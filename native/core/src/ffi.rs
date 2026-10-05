//! Small, versioned C ABI for the PTZ Manager consumer.
//!
//! The ABI deliberately carries one UTF-8 JSON request and one UTF-8 JSON
//! response. This keeps the Dart boundary independent from Rust layout and
//! lets the report grow without changing a native struct. The stitch itself
//! remains the normal [`crate::StitchJob`] pipeline; this module is only an
//! ownership and serialization boundary.

use crate::{
    projection::{DistortionCoefficients, LensCalibration, Projection},
    scan::{Fov, Grid, Pose, Roi, ScanPlanner, ScanRequest, Traversal},
    CaptureGeometry, CaptureTile, StitchJob, StitchOptions, StitchReport,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    path::PathBuf,
};

pub const ABI_VERSION: u32 = 1;

/// Callback invoked synchronously by `lumia_gigascan_stitch_json`.
///
/// The callback receives pointers valid only for the duration of the call.
/// `user_data` is passed through untouched and is never dereferenced by Core.
pub type ProgressCallback =
    unsafe extern "C" fn(stage: *const c_char, fraction: f32, user_data: *mut c_void);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    rows: usize,
    columns: usize,
    overlap_x: f32,
    overlap_y: f32,
    #[serde(default = "default_band_height")]
    band_height: u32,
    #[serde(default = "default_min_features")]
    min_features: usize,
    #[serde(default = "default_blend_power")]
    blend_power: u32,
    #[serde(default)]
    tiles: Vec<TileRequest>,
    #[serde(default)]
    output_path: String,
    /// Application presentation options are accepted here so the ABI can be
    /// used by the calibrated PTZ path. The engine consumes them when the
    /// corresponding Core options are available; keeping them in the request
    /// schema prevents a caller from silently losing its intent.
    #[serde(default)]
    quality: Option<String>,
    #[serde(default)]
    projection: Option<String>,
    #[serde(default)]
    pan_span_degrees: Option<f64>,
    #[serde(default)]
    tilt_span_degrees: Option<f64>,
    #[serde(default)]
    calibration: Option<Value>,
    #[serde(default)]
    lens_profile: Option<LensProfileRequest>,
    #[serde(default)]
    render_backend_preference: Option<String>,
}

fn default_band_height() -> u32 {
    32
}
fn default_min_features() -> usize {
    8
}
fn default_blend_power() -> u32 {
    12
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TileRequest {
    row: usize,
    column: usize,
    path: String,
    geometry: Option<CaptureGeometry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LensProfileRequest {
    source_resolution: SourceResolutionRequest,
    intrinsics: IntrinsicsRequest,
    #[serde(default)]
    distortion: DistortionRequest,
}

#[derive(Debug, Deserialize)]
struct SourceResolutionRequest {
    width: u32,
    height: u32,
}

#[derive(Debug, Deserialize)]
struct IntrinsicsRequest {
    fx: f64,
    fy: f64,
    #[serde(default = "default_principal_point")]
    cx: f64,
    #[serde(default = "default_principal_point")]
    cy: f64,
}

#[derive(Clone, Copy, Debug, Default, Deserialize)]
struct DistortionRequest {
    #[serde(default)]
    k1: f64,
    #[serde(default)]
    k2: f64,
    #[serde(default)]
    k3: f64,
    #[serde(default)]
    p1: f64,
    #[serde(default)]
    p2: f64,
}

fn default_principal_point() -> f64 {
    0.5
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanRequest {
    source: PlanPose,
    source_fov: PlanFov,
    roi: PlanRoi,
    target_fov: PlanFov,
    overlap_x: f64,
    overlap_y: f64,
    grid: PlanGrid,
    #[serde(default)]
    traversal: PlanTraversal,
    estimated_bytes_per_tile: u64,
    maximum_tiles: usize,
}

#[derive(Debug, Deserialize)]
struct PlanPose {
    pan: f64,
    tilt: f64,
    zoom: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanFov {
    horizontal: f64,
    vertical: f64,
    mechanical_pan: f64,
    mechanical_tilt: f64,
}

#[derive(Debug, Deserialize)]
struct PlanRoi {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "mode", rename_all = "camelCase")]
enum PlanGrid {
    Auto,
    Explicit { rows: usize, columns: usize },
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
enum PlanTraversal {
    #[default]
    Snake,
    RowByRow,
    ColumnByColumn,
}

fn response_error(code: &str, message: impl ToString) -> Value {
    json!({
        "ok": false,
        "error": { "code": code, "message": message.to_string() },
        "abiVersion": ABI_VERSION,
    })
}

fn response_json(value: Value) -> *mut c_char {
    // JSON serialization of the response is infallible for the Value values
    // constructed here. Return a valid error object even if that assumption
    // is ever broken by a future report field.
    let text = serde_json::to_string(&value).unwrap_or_else(|error| {
        serde_json::to_string(&response_error("SERIALIZATION", error))
            .unwrap_or_else(|_| r#"{"ok":false,"error":{"code":"SERIALIZATION"}}"#.to_owned())
    });
    CString::new(text)
        .unwrap_or_else(|_| {
            CString::new(r#"{"ok":false,"error":{"code":"SERIALIZATION"}}"#).unwrap()
        })
        .into_raw()
}

fn finite(value: f64) -> f64 {
    if value.is_finite() {
        value
    } else {
        0.0
    }
}

fn quality_report(
    report: &StitchReport,
    projection: &str,
    render_backend_preference: &str,
    render_backend_fallback: bool,
    blend_power: u32,
) -> Value {
    let residuals = report
        .edges
        .iter()
        .filter(|edge| edge.accepted && !edge.nominal_fallback && edge.median_residual.is_finite())
        .map(|edge| edge.median_residual)
        .collect::<Vec<_>>();
    let average_residual = if residuals.is_empty() {
        0.0
    } else {
        residuals.iter().sum::<f64>() / residuals.len() as f64
    };
    let maximum_residual = residuals.iter().copied().fold(0.0, f64::max);
    json!({
        "geometryModel": report.geometry_model,
        "transformFallbackCount": report.transform_fallback_count,
        "matchedEdges": report.matched_edges,
        "visualMatchedEdges": report.matched_edges,
        "nominalFallbackEdges": report.nominal_fallback_edges,
        "failedEdges": report.failed_edges,
        "resolvedEdgeCount": report.matched_edges + report.nominal_fallback_edges,
        "averageConfidence": finite(report.average_inlier_ratio),
        "averageReprojectionError": finite(average_residual),
        "maximumReprojectionError": finite(maximum_residual),
        "globalOptimizationResidual": finite(report.p95_residual),
        "medianReprojectionError": finite(report.median_residual),
        "p95ReprojectionError": finite(report.p95_residual),
        "residualSemantics": "thumbnail pair-registration residual; not final rendered-coordinate error",
        "coverage": finite(report.coverage),
        "transparentGapRatio": finite(report.transparent_gap_ratio),
        "connectedTileCount": report.connected_tile_count,
        "totalTileCount": report.total_tile_count,
        "renderDurationMs": report.render_duration_ms,
        "outputWidth": report.output_width,
        "outputHeight": report.output_height,
        "backend": "lumia-gigascan-core",
        "renderBackend": "cpu-rust-banded",
        "renderBackendPreference": render_backend_preference,
        "renderBackendFallback": render_backend_fallback,
        "blendModel": format!("high-order-geometric-feather-{blend_power}"),
        "projection": projection,
    })
}

unsafe fn request_from_ptr(request: *const c_char) -> Result<Request, String> {
    if request.is_null() {
        return Err("request pointer is null".to_owned());
    }
    let bytes = CStr::from_ptr(request).to_bytes();
    serde_json::from_slice(bytes).map_err(|error| format!("invalid request JSON: {error}"))
}

unsafe fn plan_request_from_ptr(request: *const c_char) -> Result<PlanRequest, String> {
    if request.is_null() {
        return Err("request pointer is null".to_owned());
    }
    let bytes = CStr::from_ptr(request).to_bytes();
    serde_json::from_slice(bytes).map_err(|error| format!("invalid plan request JSON: {error}"))
}

fn run_plan_request(request: PlanRequest) -> Value {
    let grid = match request.grid {
        PlanGrid::Auto => Grid::Auto,
        PlanGrid::Explicit { rows, columns } => Grid::Explicit { rows, columns },
    };
    let traversal = match request.traversal {
        PlanTraversal::Snake => Traversal::Snake,
        PlanTraversal::RowByRow => Traversal::RowByRow,
        PlanTraversal::ColumnByColumn => Traversal::ColumnByColumn,
    };
    let plan = ScanPlanner::plan(ScanRequest {
        source: Pose {
            pan: request.source.pan,
            tilt: request.source.tilt,
            zoom: request.source.zoom,
        },
        source_fov: Fov {
            horizontal: request.source_fov.horizontal,
            vertical: request.source_fov.vertical,
            mechanical_pan: request.source_fov.mechanical_pan,
            mechanical_tilt: request.source_fov.mechanical_tilt,
        },
        roi: Roi::new(
            request.roi.left,
            request.roi.top,
            request.roi.right,
            request.roi.bottom,
        ),
        target_fov: Fov {
            horizontal: request.target_fov.horizontal,
            vertical: request.target_fov.vertical,
            mechanical_pan: request.target_fov.mechanical_pan,
            mechanical_tilt: request.target_fov.mechanical_tilt,
        },
        overlap_x: request.overlap_x,
        overlap_y: request.overlap_y,
        grid,
        traversal,
        estimated_bytes_per_tile: request.estimated_bytes_per_tile,
        maximum_tiles: request.maximum_tiles,
    });
    match plan {
        Ok(plan) => json!({
            "ok": true,
            "abiVersion": ABI_VERSION,
            "plan": {
                "rows": plan.rows,
                "columns": plan.columns,
                "estimatedBytes": plan.estimated_bytes,
                "horizontalStep": plan.horizontal_step,
                "verticalStep": plan.vertical_step,
                "tiles": plan.tiles.into_iter().map(|tile| json!({
                    "sequence": tile.sequence,
                    "row": tile.row,
                    "column": tile.column,
                    "pose": {
                        "pan": tile.pose.pan,
                        "tilt": tile.pose.tilt,
                        "zoom": tile.pose.zoom,
                    },
                })).collect::<Vec<_>>(),
            },
        }),
        Err(error) => response_error("INVALID_PLAN", error),
    }
}

fn select_projection(
    requested: Option<&str>,
    pan_span_degrees: Option<f64>,
    tilt_span_degrees: Option<f64>,
) -> Result<Projection, String> {
    match requested
        .unwrap_or("AUTOMATIC")
        .to_ascii_uppercase()
        .as_str()
    {
        "PLANAR" => Ok(Projection::Planar),
        "CYLINDRICAL" => Ok(Projection::Cylindrical),
        "SPHERICAL" => Ok(Projection::Spherical),
        "AUTOMATIC" => {
            let pan = pan_span_degrees.unwrap_or(0.0).abs();
            let tilt = tilt_span_degrees.unwrap_or(0.0).abs();
            if tilt >= 30.0 {
                Ok(Projection::Spherical)
            } else if pan >= 60.0 {
                Ok(Projection::Cylindrical)
            } else {
                Ok(Projection::Planar)
            }
        }
        _ => Err("projection must be AUTOMATIC, PLANAR, CYLINDRICAL, or SPHERICAL".into()),
    }
}

fn calibration_from_profile(profile: &LensProfileRequest) -> Result<LensCalibration, String> {
    let width = f64::from(profile.source_resolution.width);
    let height = f64::from(profile.source_resolution.height);
    if width <= 0.0
        || height <= 0.0
        || !profile.intrinsics.fx.is_finite()
        || !profile.intrinsics.fy.is_finite()
        || profile.intrinsics.fx <= 0.0
        || profile.intrinsics.fy <= 0.0
    {
        return Err("lensProfile source resolution and fx/fy must be positive".into());
    }
    let fov_x = 2.0 * (width / (2.0 * profile.intrinsics.fx)).atan().to_degrees();
    let fov_y = 2.0 * (height / (2.0 * profile.intrinsics.fy)).atan().to_degrees();
    let distortion = profile.distortion;
    let calibration = LensCalibration {
        horizontal_fov_deg: Some(fov_x),
        vertical_fov_deg: Some(fov_y),
        distortion: Some(DistortionCoefficients {
            k1: distortion.k1,
            k2: distortion.k2,
            p1: distortion.p1,
            p2: distortion.p2,
            k3: distortion.k3,
        }),
        principal_point: Some((profile.intrinsics.cx, profile.intrinsics.cy)),
    };
    calibration.validate().map_err(|error| error.to_string())?;
    Ok(calibration)
}

fn calibration_from_camera_profile(
    value: Option<&Value>,
) -> Result<Option<LensCalibration>, String> {
    let Some(value) = value else {
        return Ok(None);
    };
    let number = |key: &str| value.get(key).and_then(Value::as_f64);
    let distortion = value.get("distortion");
    let coefficient = |key: &str| {
        distortion
            .and_then(|entry| entry.get(key))
            .and_then(Value::as_f64)
            .unwrap_or(0.0)
    };
    let calibration = LensCalibration {
        horizontal_fov_deg: number("horizontalFovAt1x"),
        vertical_fov_deg: number("verticalFovAt1x"),
        distortion: Some(DistortionCoefficients {
            k1: coefficient("k1"),
            k2: coefficient("k2"),
            p1: coefficient("p1"),
            p2: coefficient("p2"),
            k3: coefficient("k3"),
        }),
        principal_point: Some((
            number("principalPointX").unwrap_or(0.5),
            number("principalPointY").unwrap_or(0.5),
        )),
    };
    calibration.validate().map_err(|error| error.to_string())?;
    Ok(Some(calibration))
}

fn run_request(
    request: Request,
    callback: Option<ProgressCallback>,
    user_data: *mut c_void,
    register_only: bool,
) -> Value {
    if request.rows == 0 || request.columns == 0 {
        return response_error("INVALID_ARGUMENT", "rows and columns must be positive");
    }
    if !register_only && request.output_path.trim().is_empty() {
        return response_error("INVALID_ARGUMENT", "outputPath must not be empty");
    }
    if !(1..=32).contains(&request.blend_power) {
        return response_error("INVALID_ARGUMENT", "blendPower must be between 1 and 32");
    }
    if request.tiles.len() != request.rows.saturating_mul(request.columns) {
        return response_error(
            "INVALID_GRID",
            format!(
                "expected {} tiles, got {}",
                request.rows.saturating_mul(request.columns),
                request.tiles.len()
            ),
        );
    }
    let requested_quality = request.quality.clone();
    let requested_pan_span = request.pan_span_degrees.is_some();
    let requested_tilt_span = request.tilt_span_degrees.is_some();
    let render_backend_preference = request
        .render_backend_preference
        .as_deref()
        .unwrap_or("cpuOnly");
    if !matches!(
        render_backend_preference,
        "gpuPreferred" | "cpuOnly" | "automatic"
    ) {
        return response_error(
            "INVALID_ARGUMENT",
            "renderBackendPreference must be gpuPreferred, cpuOnly, or automatic",
        );
    }
    let render_backend_fallback = render_backend_preference == "gpuPreferred";
    let projection = match select_projection(
        request.projection.as_deref(),
        request.pan_span_degrees,
        request.tilt_span_degrees,
    ) {
        Ok(value) => value,
        Err(error) => return response_error("INVALID_ARGUMENT", error),
    };
    let lens_profile_overrides_tile_fov = request.lens_profile.is_some();
    let lens_calibration = match request.lens_profile.as_ref() {
        Some(profile) => match calibration_from_profile(profile) {
            Ok(value) => Some(value),
            Err(error) => return response_error("INVALID_ARGUMENT", error),
        },
        None => match calibration_from_camera_profile(request.calibration.as_ref()) {
            Ok(value) => value,
            Err(error) => return response_error("INVALID_ARGUMENT", error),
        },
    };

    let options = StitchOptions {
        rows: request.rows,
        columns: request.columns,
        overlap_x: request.overlap_x,
        overlap_y: request.overlap_y,
        band_height: request.band_height,
        min_features: request.min_features,
        blend_power: request.blend_power,
        projection,
        lens_calibration,
        lens_calibration_overrides_tile_fov: lens_profile_overrides_tile_fov,
    };
    let mut job = StitchJob::new(options);
    for tile in request.tiles {
        let path = PathBuf::from(tile.path);
        if let Err(error) = job.add_tile(CaptureTile {
            row: tile.row,
            column: tile.column,
            path,
            geometry: tile.geometry,
        }) {
            return response_error("INVALID_TILE", error);
        }
    }
    if register_only {
        return match job.register_only() {
            Ok(report) => json!({"ok": true, "abiVersion": ABI_VERSION,
                "registrationOnly": true, "report": report, "alignment": report}),
            Err(error) => json!({"ok": false, "abiVersion": ABI_VERSION,
                "error": {"code": error_code(&error), "message": error.to_string()},
                "report": job.diagnostic_snapshot()}),
        };
    }
    let output = PathBuf::from(request.output_path);
    let result = job.run(&output, |progress| {
        if let Some(callback) = callback {
            let Ok(stage) = CString::new(progress.stage) else {
                return;
            };
            unsafe {
                callback(stage.as_ptr(), progress.fraction, user_data);
            }
        }
    });
    match result {
        Ok(result) => {
            let mut report_value = result.report.clone();
            if requested_quality.is_some() {
                report_value.warnings.push(
                    "quality preset is accepted by ABI v1 but is not yet applied by the renderer"
                        .into(),
                );
            }
            if requested_pan_span || requested_tilt_span {
                report_value.warnings.push(
                    "pan/tilt spans are accepted by ABI v1 but are currently diagnostic only"
                        .into(),
                );
            }
            if render_backend_fallback {
                report_value.warnings.push(
                    "GPU rendering was preferred but no GPU backend is linked; used cpu-rust-banded"
                        .into(),
                );
            }
            let actual_projection = match projection {
                Projection::Planar => "planarPairwiseHomographyDeghostFeather",
                Projection::Cylindrical => "cylindricalPairwiseHomographyDeghostFeather",
                Projection::Spherical => "sphericalPairwiseHomographyDeghostFeather",
            };
            let report = serde_json::to_value(&report_value).unwrap_or_else(|_| json!({}));
            let quality = quality_report(
                &report_value,
                actual_projection,
                render_backend_preference,
                render_backend_fallback,
                request.blend_power,
            );
            json!({
                "ok": true,
                "abiVersion": ABI_VERSION,
                "width": result.width,
                "height": result.height,
                "partial": result.partial,
                "report": report.clone(),
                "alignment": report,
                "qualityReport": quality,
            })
        }
        Err(error) => {
            let snapshot =
                serde_json::to_value(job.diagnostic_snapshot()).unwrap_or_else(|_| json!({}));
            json!({
                "ok": false,
                "abiVersion": ABI_VERSION,
                "error": { "code": error_code(&error), "message": error.to_string() },
                "report": snapshot,
            })
        }
    }
}

fn error_code(error: &crate::Error) -> &'static str {
    match error {
        crate::Error::Cancelled => "CANCELLED",
        crate::Error::Decode(_) => "DECODE_ERROR",
        crate::Error::Invalid(_) => "INVALID_ARGUMENT",
        crate::Error::Registration(_) => "REGISTRATION_FAILED",
        crate::Error::RegistrationReport { .. } => "REGISTRATION_FAILED",
        crate::Error::Io(_) => "IO_ERROR",
    }
}

/// Returns the ABI number used by the PTZ Manager loader.
#[no_mangle]
pub extern "C" fn lumia_gigascan_abi_version() -> u32 {
    ABI_VERSION
}

/// Runs one complete Core stitch from a JSON request.
///
/// The returned pointer is owned by the caller and must be released with
/// [`lumia_gigascan_free`]. A null request never panics and returns an error
/// response. Rust panics are contained at this boundary so a malformed input
/// cannot unwind through Dart FFI.
#[no_mangle]
/// # Safety
/// `request` must point to a NUL-terminated UTF-8 JSON string for the duration
/// of this call. If `callback` is supplied, it must remain valid for the call
/// and may only retain the stage pointer during the callback invocation.
pub unsafe extern "C" fn lumia_gigascan_stitch_json(
    request: *const c_char,
    callback: Option<ProgressCallback>,
    user_data: *mut c_void,
) -> *mut c_char {
    let value = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let request = unsafe { request_from_ptr(request) };
        match request {
            Ok(request) => run_request(request, callback, user_data, false),
            Err(error) => response_error("INVALID_REQUEST", error),
        }
    }));
    response_json(match value {
        Ok(response) => response,
        Err(_) => response_error("PANIC", "Core panicked while processing the stitch request"),
    })
}

/// Registers tiles without rendering. Output path is optional and ignored.
/// Return ownership is identical to `lumia_gigascan_stitch_json`.
/// # Safety
/// `request` must be a valid NUL-terminated UTF-8 string for this call, or null.
#[no_mangle]
pub unsafe extern "C" fn lumia_gigascan_register_json(request: *const c_char) -> *mut c_char {
    let value = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        match unsafe { request_from_ptr(request) } {
            Ok(request) => run_request(request, None, std::ptr::null_mut(), true),
            Err(error) => response_error("INVALID_REQUEST", error),
        }
    }));
    response_json(match value {
        Ok(response) => response,
        Err(_) => response_error("PANIC", "Core panicked while registering tiles"),
    })
}

/// Estimates globally consistent camera rotations and emits the spherical
/// camera-layout JSON contract. It does not render or return a planar mosaic.
/// # Safety
/// `request` must be a valid NUL-terminated UTF-8 JSON string for this call, or null.
#[no_mangle]
pub unsafe extern "C" fn lumia_gigascan_spherical_json(request: *const c_char) -> *mut c_char {
    let value = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if request.is_null() {
            return response_error("INVALID_REQUEST", "request pointer is null");
        }
        let bytes = unsafe { CStr::from_ptr(request) }.to_bytes();
        match std::str::from_utf8(bytes) {
            Ok(input) => match crate::spherical::align_json_detailed(input) {
                Ok(layout) => json!({"ok": true, "layout": layout}),
                Err(failure) => {
                    let mut response = response_error(failure.code, failure.message);
                    if let Some(diagnostics) = failure.diagnostics {
                        response["error"]["diagnostics"] = diagnostics;
                    }
                    response
                }
            },
            Err(error) => response_error("INVALID_REQUEST", error),
        }
    }));
    response_json(
        value.unwrap_or_else(|_| {
            response_error("PANIC", "Core panicked during spherical alignment")
        }),
    )
}

/// Starts or controls an asynchronous persistent spherical rendering job.
/// Response ownership is identical to the other JSON entry points.
/// # Safety
/// `request` must be a valid NUL-terminated UTF-8 JSON string for this call, or null.
#[no_mangle]
pub unsafe extern "C" fn lumia_gigascan_job_json(request: *const c_char) -> *mut c_char {
    let value = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if request.is_null() {
            return response_error("INVALID_REQUEST", "request pointer is null");
        }
        match std::str::from_utf8(unsafe { CStr::from_ptr(request) }.to_bytes()) {
            Ok(input) => crate::job::handle(input),
            Err(error) => response_error("INVALID_REQUEST", error),
        }
    }));
    response_json(value.unwrap_or_else(|_| response_error("PANIC", "Core panicked in job API")))
}

/// Produces a device-independent scan plan from a UTF-8 JSON request.
///
/// The returned pointer follows the same ownership rule as
/// [`lumia_gigascan_stitch_json`].
#[no_mangle]
/// # Safety
/// `request` must point to a NUL-terminated UTF-8 JSON string for the duration
/// of this call.
pub unsafe extern "C" fn lumia_gigascan_plan_json(request: *const c_char) -> *mut c_char {
    let value = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        match unsafe { plan_request_from_ptr(request) } {
            Ok(request) => run_plan_request(request),
            Err(error) => response_error("INVALID_REQUEST", error),
        }
    }));
    response_json(match value {
        Ok(response) => response,
        Err(_) => response_error("PANIC", "Core panicked while planning the scan"),
    })
}

/// Releases a response returned by [`lumia_gigascan_stitch_json`].
///
/// # Safety
/// `value` must be null or a pointer returned by a Lumia GigaScan JSON ABI
/// function that has not already been freed.
#[no_mangle]
pub unsafe extern "C" fn lumia_gigascan_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

/// Backwards-compatible alias for consumers that use an explicit JSON suffix.
///
/// # Safety
/// `value` follows the same ownership rules as [`lumia_gigascan_free`].
#[no_mangle]
pub unsafe extern "C" fn lumia_gigascan_free_json(value: *mut c_char) {
    lumia_gigascan_free(value);
}

/// Null-safe helper used by native smoke tests to check the ABI symbol.
#[no_mangle]
pub extern "C" fn lumia_gigascan_is_available() -> u32 {
    1
}

#[allow(dead_code)]
fn _assert_send(_: *mut c_void) {}
