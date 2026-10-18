use image::ImageReader;
use lumia_gigascan_core::{fingerprint, job, spherical_renderer};
use serde_json::{json, Value};
use std::{
    env, fs,
    io::Write,
    path::{Path, PathBuf},
    time::Instant,
};

fn progress(phase: &str, completed: u64, total: u64, last_percent: &mut u64) -> bool {
    let percent = completed.saturating_mul(100) / total.max(1);
    if percent >= *last_percent + 5 || completed >= total {
        *last_percent = percent;
        println!(
            "{}",
            json!({"event":"progress","phase":phase,"completed":completed,"total":total,"percent":percent})
        );
    }
    true
}

fn write_new_json(path: &Path, value: &Value) -> Result<(), Box<dyn std::error::Error>> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    file.write_all(&serde_json::to_vec_pretty(value)?)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

fn level0_rgba_fingerprint(output: &Path) -> Result<(String, usize), Box<dyn std::error::Error>> {
    let mut tiles = fs::read_dir(output.join("level-0"))?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<Vec<_>, _>>()?;
    tiles.retain(|path| path.extension().is_some_and(|extension| extension == "png"));
    tiles.sort_by_key(|path| {
        let stem = path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        let (row, column) = stem.split_once('-').unwrap_or(("0", "0"));
        (
            row.parse::<u32>().unwrap_or(u32::MAX),
            column.parse::<u32>().unwrap_or(u32::MAX),
        )
    });
    let mut pixel_tiles = Vec::with_capacity(tiles.len());
    for path in &tiles {
        let stem = path
            .file_stem()
            .and_then(|value| value.to_str())
            .ok_or("invalid level-zero tile name")?;
        let (row, column) = stem
            .split_once('-')
            .ok_or("invalid level-zero tile coordinate")?;
        let image = ImageReader::open(path)?
            .with_guessed_format()?
            .decode()?
            .to_rgba8();
        pixel_tiles.push(json!({
            "row":row.parse::<u32>()?,
            "column":column.parse::<u32>()?,
            "width":image.width(),
            "height":image.height(),
            "rgbaSha256":fingerprint::sha256_bytes(image.as_raw()),
        }));
    }
    let bytes = serde_json::to_vec(&pixel_tiles)?;
    Ok((fingerprint::sha256_bytes(&bytes), pixel_tiles.len()))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 4 {
        return Err("usage: benchmark_spherical_layout <layout.json> <new-output-dir> <workers> <memoryBudgetMiB>".into());
    }
    let layout_path = PathBuf::from(&args[0]);
    let output = PathBuf::from(&args[1]);
    let workers = args[2].to_string_lossy().parse::<usize>()?;
    let budget = args[3].to_string_lossy().parse::<usize>()?;
    if !(1..=lumia_gigascan_core::job_resources::MAX_WORKERS_PER_JOB).contains(&workers) {
        return Err(format!(
            "workers must be 1..={}",
            lumia_gigascan_core::job_resources::MAX_WORKERS_PER_JOB
        )
        .into());
    }
    if !(32..=lumia_gigascan_core::job_resources::MAX_JOB_MEMORY_MIB).contains(&budget) {
        return Err(format!(
            "memoryBudgetMiB must be 32..={} MiB",
            lumia_gigascan_core::job_resources::MAX_JOB_MEMORY_MIB
        )
        .into());
    }
    if output.exists() {
        return Err(format!("output directory already exists: {}", output.display()).into());
    }
    let layout_bytes = fs::read(&layout_path)?;
    let layout: Value = serde_json::from_slice(&layout_bytes)?;
    let width = u32::try_from(layout["width"].as_u64().ok_or("layout width is missing")?)?;
    let height = u32::try_from(
        layout["height"]
            .as_u64()
            .ok_or("layout height is missing")?,
    )?;
    if width == 0 || height == 0 {
        return Err("layout dimensions must be positive".into());
    }
    fs::create_dir_all(
        output
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new(".")),
    )?;
    fs::create_dir(&output)?;

    let started = Instant::now();
    let render_started = Instant::now();
    let mut render_progress = 0;
    let render = spherical_renderer::render_layout_tiles_with_options(
        &layout,
        &output,
        budget,
        workers,
        true,
        |done, total| progress("render", done, total, &mut render_progress),
    )?;
    let render_ms = render_started.elapsed().as_millis() as u64;
    println!(
        "{}",
        json!({"event":"phaseComplete","phase":"render","elapsedMs":render_ms})
    );

    let pyramid_started = Instant::now();
    let mut pyramid_progress = 0;
    let (levels, pyramid_stats) = spherical_renderer::build_pyramid_levels_with_options(
        &output,
        width,
        height,
        budget,
        workers,
        |done, total| progress("pyramid", done, total, &mut pyramid_progress),
    )?;
    let pyramid_ms = pyramid_started.elapsed().as_millis() as u64;
    println!(
        "{}",
        json!({"event":"phaseComplete","phase":"pyramid","elapsedMs":pyramid_ms})
    );

    let manifest = json!({
        "schemaVersion":1,
        "projection":"spherical",
        "tileSize":512,
        "width":width,
        "height":height,
        "yawMinRad":layout["yawMinRad"],
        "yawMaxRad":layout["yawMaxRad"],
        "pitchMinRad":layout["pitchMinRad"],
        "pitchMaxRad":layout["pitchMaxRad"],
        "complete":true,
        "backend":render["backend"],
        "memoryBudgetMiB":budget,
        "workersRequested":workers,
        "layoutReport":layout["report"],
        "rendererStats":render,
        "pyramidStats":pyramid_stats,
        "levels":levels,
    });
    write_new_json(&output.join("manifest.json"), &manifest)?;

    let export_started = Instant::now();
    let tiff_path = output.join("final.tiff");
    let tiff = job::benchmark_export_level0_tiff(&output, &manifest, &tiff_path, budget)?;
    let export_ms = export_started.elapsed().as_millis() as u64;
    println!(
        "{}",
        json!({"event":"phaseComplete","phase":"losslessTiff","elapsedMs":export_ms})
    );

    let pipeline_total_ms = started.elapsed().as_millis() as u64;
    let verification_started = Instant::now();
    let (pixel_hash, pixel_tile_count) = level0_rgba_fingerprint(&output)?;
    let pixel_verification_ms = verification_started.elapsed().as_millis() as u64;
    let receipt = json!({
        "schemaVersion":1,
        "benchmark":"spherical-layout-render-pyramid-lossless-tiff",
        "layoutSha256":fingerprint::sha256_bytes(&layout_bytes),
        "outputGeometry":{"width":width,"height":height,"tileSize":512},
        "qualityReport":layout["report"],
        "workersRequested":workers,
        "memoryBudgetMiB":budget,
        "endpoint":"complete-level0-render+pyramid+uncompressed-lossless-RGBA8-BigTIFF-or-TIFF",
        "pixelComparison":{"method":"decode each level-zero PNG to RGBA8; compare tile coordinates, dimensions, and raw pixels exactly; compressed file bytes are not compared","level0RgbaPixelsSha256":pixel_hash,"level0TileCount":pixel_tile_count},
        "phaseTimesMs":{"render":render_ms,"pyramid":pyramid_ms,"losslessTiff":export_ms,"total":pipeline_total_ms,"pixelVerification":pixel_verification_ms},
        "rendererStats":render,
        "pyramidStats":pyramid_stats,
        "tiffStats":tiff,
        "tiffPath":tiff_path,
        "manifestPath":output.join("manifest.json"),
    });
    let receipt_path = output.join("benchmark-receipt.json");
    write_new_json(&receipt_path, &receipt)?;
    println!(
        "{}",
        json!({"event":"benchmarkComplete","receipt":receipt_path,"width":width,"height":height,"level0RgbaPixelsSha256":pixel_hash})
    );
    Ok(())
}
