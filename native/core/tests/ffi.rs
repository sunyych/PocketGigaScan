use lumia_gigascan_core::ffi::{
    lumia_gigascan_abi_version, lumia_gigascan_free, lumia_gigascan_plan_json,
    lumia_gigascan_stitch_json, ABI_VERSION,
};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

unsafe fn call_json(
    request: Value,
    function: unsafe extern "C" fn(*const std::ffi::c_char) -> *mut std::ffi::c_char,
) -> Value {
    let request = CString::new(request.to_string()).unwrap();
    let response = function(request.as_ptr());
    assert!(!response.is_null());
    let value: Value = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
    lumia_gigascan_free(response);
    value
}

#[test]
fn abi_version_is_stable() {
    assert_eq!(lumia_gigascan_abi_version(), ABI_VERSION);
    assert_eq!(ABI_VERSION, 1);
}

#[test]
fn planner_json_returns_monotonic_plan() {
    let response = unsafe {
        call_json(
            json!({
                "source": {"pan": 0.0, "tilt": 0.0, "zoom": 1.0},
                "sourceFov": {
                    "horizontal": 82.0, "vertical": 52.0,
                    "mechanicalPan": 260.0, "mechanicalTilt": 130.0
                },
                "roi": {"left": 0.1, "top": 0.1, "right": 0.9, "bottom": 0.9},
                "targetFov": {
                    "horizontal": 82.0, "vertical": 52.0,
                    "mechanicalPan": 260.0, "mechanicalTilt": 130.0
                },
                "overlapX": 0.45,
                "overlapY": 0.45,
                "grid": {"mode": "explicit", "rows": 3, "columns": 3},
                "traversal": "rowByRow",
                "estimatedBytesPerTile": 10,
                "maximumTiles": 4096
            }),
            lumia_gigascan_plan_json,
        )
    };
    assert_eq!(response["ok"], true, "{response:#}");
    assert_eq!(response["plan"]["rows"], 3);
    assert_eq!(response["plan"]["tiles"].as_array().unwrap().len(), 9);
    assert_eq!(response["plan"]["tiles"][3]["row"], 1);
    assert_eq!(response["plan"]["tiles"][3]["column"], 0);
}

#[test]
fn stitch_json_returns_consumer_quality_report() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/generated");
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let output = std::env::temp_dir().join(format!("lumia-ffi-{suffix}.png"));
    let response = unsafe {
        let request = CString::new(
            json!({
                "rows": 1,
                "columns": 2,
                "overlapX": 0.5,
                "overlapY": 0.5,
                "outputPath": output,
                "projection": "PLANAR",
                "lensProfile": {
                    "schemaVersion": 1,
                    "profileId": "pocket-built-in-wide",
                    "model": "Built-in wide",
                    "sourceResolution": {"width": 256, "height": 192},
                    "intrinsics": {"fx": 190.0, "fy": 190.0, "cx": 0.5, "cy": 0.5},
                    "distortion": {"k1": 0.01, "k2": 0.0, "k3": 0.0, "p1": 0.0, "p2": 0.0},
                    "empirical": false
                },
                "renderBackendPreference": "gpuPreferred",
                "blendPower": 8,
                "tiles": [
                    {"row": 0, "column": 0, "path": fixture.join("tile_0_0.png")},
                    {"row": 0, "column": 1, "path": fixture.join("tile_0_1.png")}
                ]
            })
            .to_string(),
        )
        .unwrap();
        let response = lumia_gigascan_stitch_json(request.as_ptr(), None, std::ptr::null_mut());
        assert!(!response.is_null());
        let value: Value = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
        lumia_gigascan_free(response);
        value
    };
    assert_eq!(response["ok"], true, "{response:#}");
    assert_eq!(response["qualityReport"]["backend"], "lumia-gigascan-core");
    assert_eq!(
        response["qualityReport"]["renderBackend"],
        "cpu-rust-banded"
    );
    assert_eq!(
        response["qualityReport"]["renderBackendPreference"],
        "gpuPreferred"
    );
    assert_eq!(response["qualityReport"]["renderBackendFallback"], true);
    assert_eq!(
        response["qualityReport"]["projection"],
        "planarPairwiseHomographyDeghostFeather"
    );
    assert_eq!(
        response["qualityReport"]["blendModel"],
        "high-order-geometric-feather-8"
    );
    assert_eq!(
        response["qualityReport"]["geometryModel"],
        "pairwise-homography+confidence-tree-projective"
    );
    assert!(response["qualityReport"]["transformFallbackCount"].is_number());
    assert_eq!(response["qualityReport"]["totalTileCount"], 2);
    // Subpixel projective bounds can include a narrow partially uncovered
    // border; the valid-alpha renderer must still cover the useful canvas.
    assert!(response["qualityReport"]["coverage"].as_f64().unwrap() > 0.95);
    assert!(output.exists());
    std::fs::remove_file(output).unwrap();
}

#[test]
fn stitch_json_rejects_invalid_lens_profile() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/generated");
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let output = std::env::temp_dir().join(format!("lumia-ffi-invalid-{suffix}.png"));
    let response = unsafe {
        let request = CString::new(
            json!({
                "rows": 1,
                "columns": 2,
                "overlapX": 0.5,
                "overlapY": 0.5,
                "outputPath": output,
                "projection": "PLANAR",
                "lensProfile": {
                    "sourceResolution": {"width": 256, "height": 192},
                    "intrinsics": {"fx": 0.0, "fy": 190.0, "cx": 0.5, "cy": 0.5}
                },
                "tiles": [
                    {"row": 0, "column": 0, "path": fixture.join("tile_0_0.png")},
                    {"row": 0, "column": 1, "path": fixture.join("tile_0_1.png")}
                ]
            })
            .to_string(),
        )
        .unwrap();
        let response = lumia_gigascan_stitch_json(request.as_ptr(), None, std::ptr::null_mut());
        assert!(!response.is_null());
        let value: Value = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
        lumia_gigascan_free(response);
        value
    };
    assert_eq!(response["ok"], false, "{response:#}");
    assert_eq!(response["error"]["code"], "INVALID_ARGUMENT");
    assert!(
        response["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("lensProfile"),
        "{response:#}"
    );
    assert!(!output.exists());
}

#[test]
fn registration_only_reports_visual_alignment_without_output() {
    use lumia_gigascan_core::ffi::lumia_gigascan_register_json;
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/generated");
    let output = std::env::temp_dir().join(format!(
        "registration-no-output-{}.png",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let mut request = json!({"rows":1,"columns":2,"overlapX":0.5,"overlapY":0.5,
        "tiles":[{"row":0,"column":0,"path":fixture.join("tile_0_0.png")},
                 {"row":0,"column":1,"path":fixture.join("tile_0_1.png")} ]});
    for supplied_output in [false, true] {
        if supplied_output {
            request["outputPath"] = json!(output);
        }
        let response = unsafe { call_json(request.clone(), lumia_gigascan_register_json) };
        assert_eq!(response["ok"], true, "{response:#}");
        assert_eq!(response["registrationOnly"], true);
        assert_eq!(response["alignment"]["visual_connected"], true);
        assert_eq!(response["alignment"]["output_width"], 0);
        assert!(response["alignment"]["edges"]
            .as_array()
            .unwrap()
            .iter()
            .any(|edge| edge["accepted"] == true
                && edge["nominal_fallback"] == false
                && edge["homography_from_to"].is_array()));
        assert!(!output.exists());
        assert!(response.get("qualityReport").is_none());
    }
}

#[test]
fn registration_only_rejects_null_and_malformed_requests() {
    use lumia_gigascan_core::ffi::lumia_gigascan_register_json;
    let malformed = CString::new("{broken").unwrap();
    for request in [std::ptr::null(), malformed.as_ptr()] {
        unsafe {
            let response = lumia_gigascan_register_json(request);
            let value: Value = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            lumia_gigascan_free(response);
            assert_eq!(value["ok"], false);
            assert_eq!(value["error"]["code"], "INVALID_REQUEST");
        }
    }
}
