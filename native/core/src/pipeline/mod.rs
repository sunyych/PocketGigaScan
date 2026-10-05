mod register;
pub(crate) use register::spherical_extract_features_parallel;
#[cfg(test)]
pub(crate) use register::spherical_neighbor_pairs;
pub(crate) use register::{spherical_overlap_matches, GridOverlapMatch};
mod render;

pub use register::{ProjectiveTransform, Registration};
pub(crate) use register::{SphericalMatchAttempt, SphericalMatchEdge};
pub use render::{render_banded, render_banded_with_overlay, OutputOverlay};

use crate::{
    metadata::{CaptureTile, StitchOptions, StitchReport},
    projection::{LensCalibration, Projection, ProjectionOptions},
    Error, Result,
};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};

#[derive(Clone, Debug)]
pub struct Progress {
    pub stage: String,
    pub fraction: f32,
}
#[derive(Clone, Default)]
pub struct CancellationToken(Arc<AtomicBool>);
impl CancellationToken {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
}
#[derive(Debug)]
pub struct StitchResult {
    pub width: u32,
    pub height: u32,
    pub report: StitchReport,
    pub partial: bool,
}

pub struct StitchJob {
    opts: StitchOptions,
    tiles: Vec<CaptureTile>,
    features: Vec<register::NativeFeatures>,
    projection_scratch: Option<ProjectionScratch>,
    cancel: CancellationToken,
    last_report: Mutex<StitchReport>,
}

impl StitchJob {
    pub fn new(opts: StitchOptions) -> Self {
        let report = empty_report();
        Self {
            opts,
            tiles: Vec::new(),
            features: Vec::new(),
            projection_scratch: None,
            cancel: CancellationToken::default(),
            last_report: Mutex::new(report),
        }
    }
    pub fn cancellation_token(&self) -> CancellationToken {
        self.cancel.clone()
    }
    /// Returns the latest report even when `run` failed. This is intentionally a
    /// snapshot so callers can persist failure diagnostics after cancellation.
    pub fn diagnostic_snapshot(&self) -> StitchReport {
        self.last_report
            .lock()
            .map(|r| r.clone())
            .unwrap_or_else(|_| empty_report())
    }
    pub fn add_tile(&mut self, tile: CaptureTile) -> Result<()> {
        self.add_tile_with_feature_budget(tile, 120_000).map(|_| ())
    }

    /// Adds a tile using a caller-selected bounded pixel budget for SIFT.
    /// Existing consumers keep the original 120,000-pixel default via
    /// [`StitchJob::add_tile`]. The returned dimensions are those of the input.
    pub fn add_tile_with_feature_budget(
        &mut self,
        tile: CaptureTile,
        feature_pixel_budget: usize,
    ) -> Result<(u32, u32)> {
        self.add_tile_with_feature_settings(tile, feature_pixel_budget, 0)
    }

    /// Adds a tile with explicit SIFT resolution and native worker-thread
    /// budgets. A zero thread limit preserves OpenCV's process default.
    pub fn add_tile_with_feature_settings(
        &mut self,
        tile: CaptureTile,
        feature_pixel_budget: usize,
        feature_thread_limit: i32,
    ) -> Result<(u32, u32)> {
        if tile.path.as_os_str().is_empty() {
            return Err(Error::Invalid("empty tile path".into()));
        }
        // Decode once here so the native cache cannot hide a corrupt source
        // until a much later registration stage. Valid low-texture images are
        // retained with an empty SIFT frame and rejected by the graph gate.
        let source = crate::image::load(&tile.path)?;
        let source_dimensions = (source.width(), source.height());
        let tile = if source_needs_projection(&self.opts) {
            let calibration = calibration_for_tile(
                self.opts.lens_calibration,
                self.opts.lens_calibration_overrides_tile_fov,
                &tile,
            );
            let projected = crate::projection::project_image(
                &::image::DynamicImage::ImageRgba8(source),
                ProjectionOptions {
                    projection: self.opts.projection,
                    calibration,
                },
            )?;
            if self.projection_scratch.is_none() {
                self.projection_scratch = Some(ProjectionScratch::new()?);
            }
            let scratch = self
                .projection_scratch
                .as_ref()
                .ok_or_else(|| Error::Invalid("projection scratch is unavailable".into()))?;
            let path = scratch.path.join(format!(
                "tile-{}-{}-{}.png",
                tile.row,
                tile.column,
                self.tiles.len()
            ));
            projected.save(&path)?;
            CaptureTile { path, ..tile }
        } else {
            drop(source);
            tile
        };
        let features = register::NativeFeatures::from_path_with_settings(
            &tile.path,
            feature_pixel_budget,
            feature_thread_limit,
        );
        if !features.is_valid() {
            return Err(Error::Invalid(format!(
                "native feature extraction failed: {}",
                tile.path.display()
            )));
        }
        self.features.push(features);
        self.tiles.push(tile);
        if let Ok(mut report) = self.last_report.lock() {
            report.feature_count = self.features.iter().map(register::feature_count).sum();
        }
        Ok(source_dimensions)
    }

    pub(crate) fn add_precomputed_tile(
        &mut self,
        tile: CaptureTile,
        features: register::NativeFeatures,
    ) -> Result<()> {
        if tile.path.as_os_str().is_empty() || !features.is_valid() {
            return Err(Error::Invalid("invalid precomputed spherical tile".into()));
        }
        self.features.push(features);
        self.tiles.push(tile);
        if let Ok(mut report) = self.last_report.lock() {
            report.feature_count = self.features.iter().map(register::feature_count).sum();
        }
        Ok(())
    }
    pub fn process_features(&self) -> Result<usize> {
        Ok(self.features.iter().map(register::feature_count).sum())
    }

    pub(crate) fn spherical_match_edges(
        mut self,
        maximum_pixels: usize,
        thread_limit: i32,
        retry_contrast_threshold: f64,
        neighbor_mode: &str,
        matching_workers: usize,
        feature_type: &str,
        matcher_type: &str,
        checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
    ) -> Result<(
        usize,
        usize,
        usize,
        usize,
        usize,
        usize,
        usize,
        usize,
        u64,
        u64,
        u64,
        Vec<register::SphericalMatchEdge>,
    )> {
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let edges = register::spherical_match_edges(
            self.opts.rows,
            self.opts.columns,
            &self.tiles,
            std::mem::take(&mut self.features),
            maximum_pixels,
            thread_limit,
            retry_contrast_threshold,
            neighbor_mode,
            matching_workers,
            feature_type,
            matcher_type,
            checkpoint,
        )?;
        let (
            edges,
            primary,
            retry,
            retry_endpoints,
            peak_retry,
            peak_retry_frames,
            clahe,
            peak_clahe,
            peak_clahe_frames,
            initial_matching_ms,
            low_contrast_retry_ms,
            clahe_retry_ms,
        ) = edges;
        Ok((
            primary,
            retry,
            retry_endpoints,
            peak_retry,
            peak_retry_frames,
            clahe,
            peak_clahe,
            peak_clahe_frames,
            initial_matching_ms,
            low_contrast_retry_ms,
            clahe_retry_ms,
            edges,
        ))
    }

    /// Compute alignment only; never renders or publishes a panorama.
    pub fn register_only(&self) -> Result<StitchReport> {
        if self.tiles.is_empty() || self.opts.rows == 0 || self.opts.columns == 0 {
            return Err(Error::Invalid(
                "nonempty tiles and positive grid dimensions required".into(),
            ));
        }
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        if self.tiles.len() == 1 && register::feature_count(&self.features[0]) == 0 {
            return Err(Error::Invalid(
                "source image contains no SIFT features".into(),
            ));
        }
        match register::Registration::compute(
            self.opts.clone(),
            &self.tiles,
            &self.features,
            &self.cancel,
        ) {
            Ok(reg) => {
                self.set_report(reg.report.clone());
                Ok(reg.report)
            }
            Err(error) => {
                self.update_report_from_error(&error);
                Err(error)
            }
        }
    }

    pub fn run<F: FnMut(Progress)>(
        &self,
        output: &std::path::Path,
        mut cb: F,
    ) -> Result<StitchResult> {
        if self.tiles.is_empty() {
            return Err(Error::Invalid("no tiles".into()));
        }
        if self.opts.rows == 0 || self.opts.columns == 0 {
            return Err(Error::Invalid("rows and columns must be positive".into()));
        }
        if self.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        if self.tiles.len() == 1 && register::feature_count(&self.features[0]) == 0 {
            let error = Error::Invalid("source image contains no SIFT features".into());
            self.update_report_from_error(&error);
            return Err(error);
        }
        cb(Progress {
            stage: "features_cached".into(),
            fraction: 0.20,
        });
        let reg = match register::Registration::compute(
            self.opts.clone(),
            &self.tiles,
            &self.features,
            &self.cancel,
        ) {
            Ok(reg) => reg,
            Err(e) => {
                self.update_report_from_error(&e);
                return Err(e);
            }
        };
        self.set_report(reg.report.clone());
        cb(Progress {
            stage: "registration".into(),
            fraction: 0.60,
        });
        let mut render_progress = |p: Progress| {
            cb(Progress {
                stage: p.stage,
                fraction: 0.60 + p.fraction.clamp(0.0, 1.0) * 0.40,
            })
        };
        match render::render_banded_configured(
            &self.tiles,
            &reg,
            render::RenderConfig {
                band_height: self.opts.band_height,
                blend_power: self.opts.blend_power,
                overlay: None,
            },
            output,
            &self.cancel,
            &mut render_progress,
        ) {
            Ok((report, width, height)) => {
                self.set_report(report.clone());
                Ok(StitchResult {
                    width,
                    height,
                    partial: false,
                    report,
                })
            }
            Err(e) => {
                self.update_report_from_error(&e);
                Err(e)
            }
        }
    }
    fn set_report(&self, report: StitchReport) {
        if let Ok(mut slot) = self.last_report.lock() {
            *slot = report;
        }
    }
    fn update_report_from_error(&self, error: &Error) {
        if let Ok(mut report) = self.last_report.lock() {
            if let Error::RegistrationReport {
                report: detailed, ..
            } = error
            {
                *report = (**detailed).clone();
            }
            report.warnings.push(error.to_string());
        }
    }
}

fn source_needs_projection(opts: &StitchOptions) -> bool {
    opts.projection != Projection::Planar
        || opts
            .lens_calibration
            .is_some_and(|value| value.distortion.is_some_and(|d| !d.is_identity()))
}

fn calibration_for_tile(
    calibration: Option<LensCalibration>,
    overrides_tile_fov: bool,
    tile: &CaptureTile,
) -> Option<LensCalibration> {
    let mut calibration = calibration?;
    if !overrides_tile_fov {
        if let Some(geometry) = tile.geometry.as_ref() {
            calibration.horizontal_fov_deg = geometry.fov_x_deg.or(calibration.horizontal_fov_deg);
            calibration.vertical_fov_deg = geometry.fov_y_deg.or(calibration.vertical_fov_deg);
        }
    }
    Some(calibration)
}

struct ProjectionScratch {
    path: PathBuf,
}

impl ProjectionScratch {
    fn new() -> Result<Self> {
        let suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |value| value.as_nanos());
        let path = std::env::temp_dir().join(format!(
            "lumia-gigascan-projection-{}-{suffix}",
            std::process::id()
        ));
        std::fs::create_dir_all(&path)?;
        Ok(Self { path })
    }
}

impl Drop for ProjectionScratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn empty_report() -> StitchReport {
    StitchReport {
        geometry_model: "pairwise-homography+confidence-tree-projective".into(),
        transform_fallback_count: 0,
        matched_edges: 0,
        nominal_fallback_edges: 0,
        failed_edges: 0,
        feature_count: 0,
        connected_tile_count: 0,
        total_tile_count: 0,
        registration_width: 0,
        registration_height: 0,
        connected: false,
        visual_connected: false,
        average_inlier_ratio: 0.0,
        median_residual: f64::NAN,
        p95_residual: f64::NAN,
        coverage: 0.0,
        transparent_gap_ratio: 1.0,
        render_duration_ms: 0,
        output_width: 0,
        output_height: 0,
        memory_strategy: "disk-spool+bounded-output-and-source-bands+sift-cache".into(),
        edges: Vec::new(),
        warnings: Vec::new(),
    }
}
