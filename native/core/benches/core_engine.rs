use lumia_gigascan_core::{CaptureTile, StitchJob, StitchOptions};
use std::{env, fs, path::PathBuf, time::Instant};
fn main() {
    let manifest = match env::var("LUMIA_FIXTURE_MANIFEST") {
        Ok(x) => x,
        Err(_) => {
            eprintln!("SKIP: set LUMIA_FIXTURE_MANIFEST to a TSV manifest");
            return;
        }
    };
    let root = PathBuf::from(&manifest)
        .parent()
        .unwrap_or(std::path::Path::new("."))
        .to_path_buf();
    let started = Instant::now();
    let mut entries = Vec::new();
    for line in fs::read_to_string(&manifest)
        .expect("manifest")
        .lines()
        .filter(|x| !x.trim().is_empty() && !x.starts_with('#'))
    {
        let p: Vec<_> = line.split('\t').collect();
        assert!(p.len() >= 3, "manifest TSV: row column path");
        entries.push((
            p[0].parse::<usize>().unwrap(),
            p[1].parse::<usize>().unwrap(),
            p[2].to_string(),
        ));
    }
    let rows = entries.iter().map(|x| x.0).max().unwrap_or(0) + 1;
    let columns = entries.iter().map(|x| x.1).max().unwrap_or(0) + 1;
    let mut job = StitchJob::new(StitchOptions {
        rows,
        columns,
        ..Default::default()
    });
    for (row, column, path) in entries {
        job.add_tile(CaptureTile {
            row,
            column,
            path: root.join(path),
            geometry: None,
        })
        .unwrap();
    }
    let out = env::var("LUMIA_BENCH_OUTPUT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| root.join("core-benchmark.png"));
    let result = job.run(&out, |_| {}).expect("core engine");
    println!("elapsed_seconds={:.6} width={} height={} matched_edges={} fallback_edges={} failed_edges={} feature_count={}",started.elapsed().as_secs_f64(),result.width,result.height,result.report.matched_edges,result.report.nominal_fallback_edges,result.report.failed_edges,result.report.feature_count);
}
