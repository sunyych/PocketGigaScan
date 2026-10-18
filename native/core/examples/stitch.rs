//! Small command-line harness for the public core_engine API.
//!
//! Manifest format:
//! {"rows":1,"columns":2,"overlapX":0.2,"overlapY":0.2,
//!  "tiles":[{"row":0,"column":0,"path":"a.png"}, ...]}
//! Paths are resolved relative to the manifest file.
use lumia_gigascan_core::{CaptureTile, StitchJob, StitchOptions};
use serde::Deserialize;
use std::{
    env, fs,
    path::{Path, PathBuf},
    time::Instant,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    rows: Option<usize>,
    columns: Option<usize>,
    overlap_x: Option<f32>,
    overlap_y: Option<f32>,
    band_height: Option<u32>,
    min_features: Option<usize>,
    blend_power: Option<u32>,
    tiles: Vec<Tile>,
}
#[derive(Deserialize)]
struct Tile {
    row: usize,
    column: usize,
    path: String,
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: cargo run --example stitch -- manifest.json output.png");
        std::process::exit(64);
    }
    let manifest_path = PathBuf::from(&args[1]);
    let base = manifest_path.parent().unwrap_or(Path::new("."));
    let m: Manifest = serde_json::from_str(&fs::read_to_string(&manifest_path)?)?;
    let defaults = StitchOptions::default();
    let opts = StitchOptions {
        rows: m.rows.unwrap_or(defaults.rows),
        columns: m.columns.unwrap_or(defaults.columns),
        overlap_x: m.overlap_x.unwrap_or(defaults.overlap_x),
        overlap_y: m.overlap_y.unwrap_or(defaults.overlap_y),
        band_height: m.band_height.unwrap_or(defaults.band_height),
        min_features: m.min_features.unwrap_or(defaults.min_features),
        blend_power: m.blend_power.unwrap_or(defaults.blend_power),
        ..Default::default()
    };
    let started = Instant::now();
    let mut job = StitchJob::new(opts);
    for t in m.tiles {
        job.add_tile(CaptureTile {
            row: t.row,
            column: t.column,
            path: base.join(t.path),
            geometry: None,
        })?;
    }
    let out = PathBuf::from(&args[2]);
    let mut last = String::new();
    let result = job.run(&out, |p| {
        if p.stage != last {
            eprintln!("{} {:.1}%", p.stage, p.fraction * 100.0);
            last = p.stage;
        }
    })?;
    let elapsed = started.elapsed().as_secs_f64();
    let diagnostics = serde_json::json!({"output":out,"width":result.width,"height":result.height,"partial":result.partial,"elapsedSeconds":elapsed,"report":result.report});
    let report = out.with_extension("json");
    fs::write(&report, serde_json::to_vec_pretty(&diagnostics)?)?;
    println!("{}", serde_json::to_string(&diagnostics)?);
    Ok(())
}
