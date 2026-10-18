use std::{env, fs, process};

fn main() {
    let mut args = env::args().skip(1);
    let (Some(request_path), Some(snapshot_path)) = (args.next(), args.next()) else {
        eprintln!("usage: refine_spherical_snapshot <request.json> <snapshot-or-prune-result.json> [--fit-texture-warp | --auto-prune | --exclude-edge FROM,TO ...]");
        process::exit(2);
    };
    let mut excluded_edges = Vec::new();
    let mut auto_prune = false;
    let mut fit_texture_warp = false;
    while let Some(flag) = args.next() {
        if flag == "--auto-prune" {
            auto_prune = true;
            continue;
        }
        if flag == "--fit-texture-warp" {
            fit_texture_warp = true;
            continue;
        }
        if flag != "--exclude-edge" {
            eprintln!("usage: refine_spherical_snapshot <request.json> <snapshot-or-prune-result.json> [--fit-texture-warp | --auto-prune | --exclude-edge FROM,TO ...]");
            process::exit(2);
        }
        let Some(pair) = args.next() else {
            eprintln!("--exclude-edge requires FROM,TO");
            process::exit(2);
        };
        let Some((from, to)) = pair.split_once(',') else {
            eprintln!("--exclude-edge must use FROM,TO");
            process::exit(2);
        };
        let parsed = from
            .parse::<usize>()
            .and_then(|from| to.parse::<usize>().map(|to| (from, to)));
        match parsed {
            Ok(edge) => excluded_edges.push(edge),
            Err(error) => {
                eprintln!("invalid excluded edge: {error}");
                process::exit(2);
            }
        }
    }
    let request = fs::read_to_string(request_path).unwrap_or_else(|error| {
        eprintln!("cannot read request: {error}");
        process::exit(2);
    });
    let snapshot = fs::read_to_string(snapshot_path).unwrap_or_else(|error| {
        eprintln!("cannot read snapshot: {error}");
        process::exit(2);
    });
    let snapshot_value: serde_json::Value =
        serde_json::from_str(&snapshot).unwrap_or_else(|error| {
            eprintln!("invalid snapshot JSON: {error}");
            process::exit(2);
        });
    let snapshot = snapshot_value
        .get("diagnosticCorrespondenceSnapshot")
        .unwrap_or(&snapshot_value)
        .to_string();
    if (auto_prune || fit_texture_warp) && !excluded_edges.is_empty()
        || auto_prune && fit_texture_warp
    {
        eprintln!("--auto-prune and --fit-texture-warp are exclusive, and neither combines with --exclude-edge");
        process::exit(2);
    }
    let result = if fit_texture_warp {
        lumia_gigascan_core::spherical::fit_texture_warp_from_snapshot_json(&request, &snapshot)
    } else if auto_prune {
        lumia_gigascan_core::spherical::refine_correspondence_snapshot_auto_prune_json(
            &request, &snapshot,
        )
    } else {
        lumia_gigascan_core::spherical::refine_correspondence_snapshot_excluding_json(
            &request,
            &snapshot,
            &excluded_edges,
        )
    };
    match result {
        Ok(result) => println!("{}", serde_json::to_string_pretty(&result).unwrap()),
        Err(failure) => {
            eprintln!("{}: {}", failure.code, failure.message);
            if let Some(diagnostics) = failure.diagnostics {
                eprintln!("{}", diagnostics);
            }
            process::exit(1);
        }
    }
}
