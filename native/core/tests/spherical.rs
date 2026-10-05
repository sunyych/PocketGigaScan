use image::{GrayImage, Luma};
use lumia_gigascan_core::ffi::{lumia_gigascan_free, lumia_gigascan_spherical_json};
use serde_json::{json, Value};
use std::{
    ffi::{CStr, CString},
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

type Mat = [f64; 9];
fn mul(a: Mat, b: Mat) -> Mat {
    let mut out = [0.; 9];
    for r in 0..3 {
        for c in 0..3 {
            out[r * 3 + c] = (0..3).map(|k| a[r * 3 + k] * b[k * 3 + c]).sum();
        }
    }
    out
}
fn transpose(a: Mat) -> Mat {
    [a[0], a[3], a[6], a[1], a[4], a[7], a[2], a[5], a[8]]
}
fn ry(a: f64) -> Mat {
    let (s, c) = a.sin_cos();
    [c, 0., s, 0., 1., 0., -s, 0., c]
}
fn rx(a: f64) -> Mat {
    let (s, c) = a.sin_cos();
    [1., 0., 0., 0., c, -s, 0., s, c]
}
fn mul_vec(a: Mat, v: [f64; 3]) -> [f64; 3] {
    [
        a[0] * v[0] + a[1] * v[1] + a[2] * v[2],
        a[3] * v[0] + a[4] * v[1] + a[5] * v[2],
        a[6] * v[0] + a[7] * v[1] + a[8] * v[2],
    ]
}
fn mix(mut x: u32) -> u32 {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846ca68b);
    x ^ (x >> 16)
}
fn sphere_texture(yaw: f64, pitch: f64, texture_width: f64) -> u8 {
    let x = (((yaw + std::f64::consts::PI) / (2. * std::f64::consts::PI) * texture_width) as i32)
        .div_euclid(8) as u32;
    let y = (((std::f64::consts::FRAC_PI_2 - pitch) / std::f64::consts::PI * texture_width * 0.5)
        as i32)
        .div_euclid(8) as u32;
    (40 + mix(x.wrapping_mul(0x9e3779b9) ^ y.wrapping_mul(0x85ebca6b)) % 200) as u8
}
fn low_contrast_sphere_texture(yaw: f64, pitch: f64, texture_width: f64, seed: u32) -> u8 {
    let x = (((yaw + std::f64::consts::PI) / (2. * std::f64::consts::PI) * texture_width) as i32)
        .div_euclid(8) as u32;
    let y = (((std::f64::consts::FRAC_PI_2 - pitch) / std::f64::consts::PI * texture_width * 0.5)
        as i32)
        .div_euclid(8) as u32;
    let value = mix(x.wrapping_mul(0x9e3779b9) ^ y.wrapping_mul(0x85ebca6b) ^ seed);
    (118 + value % 5) as u8
}

fn low_contrast_view(row: usize, column: usize, seed: u32, path: &std::path::Path) {
    const W: u32 = 320;
    const H: u32 = 240;
    const FX: f64 = 190.;
    const FY: f64 = 188.;
    const CX: f64 = (W as f64 - 1.) * 0.5;
    const CY: f64 = (H as f64 - 1.) * 0.5;
    let pose = camera_pose(row, column);
    let mut image = GrayImage::new(W, H);
    for y in 0..H {
        for x in 0..W {
            let mut ray = [(x as f64 - CX) / FX, -(y as f64 - CY) / FY, 1.];
            let norm = (ray[0] * ray[0] + ray[1] * ray[1] + 1.).sqrt();
            for value in &mut ray {
                *value /= norm;
            }
            let world = mul_vec(pose, ray);
            image.put_pixel(
                x,
                y,
                Luma([low_contrast_sphere_texture(
                    world[0].atan2(world[2]),
                    world[1].asin(),
                    2048.,
                    seed,
                )]),
            );
        }
    }
    image.save(path).unwrap();
}

struct FixtureDir(PathBuf);
static NEXT_FIXTURE_ID: AtomicU64 = AtomicU64::new(0);
impl FixtureDir {
    fn new() -> Self {
        loop {
            let sequence = NEXT_FIXTURE_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("lumia-spherical-{}-{sequence}", std::process::id()));
            match fs::create_dir(&path) {
                Ok(()) => return Self(path),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("failed to create spherical fixture directory: {error}"),
            }
        }
    }
}
impl Drop for FixtureDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn camera_pose_at(row: usize, column: usize, yaw_step: f64, pitch_step: f64) -> Mat {
    let yaw = (column as f64 - 1.) * yaw_step;
    let pitch = (1. - row as f64) * pitch_step;
    mul(ry(yaw), rx(-pitch))
}
fn camera_pose(row: usize, column: usize) -> Mat {
    camera_pose_at(row, column, 0.32, 0.23)
}

#[test]
fn spherical_abi_registers_a_true_nine_view_textured_sphere() {
    const W: u32 = 320;
    const H: u32 = 240;
    const FX: f64 = 190.;
    const FY: f64 = 188.;
    const CX: f64 = (W as f64 - 1.) * 0.5;
    const CY: f64 = (H as f64 - 1.) * 0.5;
    let dir = FixtureDir::new();
    let mut tiles = Vec::new();
    for row in 0..3 {
        for column in 0..3 {
            let pose = camera_pose(row, column);
            let mut image = GrayImage::new(W, H);
            for y in 0..H {
                for x in 0..W {
                    let mut ray = [(x as f64 - CX) / FX, -(y as f64 - CY) / FY, 1.];
                    let n = (ray[0] * ray[0] + ray[1] * ray[1] + 1.).sqrt();
                    for v in &mut ray {
                        *v /= n;
                    }
                    let world = mul_vec(pose, ray);
                    let yaw = world[0].atan2(world[2]);
                    let pitch = world[1].asin();
                    image.put_pixel(x, y, Luma([sphere_texture(yaw, pitch, 2048.)]));
                }
            }
            let path = dir.0.join(format!("view_{row}_{column}.png"));
            image.save(&path).unwrap();
            tiles.push(json!({"row":row,"column":column,"path":path}));
        }
    }
    let request = CString::new(
        json!({"rows":3,"columns":3,"tiles":tiles,"fx":FX,"fy":FY,"cx":CX,"cy":CY,"sourceWidth":W,"sourceHeight":H,"outputDir":"unused","neighborMode":"eight","workers":1})
            .to_string(),
    )
    .unwrap();
    let response_ptr = unsafe { lumia_gigascan_spherical_json(request.as_ptr()) };
    let response: Value =
        unsafe { serde_json::from_slice(CStr::from_ptr(response_ptr).to_bytes()) }.unwrap();
    unsafe { lumia_gigascan_free(response_ptr) };
    assert_eq!(response["ok"], true, "{response:#}");
    let layout = &response["layout"];
    let mut parallel_request: Value = serde_json::from_str(request.to_str().unwrap()).unwrap();
    parallel_request["workers"] = json!(4);
    let parallel_json = CString::new(parallel_request.to_string()).unwrap();
    let parallel_ptr = unsafe { lumia_gigascan_spherical_json(parallel_json.as_ptr()) };
    let parallel: Value =
        unsafe { serde_json::from_slice(CStr::from_ptr(parallel_ptr).to_bytes()) }.unwrap();
    unsafe { lumia_gigascan_free(parallel_ptr) };
    assert_eq!(parallel["ok"], true, "{parallel:#}");
    assert_eq!(parallel["layout"]["report"]["neighborMode"], "eight");
    assert_eq!(layout["report"]["neighborMode"], "eight");
    assert_eq!(layout["report"]["effectiveWorkers"], 1);
    assert_eq!(parallel["layout"]["report"]["effectiveWorkers"], 4);
    assert_eq!(
        layout["report"]["featureCount"],
        parallel["layout"]["report"]["featureCount"]
    );
    assert!(
        parallel["layout"]["report"]["estimatedPrimaryDescriptorBytes"]
            .as_u64()
            .unwrap()
            > 0
    );
    assert!(
        parallel["layout"]["report"]["estimatedPeakDescriptorBytes"]
            .as_u64()
            .unwrap()
            > 0
    );
    assert_eq!(parallel["layout"]["report"]["totalEdges"], 20);
    for index in 0..9 {
        let serial: [f64; 9] =
            serde_json::from_value(layout["tiles"][index]["cameraToWorld"].clone()).unwrap();
        let parallel_pose: [f64; 9] =
            serde_json::from_value(parallel["layout"]["tiles"][index]["cameraToWorld"].clone())
                .unwrap();
        assert!(
            serial
                .iter()
                .zip(parallel_pose)
                .all(|(a, b)| (a - b).abs() < 0.025),
            "parallel pose changed for tile {index}"
        );
    }
    assert_eq!(layout["projection"], "spherical");
    assert_eq!(layout["schemaVersion"], 1);
    assert_eq!(layout["tiles"].as_array().unwrap().len(), 9);
    let graph_rms_px = layout["report"]["orientationRmsPixelEquivalent"]
        .as_f64()
        .unwrap();
    println!("wide-view spherical graph RMS: {graph_rms_px:.4} px-equivalent");

    // The center tile defines the output orientation; compare every pose to it.
    assert_eq!(layout["report"]["orientationReference"]["row"], 1);
    assert_eq!(layout["report"]["orientationReference"]["column"], 1);
    assert_eq!(layout["report"]["orientationReference"]["index"], 4);
    let center: [f64; 9] =
        serde_json::from_value(layout["tiles"][4]["cameraToWorld"].clone()).unwrap();
    assert!(center
        .iter()
        .zip([1., 0., 0., 0., 1., 0., 0., 0., 1.])
        .all(|(actual, expected)| (actual - expected).abs() < 1e-7));
    let reference = camera_pose(1, 1);
    for row in 0..3 {
        for column in 0..3 {
            let estimated: [f64; 9] =
                serde_json::from_value(layout["tiles"][row * 3 + column]["cameraToWorld"].clone())
                    .unwrap();
            let expected = mul(transpose(reference), camera_pose(row, column));
            let error = mul(transpose(expected), estimated);
            let angle = ((error[0] + error[4] + error[8] - 1.) * 0.5)
                .clamp(-1., 1.)
                .acos();
            assert!(angle < 0.06, "pose {row},{column} error {angle:.4} rad");
        }
    }
}

#[test]
fn grid_assisted_mode_places_blank_center_from_neighboring_rows_and_columns() {
    const W: u32 = 320;
    const H: u32 = 240;
    const FX: f64 = 190.;
    const FY: f64 = 188.;
    const CX: f64 = (W as f64 - 1.) * 0.5;
    const CY: f64 = (H as f64 - 1.) * 0.5;
    let dir = FixtureDir::new();
    let mut tiles = Vec::new();
    for row in 0..3 {
        for column in 0..3 {
            let path = dir.0.join(format!("grid_{row}_{column}.png"));
            if row == 1 && column == 1 {
                GrayImage::from_pixel(W, H, Luma([90])).save(&path).unwrap();
            } else {
                let pose = camera_pose(row, column);
                let mut image = GrayImage::new(W, H);
                for y in 0..H {
                    for x in 0..W {
                        let mut ray = [(x as f64 - CX) / FX, -(y as f64 - CY) / FY, 1.];
                        let n = (ray[0] * ray[0] + ray[1] * ray[1] + 1.).sqrt();
                        for value in &mut ray {
                            *value /= n;
                        }
                        let world = mul_vec(pose, ray);
                        image.put_pixel(
                            x,
                            y,
                            Luma([sphere_texture(
                                world[0].atan2(world[2]),
                                world[1].asin(),
                                2048.,
                            )]),
                        );
                    }
                }
                image.save(&path).unwrap();
            }
            tiles.push(json!({"row":row,"column":column,"path":path,
                "forceGrid":row == 1 && column == 1}));
        }
    }
    let make_request = |placement_mode: &str, tiles: &[Value]| {
        CString::new(
            json!({"rows":3,"columns":3,"tiles":tiles,"placementMode":placement_mode,"fx":FX,"fy":FY,"cx":CX,"cy":CY,"sourceWidth":W,"sourceHeight":H})
                .to_string(),
        )
        .unwrap()
    };
    let call = |request: &CString| {
        let pointer = unsafe { lumia_gigascan_spherical_json(request.as_ptr()) };
        let response: Value =
            unsafe { serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()) }.unwrap();
        unsafe { lumia_gigascan_free(pointer) };
        response
    };

    let visual = call(&make_request("visual", &tiles));
    assert_eq!(visual["ok"], false, "{visual:#}");
    assert_eq!(visual["error"]["diagnostics"]["connectedTileCount"], 8);

    let assisted = call(&make_request("grid-assisted", &tiles));
    assert_eq!(assisted["ok"], true, "{assisted:#}");
    let layout = &assisted["layout"];
    let report = &layout["report"];
    assert_eq!(report["placementMode"], "grid-assisted");
    assert_eq!(report["visualTileCount"], 8);
    assert_eq!(report["gridEstimatedTileCount"], 1);
    assert_eq!(report["gridEstimatedTileIndices"][0], 4);
    assert_eq!(report["forcedGridTileCount"], 1);
    assert_eq!(report["forcedGridTileIndices"][0], 4);
    assert_eq!(report["completeCorrespondenceEvidence"], true);
    assert_eq!(layout["tiles"][4]["positionSource"], "gridEstimated");
    assert_eq!(layout["tiles"].as_array().unwrap().len(), 9);
    assert_eq!(layout["tiles"][4]["forceGrid"], true);
    assert_eq!(
        report["edgeDiagnostics"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|edge| edge["disposition"] == "forced_grid_cell")
            .count(),
        4
    );
    assert!(report["synthesizedGridEdgeCount"].as_u64().unwrap() >= 2);
    assert!(report["globalRayReprojectionRmsPx"].as_f64().unwrap() < 12.0);

    let unforced_tiles = tiles
        .iter()
        .cloned()
        .map(|mut tile| {
            tile.as_object_mut().unwrap().remove("forceGrid");
            tile
        })
        .collect::<Vec<_>>();
    let unforced = call(&make_request("grid-assisted", &unforced_tiles));
    assert_eq!(unforced["ok"], true, "{unforced:#}");
    assert_eq!(unforced["layout"]["tiles"].as_array().unwrap().len(), 9);
    assert_eq!(unforced["layout"]["report"]["forcedGridTileCount"], 0);
    assert_eq!(unforced["layout"]["tiles"][4]["forceGrid"], false);
}

#[test]
fn grid_assisted_mode_fails_when_no_visual_grid_steps_are_measurable() {
    let dir = FixtureDir::new();
    let mut tiles = Vec::new();
    for column in 0..2 {
        let path = dir.0.join(format!("unrelated_{column}.png"));
        low_contrast_view(0, 0, column as u32 * 12_345, &path);
        tiles.push(json!({"row":0,"column":column,"path":path}));
    }
    let request = CString::new(
        json!({"rows":1,"columns":2,"tiles":tiles,"placementMode":"grid-assisted","fx":190.0,"fy":188.0,"cx":159.5,"cy":119.5,"sourceWidth":320,"sourceHeight":240})
            .to_string(),
    )
    .unwrap();
    let pointer = unsafe { lumia_gigascan_spherical_json(request.as_ptr()) };
    let response: Value =
        unsafe { serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()) }.unwrap();
    unsafe { lumia_gigascan_free(pointer) };
    assert_eq!(response["ok"], false, "{response:#}");
    assert_eq!(
        response["error"]["code"], "REGISTRATION_FAILED",
        "{response:#}"
    );
    assert!(response["error"]["message"]
        .as_str()
        .unwrap()
        .contains("horizontal neighbor rotation"));

    let mut opted_in: Value = serde_json::from_slice(request.as_bytes()).unwrap();
    opted_in["allowNominalGridFallback"] = json!(true);
    let opted_in = CString::new(opted_in.to_string()).unwrap();
    let pointer = unsafe { lumia_gigascan_spherical_json(opted_in.as_ptr()) };
    let response: Value =
        unsafe { serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()) }.unwrap();
    unsafe { lumia_gigascan_free(pointer) };
    assert_eq!(response["ok"], true, "{response:#}");
    assert_eq!(response["layout"]["report"]["visualTileCount"], 0);
    assert_eq!(response["layout"]["report"]["gridEstimatedTileCount"], 2);
    assert_eq!(
        response["layout"]["report"]["completeCorrespondenceEvidence"],
        false
    );
}

#[test]
fn explicit_nominal_fov_fallback_places_blank_grid_and_reports_unknown_visual_quality() {
    const W: u32 = 320;
    const H: u32 = 240;
    const FX: f64 = 190.0;
    const FY: f64 = 188.0;
    let dir = FixtureDir::new();
    let mut tiles = Vec::new();
    for row in 0..3 {
        for column in 0..3 {
            let path = dir.0.join(format!("blank_{row}_{column}.png"));
            GrayImage::from_pixel(W, H, Luma([90])).save(&path).unwrap();
            tiles.push(json!({"row":row,"column":column,"path":path,
                "forceGrid":row == 1 && column == 1}));
        }
    }
    let base = json!({"rows":3,"columns":3,"tiles":tiles,"placementMode":"grid-assisted",
        "fx":FX,"fy":FY,"cx":159.5,"cy":119.5,"sourceWidth":W,"sourceHeight":H});
    let call = |request: &Value| {
        let request = CString::new(request.to_string()).unwrap();
        let pointer = unsafe { lumia_gigascan_spherical_json(request.as_ptr()) };
        let response: Value =
            unsafe { serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()) }.unwrap();
        unsafe { lumia_gigascan_free(pointer) };
        response
    };

    let strict = call(&base);
    assert_eq!(strict["ok"], false, "{strict:#}");
    assert_eq!(strict["error"]["code"], "REGISTRATION_FAILED");

    let mut opted_in = base.clone();
    opted_in["allowNominalGridFallback"] = json!(true);
    let response = call(&opted_in);
    assert_eq!(response["ok"], true, "{response:#}");
    let layout = &response["layout"];
    let report = &layout["report"];
    assert_eq!(layout["tiles"].as_array().unwrap().len(), 9);
    assert_eq!(report["orientationReference"]["index"], 4);
    assert_eq!(report["forcedGridTileCount"], 1);
    assert_eq!(report["visualTileCount"], 0);
    assert_eq!(report["gridEstimatedTileCount"], 9);
    assert_eq!(report["geometryModel"], "nominal-fov-grid");
    assert_eq!(layout["tiles"][4]["forceGrid"], true);
    assert_eq!(layout["tiles"][4]["positionSource"], "gridEstimated");
    let center_pose = layout["tiles"][4]["cameraToWorld"].as_array().unwrap();
    for (value, expected) in center_pose
        .iter()
        .zip([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0])
    {
        assert!((value.as_f64().unwrap() - expected).abs() < 1e-9);
    }
    assert_eq!(report["completeCorrespondenceEvidence"], false);
    assert_eq!(report["nominalGridOnlyNeedsVisualReview"], true);
    assert_eq!(report["medianHomographyRansacResidualPx"], Value::Null);
    assert_eq!(report["globalRayReprojectionRmsPx"], Value::Null);
    assert_eq!(
        report["pairwiseMedianRotationResidualPixelEquivalent"],
        Value::Null
    );
    assert_eq!(
        report["gridHorizontalStep"]["robustRmsRadians"],
        Value::Null
    );
    assert_eq!(report["gridVerticalStep"]["robustRmsRadians"], Value::Null);
    let edges = report["synthesizedGridEdges"].as_array().unwrap();
    assert_eq!(edges.len(), 12);
    assert!(edges.iter().all(|edge| {
        edge["rotationSource"] == "nominalFovOverlap"
            && edge["sampleCount"] == 0
            && edge["robustRmsRadians"] == Value::Null
    }));

    let horizontal_fov = 2.0 * (W as f64 / (2.0 * FX)).atan();
    let vertical_fov = 2.0 * (H as f64 / (2.0 * FY)).atan();
    let expected_horizontal_step = horizontal_fov * 0.7;
    let expected_vertical_step = vertical_fov * 0.7;
    assert!(
        (report["gridHorizontalStepRadians"].as_f64().unwrap() - expected_horizontal_step).abs()
            < 1e-9
    );
    assert!(
        (report["gridVerticalStepRadians"].as_f64().unwrap() - expected_vertical_step).abs() < 1e-9
    );
    // After center reorientation, increasing columns turn toward positive
    // world yaw and increasing rows toward negative world pitch.
    assert!(layout["tiles"][5]["cameraToWorld"][2].as_f64().unwrap() > 0.0);
    assert!(layout["tiles"][7]["cameraToWorld"][5].as_f64().unwrap() < 0.0);
    let warnings = report["qualityWarnings"].as_array().unwrap();
    assert!(warnings
        .iter()
        .any(|warning| warning.as_str().unwrap().contains("visual correspondence")));
    assert!(warnings.iter().all(|warning| {
        let warning = warning.as_str().unwrap().to_ascii_lowercase();
        !warning.contains("inf") && !warning.contains("reprojection is")
    }));

    let mut invalid = base;
    invalid["gridHorizontalOverlap"] = json!(0.9);
    let invalid = call(&invalid);
    assert_eq!(invalid["ok"], false, "{invalid:#}");
    assert_eq!(invalid["error"]["code"], "INVALID_ARGUMENT");
    assert!(invalid["error"]["message"]
        .as_str()
        .unwrap()
        .contains("gridHorizontalOverlap"));
}

#[test]
fn spherical_abi_rejects_low_texture_sources_without_nominal_placement() {
    let dir = FixtureDir::new();
    let mut tiles = Vec::new();
    for column in 0..2 {
        let path = dir.0.join(format!("blank_{column}.png"));
        GrayImage::from_pixel(128, 96, Luma([90]))
            .save(&path)
            .unwrap();
        tiles.push(json!({"row":0,"column":column,"path":path}));
    }
    let request = CString::new(
        json!({"rows":1,"columns":2,"tiles":tiles,"fx":75000.0,"fy":75000.0,"cx":63.5,"cy":47.5,"sourceWidth":128,"sourceHeight":96})
            .to_string(),
    )
    .unwrap();
    let response_ptr = unsafe { lumia_gigascan_spherical_json(request.as_ptr()) };
    let response: Value =
        unsafe { serde_json::from_slice(CStr::from_ptr(response_ptr).to_bytes()) }.unwrap();
    unsafe { lumia_gigascan_free(response_ptr) };
    assert_eq!(response["ok"], false, "{response:#}");
    assert_eq!(response["error"]["code"], "REGISTRATION_FAILED");
    let diagnostics = &response["error"]["diagnostics"];
    assert_eq!(diagnostics["attemptedEdgeCount"], 1);
    assert_eq!(diagnostics["acceptedEdgeCount"], 0);
    assert_eq!(
        diagnostics["edges"][0]["disposition"],
        "descriptor_missing_or_invalid"
    );
    assert_eq!(diagnostics["edges"][0]["initial"]["fromFeatures"], 0);
    assert_eq!(diagnostics["edges"][0]["initial"]["toFeatures"], 0);
}

#[test]
fn spherical_retry_registers_low_contrast_overlap_and_rejects_unrelated_texture() {
    fn request_for(dir: &FixtureDir, second_seed: u32) -> CString {
        let first = dir.0.join("low_a.png");
        let second = dir.0.join("low_b.png");
        low_contrast_view(0, 0, 0, &first);
        low_contrast_view(0, 1, second_seed, &second);
        CString::new(
            json!({"rows":1,"columns":2,"tiles":[{"row":0,"column":0,"path":first},{"row":0,"column":1,"path":second}],"fx":190.0,"fy":188.0,"cx":159.5,"cy":119.5,"sourceWidth":320,"sourceHeight":240})
                .to_string(),
        )
        .unwrap()
    }
    fn call(request: &CString) -> Value {
        let pointer = unsafe { lumia_gigascan_spherical_json(request.as_ptr()) };
        let response: Value =
            unsafe { serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()) }.unwrap();
        unsafe { lumia_gigascan_free(pointer) };
        response
    }

    let related_dir = FixtureDir::new();
    let related = call(&request_for(&related_dir, 0));
    assert_eq!(related["ok"], true, "{related:#}");
    let report = &related["layout"]["report"];
    assert_eq!(
        report["edgeDiagnostics"][0]["selectedAttempt"],
        "lowContrast"
    );
    assert_eq!(report["edgeDiagnostics"][0]["initial"]["fromFeatures"], 0);
    assert_eq!(report["edgeDiagnostics"][0]["usedRetry"], true);
    assert!(report["globalRayReprojectionRmsPx"].as_f64().unwrap() < 12.0);

    let unrelated_dir = FixtureDir::new();
    let unrelated = call(&request_for(&unrelated_dir, 12_345));
    assert_eq!(unrelated["ok"], false, "{unrelated:#}");
    assert_eq!(unrelated["error"]["code"], "REGISTRATION_FAILED");
    assert_eq!(unrelated["error"]["diagnostics"]["connectedTileCount"], 1);
    assert_eq!(unrelated["error"]["diagnostics"]["totalTileCount"], 2);
}

#[test]
fn spherical_abi_registers_narrow_fov_views_at_twenty_percent_overlap() {
    const W: u32 = 640;
    const H: u32 = 480;
    const FX: f64 = 12_500.;
    const FY: f64 = 12_500.;
    const CX: f64 = (W as f64 - 1.) * 0.5;
    const CY: f64 = (H as f64 - 1.) * 0.5;
    let yaw_step = 0.8 * 2. * (W as f64 / (2. * FX)).atan();
    let pitch_step = 0.8 * 2. * (H as f64 / (2. * FY)).atan();
    let dir = FixtureDir::new();
    let mut tiles = Vec::new();
    for row in 0..3 {
        for column in 0..3 {
            let pose = camera_pose_at(row, column, yaw_step, pitch_step);
            let mut image = GrayImage::new(W, H);
            for y in 0..H {
                for x in 0..W {
                    let mut ray = [(x as f64 - CX) / FX, -(y as f64 - CY) / FY, 1.];
                    let n = (ray[0] * ray[0] + ray[1] * ray[1] + 1.).sqrt();
                    for value in &mut ray {
                        *value /= n;
                    }
                    let world = mul_vec(pose, ray);
                    image.put_pixel(
                        x,
                        y,
                        Luma([sphere_texture(
                            world[0].atan2(world[2]),
                            world[1].asin(),
                            32_768.,
                        )]),
                    );
                }
            }
            let path = dir.0.join(format!("tele_{row}_{column}.png"));
            image.save(&path).unwrap();
            tiles.push(json!({"row":row,"column":column,"path":path}));
        }
    }
    let request = CString::new(
        json!({"rows":3,"columns":3,"tiles":tiles,"fx":FX,"fy":FY,"cx":CX,"cy":CY,"sourceWidth":W,"sourceHeight":H})
            .to_string(),
    )
    .unwrap();
    let response_ptr = unsafe { lumia_gigascan_spherical_json(request.as_ptr()) };
    let response: Value =
        unsafe { serde_json::from_slice(CStr::from_ptr(response_ptr).to_bytes()) }.unwrap();
    unsafe { lumia_gigascan_free(response_ptr) };
    assert_eq!(response["ok"], true, "{response:#}");
    let layout = &response["layout"];
    let graph_rms_px = layout["report"]["orientationRmsPixelEquivalent"]
        .as_f64()
        .unwrap();
    println!("telephoto spherical graph RMS: {graph_rms_px:.4} px-equivalent");
    let reference = camera_pose_at(1, 1, yaw_step, pitch_step);
    for row in 0..3 {
        for column in 0..3 {
            let estimated: [f64; 9] =
                serde_json::from_value(layout["tiles"][row * 3 + column]["cameraToWorld"].clone())
                    .unwrap();
            let expected = mul(
                transpose(reference),
                camera_pose_at(row, column, yaw_step, pitch_step),
            );
            let mut max_corner_error = 0.0_f64;
            for (x, y) in [
                (CX, CY),
                (0., 0.),
                (W as f64 - 1., 0.),
                (0., H as f64 - 1.),
                (W as f64 - 1., H as f64 - 1.),
            ] {
                let source_ray = [(x - CX) / FX, -(y - CY) / FY, 1.];
                let world_ray = mul_vec(expected, source_ray);
                let estimated_ray = mul_vec(transpose(estimated), world_ray);
                let px = FX * estimated_ray[0] / estimated_ray[2] + CX;
                let py = CY - FY * estimated_ray[1] / estimated_ray[2];
                max_corner_error = max_corner_error.max((px - x).hypot(py - y));
            }
            println!("telephoto pose {row},{column} maximum center/corner error: {max_corner_error:.3} px");
            assert!(
                max_corner_error < 4.0,
                "telephoto pose {row},{column} reprojection error {max_corner_error:.3}px"
            );
        }
    }
}
