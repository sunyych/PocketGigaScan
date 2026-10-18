use std::{
    env,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    process::ExitCode,
};

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args = env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 2 {
        return Err(
            "usage: reorient_spherical_layout <input-layout.json> <output-layout.json>".into(),
        );
    }
    let input = PathBuf::from(&args[0]).canonicalize()?;
    let output = PathBuf::from(&args[1]);
    let output_name = output
        .file_name()
        .ok_or("output path must include a filename")?;
    let output_parent = output
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let output = output_parent.canonicalize()?.join(output_name);
    if output.exists() && output.canonicalize()? == input {
        return Err("input and output must differ; refusing to overwrite the source layout".into());
    }
    if output == input {
        return Err("input and output must differ; refusing to overwrite the source layout".into());
    }

    let mut layout: serde_json::Value = serde_json::from_slice(&fs::read(&input)?)?;
    lumia_gigascan_core::spherical::reorient_layout_to_grid_center(&mut layout)
        .map_err(std::io::Error::other)?;
    let mut destination = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output)?;
    destination.write_all(&serde_json::to_vec_pretty(&layout)?)?;
    destination.write_all(b"\n")?;
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}
