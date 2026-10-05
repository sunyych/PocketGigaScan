use crate::projection::{LensCalibration, Projection};
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CaptureGeometry {
    pub pan_deg: Option<f64>,
    pub tilt_deg: Option<f64>,
    pub fov_x_deg: Option<f64>,
    pub fov_y_deg: Option<f64>,
}
#[derive(Clone, Debug)]
pub struct CaptureTile {
    pub row: usize,
    pub column: usize,
    pub path: std::path::PathBuf,
    pub geometry: Option<CaptureGeometry>,
}
#[derive(Clone, Debug)]
pub struct StitchOptions {
    pub rows: usize,
    pub columns: usize,
    pub overlap_x: f32,
    pub overlap_y: f32,
    pub band_height: u32,
    pub min_features: usize,
    pub blend_power: u32,
    pub projection: Projection,
    pub lens_calibration: Option<LensCalibration>,
    pub lens_calibration_overrides_tile_fov: bool,
}
impl Default for StitchOptions {
    fn default() -> Self {
        Self {
            rows: 1,
            columns: 1,
            overlap_x: 0.2,
            overlap_y: 0.2,
            band_height: 32,
            min_features: 8,
            blend_power: 12,
            projection: Projection::Planar,
            lens_calibration: None,
            lens_calibration_overrides_tile_fov: false,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StitchEdgeReport {
    pub from_row: usize,
    pub from_column: usize,
    pub to_row: usize,
    pub to_column: usize,
    pub accepted: bool,
    pub nominal_fallback: bool,
    pub matches: usize,
    pub inliers: usize,
    pub inlier_ratio: f64,
    pub median_dx: f64,
    pub median_dy: f64,
    /// Row-major normalized homography mapping from-tile pixels to to-tile pixels.
    pub homography_from_to: [f64; 9],
    pub median_residual: f64,
    pub reason: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StitchReport {
    /// Actual geometry used by the renderer.
    pub geometry_model: String,
    /// Tile transforms rejected after propagation and replaced by translation.
    pub transform_fallback_count: usize,
    pub matched_edges: usize,
    pub nominal_fallback_edges: usize,
    pub failed_edges: usize,
    pub feature_count: usize,
    pub connected_tile_count: usize,
    pub total_tile_count: usize,
    pub registration_width: u32,
    pub registration_height: u32,
    pub connected: bool,
    pub visual_connected: bool,
    pub average_inlier_ratio: f64,
    pub median_residual: f64,
    pub p95_residual: f64,
    /// Fraction of output pixels covered by at least one valid source sample.
    pub coverage: f64,
    /// Fraction of output pixels not covered by a valid source sample.
    pub transparent_gap_ratio: f64,
    pub render_duration_ms: u64,
    pub output_width: u32,
    pub output_height: u32,
    pub memory_strategy: String,
    pub edges: Vec<StitchEdgeReport>,
    pub warnings: Vec<String>,
}
