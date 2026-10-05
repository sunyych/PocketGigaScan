use lumia_gigascan_core::{CaptureTile, Error, StitchJob, StitchOptions};
use std::{
    path::{Path, PathBuf},
    time::SystemTime,
};

fn tile(root: &Path, r: usize, c: usize) -> CaptureTile {
    CaptureTile {
        row: r,
        column: c,
        path: root.join(format!("tile_{r}_{c}.png")),
        geometry: None,
    }
}
fn run(root: &Path, rows: usize, cols: usize) -> lumia_gigascan_core::StitchResult {
    let mut j = StitchJob::new(StitchOptions {
        rows,
        columns: cols,
        overlap_x: 0.5,
        overlap_y: 0.5,
        ..Default::default()
    });
    for r in 0..rows {
        for c in 0..cols {
            j.add_tile(tile(root, r, c)).unwrap();
        }
    }
    let out = std::env::temp_dir().join(format!(
        "lumia-stitch-{}.png",
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let result = j.run(&out, |_| {}).unwrap();
    assert!(out.exists());
    let _ = std::fs::remove_file(out);
    result
}

fn assert_dimensions_close(actual: (u32, u32), expected: (u32, u32), tolerance: u32) {
    assert!(
        actual.0.abs_diff(expected.0) <= tolerance && actual.1.abs_diff(expected.1) <= tolerance,
        "dimensions {actual:?} differ from {expected:?} by more than {tolerance}px"
    );
}
#[test]
fn two_tile_alignment_has_expected_extent_and_overlap_pixels() {
    let root = Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/generated"));
    let mut j = StitchJob::new(StitchOptions {
        rows: 1,
        columns: 2,
        overlap_x: 0.5,
        overlap_y: 0.5,
        ..Default::default()
    });
    j.add_tile(tile(root, 0, 0)).unwrap();
    j.add_tile(tile(root, 0, 1)).unwrap();
    let out = std::env::temp_dir().join(format!(
        "lumia-two-tile-{}.png",
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let r = j.run(&out, |_| {}).unwrap();
    assert_dimensions_close((r.width, r.height), (384, 192), 2);
    assert!(r.report.matched_edges >= 1);
    let rendered = image::open(&out).unwrap().to_rgb8();
    let source = image::open(root.join("tile_0_0.png")).unwrap().to_rgb8();
    let q = source.get_pixel(64, 96);
    let matching_sample = (61..=67).any(|y| {
        (61..=67).any(|x| {
            rendered
                .get_pixel(x, y + 32)
                .0
                .iter()
                .zip(q.0.iter())
                .all(|(a, b)| (*a as i16 - *b as i16).abs() <= 6)
        })
    });
    assert!(
        matching_sample,
        "projective canvas origin should remain within 3px of the anchored source sample"
    );
    let _ = std::fs::remove_file(out);
}
#[test]
fn three_by_three_alignment_has_expected_extent() {
    let r = run(
        Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/generated")),
        3,
        3,
    );
    assert_dimensions_close((r.width, r.height), (512, 384), 2);
    assert!(r.report.failed_edges <= 2);
}
#[test]
fn four_by_five_alignment_has_expected_extent() {
    let r = run(
        Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/generated")),
        4,
        5,
    );
    assert_dimensions_close((r.width, r.height), (768, 480), 2);
}
#[test]
fn blank_and_corrupt_inputs_are_rejected() {
    let root = PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/generated"));
    for name in ["blank.png", "corrupt.png"] {
        let mut j = StitchJob::new(StitchOptions::default());
        let added = j.add_tile(CaptureTile {
            row: 0,
            column: 0,
            path: root.join(name),
            geometry: None,
        });
        let out = std::env::temp_dir().join(format!("lumia-invalid-{}.png", name));
        assert!(added.is_err() || j.run(&out, |_| {}).is_err());
        assert!(!out.exists());
    }
}
#[test]
fn cancelled_job_does_not_publish_output() {
    let root = Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/generated"));
    let mut j = StitchJob::new(StitchOptions::default());
    j.add_tile(tile(root, 0, 0)).unwrap();
    let token = j.cancellation_token();
    token.cancel();
    let out = std::env::temp_dir().join("lumia-cancelled.png");
    let e = j.run(&out, |_| {}).unwrap_err();
    assert!(matches!(e, Error::Cancelled));
    assert!(!out.exists());
}
