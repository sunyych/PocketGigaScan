use std::{env, fs, process};

fn main() {
    let mut args = env::args_os().skip(1);
    let (Some(request_path), Some(snapshot_path), Some(producer_dll_path)) =
        (args.next(), args.next(), args.next())
    else {
        eprintln!("usage: upgrade_spherical_snapshot_metadata <request.json> <snapshot.json> <approved-producer.dll>");
        process::exit(2);
    };
    if args.next().is_some() {
        eprintln!("expected exactly three input paths");
        process::exit(2);
    }
    let request = fs::read_to_string(request_path).unwrap_or_else(|error| {
        eprintln!("cannot read request: {error}");
        process::exit(2);
    });
    let snapshot = fs::read_to_string(snapshot_path).unwrap_or_else(|error| {
        eprintln!("cannot read snapshot: {error}");
        process::exit(2);
    });
    let producer_dll_path = producer_dll_path.to_string_lossy();
    match lumia_gigascan_core::spherical::upgrade_approved_v2_correspondence_snapshot_json(
        &request,
        &snapshot,
        &producer_dll_path,
    ) {
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
