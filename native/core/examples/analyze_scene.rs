use lumia_gigascan_core::{fingerprint, scene_analysis};
use serde_json::{json, Value};
use std::{env, fs, path::PathBuf};

fn run() -> Result<(), String> {
    let request_path = env::args()
        .nth(1)
        .ok_or("usage: cargo run --release --example analyze_scene -- request.json")?;
    let value: Value = serde_json::from_slice(&fs::read(&request_path).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    let sources = value["sources"]
        .as_array()
        .ok_or("sources must be an array")?
        .iter()
        .map(|source| {
            let path = PathBuf::from(
                source
                    .as_str()
                    .ok_or("each sources entry must be an absolute path")?,
            )
            .canonicalize()
            .map_err(|e| e.to_string())?;
            let hash = fingerprint::sha256_file(&path).map_err(|e| e.to_string())?;
            Ok((path, hash))
        })
        .collect::<Result<Vec<_>, String>>()?;
    let model = PathBuf::from(
        value["sceneModelPath"]
            .as_str()
            .ok_or("sceneModelPath is required")?,
    );
    let model_sha = value["sceneModelSha256"]
        .as_str()
        .ok_or("sceneModelSha256 is required")?;
    let cache = PathBuf::from(
        value["sceneCacheDir"]
            .as_str()
            .ok_or("sceneCacheDir is required")?,
    );
    let budget = value["memoryBudgetMiB"]
        .as_u64()
        .ok_or("memoryBudgetMiB is required")? as usize;
    let cpu_workers = value["cpuWorkers"].as_u64().unwrap_or(4) as usize;
    let result = scene_analysis::analyze(
        &sources,
        &model,
        model_sha,
        &cache,
        budget,
        cpu_workers,
        |_, _| true,
    )?;
    println!(
        "{}",
        json!({"cpuWorkers":cpu_workers.clamp(1, 8),"semanticAnalysis":result})
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
