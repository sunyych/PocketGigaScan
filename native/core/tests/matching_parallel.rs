use image::{GrayImage, Luma};
use lumia_gigascan_core::ffi::{lumia_gigascan_free, lumia_gigascan_spherical_json};
use serde_json::{json, Value};
use std::{
    ffi::{CStr, CString},
    fs,
    sync::atomic::{AtomicU64, Ordering},
};

static NEXT: AtomicU64 = AtomicU64::new(0);

fn run(feature: &str, matcher: &str, parallel: bool) -> Value {
    let dir = std::env::temp_dir().join(format!(
        "lg-match-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&dir).unwrap();
    let mut image = GrayImage::new(320, 240);
    let mut state = 0x1234_5678u32;
    for pixel in image.pixels_mut() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        *pixel = Luma([(state >> 24) as u8]);
    }
    let paths = (0..4)
        .map(|index| {
            let path = dir.join(format!("tile-{index}.png"));
            image.save(&path).unwrap();
            path
        })
        .collect::<Vec<_>>();
    let tiles = paths
        .iter()
        .enumerate()
        .map(|(index, path)| json!({"row":index / 2,"column":index % 2,"path":path}))
        .collect::<Vec<_>>();
    let request = CString::new(
        json!({
            "rows":2,"columns":2,"tiles":tiles,
            "fx":190.0,"fy":188.0,"cx":159.5,"cy":119.5,"sourceWidth":320,"sourceHeight":240,
            "featureType":feature,"matcherType":matcher,"parallelMatching":parallel,"workers":4
        })
        .to_string(),
    )
    .unwrap();
    let ptr = unsafe { lumia_gigascan_spherical_json(request.as_ptr()) };
    let result = unsafe { serde_json::from_slice(CStr::from_ptr(ptr).to_bytes()) }.unwrap();
    unsafe { lumia_gigascan_free(ptr) };
    let _ = fs::remove_dir_all(dir);
    result
}

fn run_low_contrast_retry(parallel: bool) -> Value {
    let dir = std::env::temp_dir().join(format!(
        "lg-retry-match-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&dir).unwrap();
    let mut image = GrayImage::new(320, 240);
    let mut state = 0x51a7_991du32;
    for y in 0..240 {
        for x in 0..320 {
            if x % 8 == 0 && y % 8 == 0 {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
            }
            image.put_pixel(x, y, Luma([118 + (state % 5) as u8]));
        }
    }
    let path = dir.join("low-contrast.png");
    image.save(&path).unwrap();
    let tiles = (0..4)
        .map(|index| json!({"row":index / 2,"column":index % 2,"path":path}))
        .collect::<Vec<_>>();
    let request = CString::new(
        json!({
            "rows":2,"columns":2,"tiles":tiles,
            "fx":190.0,"fy":188.0,"cx":159.5,"cy":119.5,"sourceWidth":320,"sourceHeight":240,
            "neighborMode":"four","parallelMatching":parallel,"workers":4
        })
        .to_string(),
    )
    .unwrap();
    let ptr = unsafe { lumia_gigascan_spherical_json(request.as_ptr()) };
    let result = unsafe { serde_json::from_slice(CStr::from_ptr(ptr).to_bytes()) }.unwrap();
    unsafe { lumia_gigascan_free(ptr) };
    let _ = fs::remove_dir_all(dir);
    result
}

#[test]
fn serial_and_parallel_edge_matching_are_equivalent() {
    let serial = run("sift", "bf", false);
    let parallel = run("sift", "bf", true);
    assert_eq!(serial["ok"], true, "{serial:#}");
    assert_eq!(parallel["ok"], true, "{parallel:#}");
    assert_eq!(
        serial["layout"]["report"]["edgeDiagnostics"],
        parallel["layout"]["report"]["edgeDiagnostics"]
    );
    assert_eq!(serial["layout"]["report"]["requestedMatchingWorkers"], 4);
    assert_eq!(serial["layout"]["report"]["effectiveMatchingWorkers"], 1);
    assert_eq!(parallel["layout"]["report"]["effectiveMatchingWorkers"], 4);
}

#[test]
fn serial_and_parallel_low_contrast_retry_preserve_edge_results() {
    let serial = run_low_contrast_retry(false);
    let parallel = run_low_contrast_retry(true);
    fn edges(result: &Value) -> &Value {
        result
            .pointer("/layout/report/edgeDiagnostics")
            .or_else(|| result.pointer("/error/diagnostics/edges"))
            .unwrap_or_else(|| panic!("missing edge diagnostics: {result:#}"))
    }
    let serial_edges = edges(&serial);
    let parallel_edges = edges(&parallel);
    assert_eq!(serial_edges.as_array().unwrap().len(), 4);
    assert_eq!(
        serial_edges
            .as_array()
            .unwrap()
            .iter()
            .map(|edge| {
                (
                    edge["from"].clone(),
                    edge["to"].clone(),
                    edge["usedRetry"].clone(),
                    edge["usedClaheRetry"].clone(),
                    edge["selectedAttempt"].clone(),
                    edge["initial"].clone(),
                    edge["retry"].clone(),
                    edge["claheRetry"].clone(),
                )
            })
            .collect::<Vec<_>>(),
        parallel_edges
            .as_array()
            .unwrap()
            .iter()
            .map(|edge| {
                (
                    edge["from"].clone(),
                    edge["to"].clone(),
                    edge["usedRetry"].clone(),
                    edge["usedClaheRetry"].clone(),
                    edge["selectedAttempt"].clone(),
                    edge["initial"].clone(),
                    edge["retry"].clone(),
                    edge["claheRetry"].clone(),
                )
            })
            .collect::<Vec<_>>()
    );
    assert!(serial_edges
        .as_array()
        .unwrap()
        .iter()
        .any(|edge| edge["retry"].is_object() || edge["claheRetry"].is_object()));
}

#[test]
fn orb_and_flann_requests_execute_as_selected() {
    let orb = run("orb", "bf", true);
    assert_eq!(orb["ok"], true, "{orb:#}");
    assert_eq!(orb["layout"]["report"]["featureType"], "orb");
    assert_eq!(orb["layout"]["report"]["matcherType"], "bf");
    let sift_flann = run("sift", "flann", true);
    assert_eq!(sift_flann["ok"], true, "{sift_flann:#}");
    assert_eq!(sift_flann["layout"]["report"]["matcherType"], "flann");
}
#[test]
fn spherical_alignment_propagates_cancellation_checkpoints() {
    let request = json!({
        "rows":1,"columns":2,
        "tiles":[{"row":0,"column":0,"path":"missing-a.png"},{"row":0,"column":1,"path":"missing-b.png"}],
        "fx":190.0,"fy":188.0,"cx":159.5,"cy":119.5,"sourceWidth":320,"sourceHeight":240
    }).to_string();
    let mut checkpoint = |stage: &str| {
        if stage == "validation-complete" {
            Err("cancelled by test".to_owned())
        } else {
            Ok(())
        }
    };
    let error =
        lumia_gigascan_core::spherical::align_json_with_checkpoint(&request, &mut checkpoint)
            .unwrap_err();
    assert_eq!(error.code, "CANCELLED");
}
