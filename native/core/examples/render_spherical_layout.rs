use lumia_gigascan_core::spherical_renderer::{build_pyramid_levels, render_layout_tiles};
use serde_json::{json, Value};
use std::{env, fs, io::Write, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = env::args_os().skip(1).collect::<Vec<_>>();
    if !(2..=3).contains(&args.len()) {
        return Err(
            "usage: render_spherical_layout <layout.json> <new-output-dir> [memoryBudgetMiB]"
                .into(),
        );
    }
    let layout_path = PathBuf::from(&args[0]);
    let output = PathBuf::from(&args[1]);
    let budget = args
        .get(2)
        .map(|value| value.to_string_lossy().parse::<usize>())
        .transpose()?
        .unwrap_or(128);
    if !(32..=4096).contains(&budget) {
        return Err("memoryBudgetMiB must be 32..=4096".into());
    }
    let layout: Value = serde_json::from_slice(&fs::read(&layout_path)?)?;
    let width = u32::try_from(layout["width"].as_u64().ok_or("layout width is missing")?)?;
    let height = u32::try_from(
        layout["height"]
            .as_u64()
            .ok_or("layout height is missing")?,
    )?;
    if output.exists() {
        return Err(format!("output directory already exists: {}", output.display()).into());
    }
    fs::create_dir(&output)?;
    let render = render_layout_tiles(&layout, &output, budget, || false)?;
    let levels = build_pyramid_levels(&output, width, height, |_, _| true)?;
    let manifest = json!({
        "schemaVersion": 1,
        "projection": "spherical",
        "tileSize": 512,
        "width": width,
        "height": height,
        "yawMinRad": layout["yawMinRad"],
        "yawMaxRad": layout["yawMaxRad"],
        "pitchMinRad": layout["pitchMinRad"],
        "pitchMaxRad": layout["pitchMaxRad"],
        "complete": true,
        "backend": render["backend"],
        "memoryBudgetMiB": budget,
        "rendererStats": render,
        "levels": levels,
    });
    let manifest_path = output.join("manifest.json");
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&manifest_path)?;
    file.write_all(&serde_json::to_vec_pretty(&manifest)?)?;
    file.sync_all()?;
    println!(
        "{}",
        serde_json::to_string(&json!({
            "outputDir": output.display().to_string(),
            "manifestPath": manifest_path.display().to_string(),
            "width": width,
            "height": height,
            "render": render,
            "levels": levels.len(),
        }))?
    );
    Ok(())
}
