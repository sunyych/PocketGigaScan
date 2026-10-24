//! Portable, tiled spherical renderer for persisted camera layouts.
//!
//! The renderer deliberately has no OpenCV/GPU dependency. It consumes the
//! spherical JSON layout emitted by `spherical::align_json_detailed`.
use crate::seam_ownership::{
    adjust_candidates_for_content, coarse_cell_count, coarse_stride, content_disagreement,
    regularize_owners, scene_blend_override, CoarseOwnershipMap, OwnershipCandidate,
    SceneBlendOverride,
};
use crate::texture_warp::{
    corrected_to_source, validate_source_plane_warp, SourcePlaneWarp,
    SOURCE_WARP_MAX_DISPLACEMENT_PX,
};
#[path = "scene_render.rs"]
mod scene_render;
use image::{GenericImageView, ImageBuffer, Rgba, RgbaImage};
use serde_json::Value;
use std::sync::OnceLock;
use std::{
    collections::{HashMap, VecDeque},
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Condvar, Mutex,
    },
    time::Instant,
};

const TILE: u32 = 512;
const MAX_PIXELS: u64 = 4_000_000_000;
const DEGHOST_OWNERSHIP_TEMPERATURE_SOURCE_PIXELS: f64 = 4.0;
const SOURCE_QUALITY_COLUMNS: usize = 64;
const SOURCE_QUALITY_ROWS: usize = 36;
const SOURCE_QUALITY_SAMPLES_PER_AXIS: usize = 5;
const SOURCE_QUALITY_BYTES_PER_CELL: u64 = 2;
const SOURCE_QUALITY_DARK_LUMA_MAX: f64 = 80.0;
const SOURCE_QUALITY_LOW_TEXTURE_MAX: f64 = 5.5;
const SOURCE_QUALITY_MIN_COMPONENT_CELLS: usize = 24;
const SOURCE_QUALITY_MIN_COMPONENT_THICKNESS: usize = 4;
const SOURCE_QUALITY_MIN_EDGE_CONTRAST: f64 = 24.0;
const SOURCE_QUALITY_SUSPECT_CONFIDENCE: f64 = 0.65;
const SOURCE_QUALITY_STRUCTURED_PEER_TEXTURE: f64 = 8.0;
const SOURCE_QUALITY_OVERRIDE_MARGIN_SOURCE_PX: f64 = 32.0;
const SOURCE_QUALITY_BLUR_PEER_TEXTURE: f64 = 12.0;
const SOURCE_QUALITY_BLUR_RELATIVE_MAX: f64 = 0.70;
const SOURCE_QUALITY_BLUR_PEER_SHARPNESS: f64 = 18.0;
const SOURCE_QUALITY_SHARPNESS_PATCH_RADIUS: i32 = 4;
const GEOMETRY_CACHE_MAX_BYTES_PER_WORKER: u64 = 32 * 1024 * 1024;
const SEAM_OWNERSHIP_MAX_CELLS: usize = 32_768;
const SEAM_OWNERSHIP_MAX_CANDIDATES: usize = 4;
const SEAM_OWNERSHIP_REGULARIZATION_COST: f32 = 0.045;
const SEAM_OWNERSHIP_ITERATIONS: usize = 4;

fn seam_ownership_bytes_per_cell() -> u64 {
    let candidate_scratch = std::mem::size_of::<Vec<OwnershipCandidate>>()
        + SEAM_OWNERSHIP_MAX_CANDIDATES * std::mem::size_of::<OwnershipCandidate>();
    let solver_and_result = 2 * std::mem::size_of::<Option<usize>>() + std::mem::size_of::<f32>();
    let unaligned = candidate_scratch + solver_and_result;
    ((unaligned + 15) & !15) as u64
}

fn geometry_cache_slot_bytes() -> crate::Result<u64> {
    let arrays_per_pixel = 3 * std::mem::size_of::<f64>() as u64;
    u64::from(TILE)
        .checked_mul(u64::from(TILE))
        .and_then(|pixels| pixels.checked_mul(arrays_per_pixel))
        .and_then(|bytes| {
            bytes.checked_add(std::mem::size_of::<(usize, TileGeometryCache)>() as u64)
        })
        .ok_or_else(|| crate::Error::Invalid("geometry cache slot accounting overflowed".into()))
}

fn cache_source_quality_map(
    source: &Source,
    computed: Arc<SourceQualityMap>,
) -> Arc<SourceQualityMap> {
    let mut cached_quality = source.quality_map.lock().expect("source quality map lock");
    cached_quality.get_or_insert(computed).clone()
}
static RENDERER_IDENTITY_TEMP_ID: AtomicU64 = AtomicU64::new(0);
static SRGB_F32_THRESHOLDS: OnceLock<[u32; 256]> = OnceLock::new();
static SRGB_F32_BUCKET_BASE: OnceLock<Vec<u8>> = OnceLock::new();

fn bounded_geometry_cache_slots(
    available_bytes: u64,
    workers: usize,
    slot_bytes: u64,
    per_worker_limit: u64,
    vector_header_bytes: u64,
) -> Option<(usize, u64)> {
    if workers == 0 || slot_bytes == 0 {
        return Some((0, 0));
    }
    let workers_u64 = u64::try_from(workers).ok()?;
    let available_per_worker = available_bytes / workers_u64;
    let slots_by_budget = available_per_worker.saturating_sub(vector_header_bytes) / slot_bytes;
    let slots_by_limit = per_worker_limit.saturating_sub(vector_header_bytes) / slot_bytes;
    let slots = slots_by_budget.min(slots_by_limit) as usize;
    let reserved_per_worker = if slots == 0 {
        0
    } else {
        slot_bytes
            .checked_mul(u64::try_from(slots).ok()?)?
            .checked_add(vector_header_bytes)?
    };
    let reserved_total = reserved_per_worker.checked_mul(workers_u64)?;
    (reserved_total <= available_bytes).then_some((slots, reserved_per_worker))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BlendMode {
    Feather,
    Deghost,
}

impl BlendMode {
    fn parse(value: Option<&str>) -> crate::Result<Self> {
        match value.unwrap_or("feather") {
            "feather" => Ok(Self::Feather),
            "deghost" => Ok(Self::Deghost),
            other => Err(crate::Error::Invalid(format!(
                "unsupported renderBlendMode {other:?}"
            ))),
        }
    }

    fn model_name(self) -> &'static str {
        match self {
            Self::Feather => "source-edge-smoothstep-feather",
            Self::Deghost => "sharpness-aware-peer-coupled-coarse-ownership-v2",
        }
    }
}

#[derive(Clone, Debug)]
struct Source {
    path: PathBuf,
    width: u32,
    height: u32,
    fx: f64,
    fy: f64,
    cx: f64,
    cy: f64,
    camera_to_world: [f64; 9],
    source_plane_warp: Option<SourcePlaneWarp>,
    quality_map: Arc<Mutex<Option<Arc<SourceQualityMap>>>>,
    center: [f64; 3],
    cone_radius: f64,
}

#[derive(Clone, Debug)]
struct SourceQualityMap {
    texture_energy: Vec<u8>,
    normalized_sharpness: Vec<u8>,
    obstruction_confidence: Vec<u8>,
}

impl SourceQualityMap {
    fn byte_len() -> u64 {
        (SOURCE_QUALITY_COLUMNS * SOURCE_QUALITY_ROWS) as u64 * (SOURCE_QUALITY_BYTES_PER_CELL + 1)
    }

    fn from_image(image: &RgbaImage) -> Self {
        let width = image.width();
        let height = image.height();
        let mut luma = vec![0.0f64; SOURCE_QUALITY_COLUMNS * SOURCE_QUALITY_ROWS];
        let mut texture_energy = vec![0u8; SOURCE_QUALITY_COLUMNS * SOURCE_QUALITY_ROWS];
        let mut normalized_sharpness = vec![0u8; SOURCE_QUALITY_COLUMNS * SOURCE_QUALITY_ROWS];
        for row in 0..SOURCE_QUALITY_ROWS {
            let y0 = (row as f64 * f64::from(height.saturating_sub(1))
                / (SOURCE_QUALITY_ROWS - 1) as f64)
                .floor() as u32;
            let y1 = ((row + 1) as f64 * f64::from(height.saturating_sub(1))
                / (SOURCE_QUALITY_ROWS - 1) as f64)
                .ceil() as u32;
            for column in 0..SOURCE_QUALITY_COLUMNS {
                let x0 = (column as f64 * f64::from(width.saturating_sub(1))
                    / (SOURCE_QUALITY_COLUMNS - 1) as f64)
                    .floor() as u32;
                let x1 = ((column + 1) as f64 * f64::from(width.saturating_sub(1))
                    / (SOURCE_QUALITY_COLUMNS - 1) as f64)
                    .ceil() as u32;
                let mut samples =
                    [0.0f64; SOURCE_QUALITY_SAMPLES_PER_AXIS * SOURCE_QUALITY_SAMPLES_PER_AXIS];
                let mut count = 0usize;
                for sy in 0..SOURCE_QUALITY_SAMPLES_PER_AXIS {
                    let y = y0
                        + (((2 * sy + 1) as f64 / (2 * SOURCE_QUALITY_SAMPLES_PER_AXIS) as f64)
                            * f64::from(y1.saturating_sub(y0)))
                        .round() as u32;
                    for sx in 0..SOURCE_QUALITY_SAMPLES_PER_AXIS {
                        let x = x0
                            + (((2 * sx + 1) as f64 / (2 * SOURCE_QUALITY_SAMPLES_PER_AXIS) as f64)
                                * f64::from(x1.saturating_sub(x0)))
                            .round() as u32;
                        let rgba = image.get_pixel(x.min(width - 1), y.min(height - 1)).0;
                        samples[count] = (0.299 * f64::from(rgba[0])
                            + 0.587 * f64::from(rgba[1])
                            + 0.114 * f64::from(rgba[2]))
                        .clamp(0.0, 255.0);
                        count += 1;
                    }
                }
                let mean = samples.iter().sum::<f64>() / samples.len() as f64;
                let variance = samples
                    .iter()
                    .map(|value| (value - mean).powi(2))
                    .sum::<f64>()
                    / samples.len() as f64;
                let index = row * SOURCE_QUALITY_COLUMNS + column;
                luma[index] = mean;
                let contrast = variance.sqrt();
                texture_energy[index] = contrast.round().clamp(0.0, 255.0) as u8;
                // Use a contiguous full-resolution patch for sharpness. The
                // broad 5x5 samples above span a quality cell and provide a
                // larger-scale contrast reference, so 1-3px blur remains
                // visible even on multi-megapixel photos.
                const PATCH_SIDE: usize = (SOURCE_QUALITY_SHARPNESS_PATCH_RADIUS * 2 + 1) as usize;
                let center_x = (i64::from(x0) + i64::from(x1)) / 2;
                let center_y = (i64::from(y0) + i64::from(y1)) / 2;
                let mut patch = [0.0f64; PATCH_SIDE * PATCH_SIDE];
                for py in 0..PATCH_SIDE {
                    for px in 0..PATCH_SIDE {
                        let x = (center_x + px as i64
                            - i64::from(SOURCE_QUALITY_SHARPNESS_PATCH_RADIUS))
                        .clamp(0, i64::from(width) - 1) as u32;
                        let y = (center_y + py as i64
                            - i64::from(SOURCE_QUALITY_SHARPNESS_PATCH_RADIUS))
                        .clamp(0, i64::from(height) - 1) as u32;
                        let rgba = image.get_pixel(x, y).0;
                        patch[py * PATCH_SIDE + px] = 0.299 * f64::from(rgba[0])
                            + 0.587 * f64::from(rgba[1])
                            + 0.114 * f64::from(rgba[2]);
                    }
                }
                let mut gradient_sum = 0.0;
                for py in 0..PATCH_SIDE {
                    for px in 0..PATCH_SIDE {
                        let value = patch[py * PATCH_SIDE + px];
                        if px + 1 < PATCH_SIDE {
                            gradient_sum += (value - patch[py * PATCH_SIDE + px + 1]).abs();
                        }
                        if py + 1 < PATCH_SIDE {
                            gradient_sum += (value - patch[(py + 1) * PATCH_SIDE + px]).abs();
                        }
                    }
                }
                let gradient_count = (PATCH_SIDE * (PATCH_SIDE - 1) * 2) as f64;
                let mut laplacian_sum = 0.0;
                let mut laplacian_count = 0usize;
                for sy in 1..PATCH_SIDE - 1 {
                    for sx in 1..PATCH_SIDE - 1 {
                        let center = patch[sy * PATCH_SIDE + sx];
                        let laplacian = 4.0 * center
                            - patch[sy * PATCH_SIDE + sx - 1]
                            - patch[sy * PATCH_SIDE + sx + 1]
                            - patch[(sy - 1) * PATCH_SIDE + sx]
                            - patch[(sy + 1) * PATCH_SIDE + sx];
                        laplacian_sum += laplacian.abs();
                        laplacian_count += 1;
                    }
                }
                // Combine normalized first differences and a Laplacian term;
                // the broader-cell contrast denominator limits exposure bias
                // without normalizing away blur at the patch scale.
                let normalized_gradient = gradient_sum / gradient_count / (contrast + 1.0);
                let normalized_laplacian =
                    laplacian_sum / laplacian_count.max(1) as f64 / (contrast + 1.0);
                let detail_ratio = normalized_gradient + normalized_laplacian * 0.25;
                // Log compression preserves useful separation for sharp
                // sources without clipping their score at 255.
                normalized_sharpness[index] =
                    (detail_ratio.ln_1p() * 64.0).round().clamp(0.0, 255.0) as u8;
            }
        }

        let mut low_texture_dark = vec![false; luma.len()];
        for index in 0..luma.len() {
            low_texture_dark[index] = luma[index] <= SOURCE_QUALITY_DARK_LUMA_MAX
                && f64::from(texture_energy[index]) <= SOURCE_QUALITY_LOW_TEXTURE_MAX;
        }
        let mut visited = vec![false; luma.len()];
        let mut obstruction_confidence = vec![0u8; luma.len()];
        for start in 0..luma.len() {
            if visited[start] || !low_texture_dark[start] {
                continue;
            }
            let mut component = Vec::new();
            let mut queue = VecDeque::from([start]);
            visited[start] = true;
            while let Some(index) = queue.pop_front() {
                component.push(index);
                let row = index / SOURCE_QUALITY_COLUMNS;
                let column = index % SOURCE_QUALITY_COLUMNS;
                for next_row in row.saturating_sub(1)..=(row + 1).min(SOURCE_QUALITY_ROWS - 1) {
                    for next_column in
                        column.saturating_sub(1)..=(column + 1).min(SOURCE_QUALITY_COLUMNS - 1)
                    {
                        let next = next_row * SOURCE_QUALITY_COLUMNS + next_column;
                        if !visited[next] && low_texture_dark[next] {
                            visited[next] = true;
                            queue.push_back(next);
                        }
                    }
                }
            }
            let min_row = component
                .iter()
                .map(|index| index / SOURCE_QUALITY_COLUMNS)
                .min()
                .unwrap_or(0);
            let max_row = component
                .iter()
                .map(|index| index / SOURCE_QUALITY_COLUMNS)
                .max()
                .unwrap_or(0);
            let min_column = component
                .iter()
                .map(|index| index % SOURCE_QUALITY_COLUMNS)
                .min()
                .unwrap_or(0);
            let max_column = component
                .iter()
                .map(|index| index % SOURCE_QUALITY_COLUMNS)
                .max()
                .unwrap_or(0);
            let touches_border = min_row == 0
                || min_column == 0
                || max_row + 1 == SOURCE_QUALITY_ROWS
                || max_column + 1 == SOURCE_QUALITY_COLUMNS;
            let component_width = max_column - min_column + 1;
            let component_height = max_row - min_row + 1;
            if !touches_border
                || component.len() < SOURCE_QUALITY_MIN_COMPONENT_CELLS
                || component_width.min(component_height) < SOURCE_QUALITY_MIN_COMPONENT_THICKNESS
            {
                continue;
            }

            let component_mean =
                component.iter().map(|index| luma[*index]).sum::<f64>() / component.len() as f64;
            let component_texture = component
                .iter()
                .map(|index| f64::from(texture_energy[*index]))
                .sum::<f64>()
                / component.len() as f64;
            let mut boundary_luma = Vec::new();
            for index in &component {
                let row = index / SOURCE_QUALITY_COLUMNS;
                let column = index % SOURCE_QUALITY_COLUMNS;
                for next_row in row.saturating_sub(1)..=(row + 1).min(SOURCE_QUALITY_ROWS - 1) {
                    for next_column in
                        column.saturating_sub(1)..=(column + 1).min(SOURCE_QUALITY_COLUMNS - 1)
                    {
                        let next = next_row * SOURCE_QUALITY_COLUMNS + next_column;
                        if !low_texture_dark[next] {
                            boundary_luma.push(luma[next]);
                        }
                    }
                }
            }
            if boundary_luma.is_empty() {
                continue;
            }
            boundary_luma.sort_by(f64::total_cmp);
            let boundary_median = boundary_luma[boundary_luma.len() / 2];
            let contrast = boundary_median - component_mean;
            if contrast < SOURCE_QUALITY_MIN_EDGE_CONTRAST {
                continue;
            }
            let texture_confidence =
                ((SOURCE_QUALITY_LOW_TEXTURE_MAX + 1.0 - component_texture) / 3.0).clamp(0.0, 1.0);
            let contrast_confidence =
                ((contrast - SOURCE_QUALITY_MIN_EDGE_CONTRAST) / 24.0).clamp(0.0, 1.0);
            let area_confidence = (component.len() as f64
                / (SOURCE_QUALITY_MIN_COMPONENT_CELLS * 2) as f64)
                .clamp(0.5, 1.0);
            let confidence = (texture_confidence * contrast_confidence * area_confidence * 255.0)
                .round()
                .clamp(0.0, 255.0) as u8;
            for index in component {
                obstruction_confidence[index] = confidence;
            }
        }
        Self {
            texture_energy,
            normalized_sharpness,
            obstruction_confidence,
        }
    }

    fn sample(&self, width: u32, height: u32, x: f64, y: f64) -> (f64, f64) {
        if width < 2 || height < 2 {
            return (0.0, 0.0);
        }
        let texture = sample_quality_field(&self.texture_energy, width, height, x, y);
        let confidence =
            sample_quality_field(&self.obstruction_confidence, width, height, x, y) / 255.0;
        (texture, confidence)
    }

    fn sharpness(&self, width: u32, height: u32, x: f64, y: f64) -> f64 {
        if width < 2 || height < 2 {
            return 0.0;
        }
        sample_quality_field(&self.normalized_sharpness, width, height, x, y)
    }
}

fn sample_quality_field(values: &[u8], width: u32, height: u32, x: f64, y: f64) -> f64 {
    let gx = (x / f64::from(width.saturating_sub(1)) * (SOURCE_QUALITY_COLUMNS - 1) as f64)
        .clamp(0.0, (SOURCE_QUALITY_COLUMNS - 1) as f64);
    let gy = (y / f64::from(height.saturating_sub(1)) * (SOURCE_QUALITY_ROWS - 1) as f64)
        .clamp(0.0, (SOURCE_QUALITY_ROWS - 1) as f64);
    let x0 = (gx.floor() as usize).min(SOURCE_QUALITY_COLUMNS - 2);
    let y0 = (gy.floor() as usize).min(SOURCE_QUALITY_ROWS - 2);
    let fx = gx - x0 as f64;
    let fy = gy - y0 as f64;
    let a = f64::from(values[y0 * SOURCE_QUALITY_COLUMNS + x0]);
    let b = f64::from(values[y0 * SOURCE_QUALITY_COLUMNS + x0 + 1]);
    let c = f64::from(values[(y0 + 1) * SOURCE_QUALITY_COLUMNS + x0]);
    let d = f64::from(values[(y0 + 1) * SOURCE_QUALITY_COLUMNS + x0 + 1]);
    (1.0 - fy) * ((1.0 - fx) * a + fx * b) + fy * ((1.0 - fx) * c + fx * d)
}

fn normalize(v: [f64; 3]) -> [f64; 3] {
    let n = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    [v[0] / n, v[1] / n, v[2] / n]
}
fn source_cone(s: &Source) -> ([f64; 3], f64) {
    let center = normalize([
        s.camera_to_world[2],
        s.camera_to_world[5],
        s.camera_to_world[8],
    ]);
    let mut radius: f64 = 0.;
    for x in [0., f64::from(s.width)] {
        for y in [0., f64::from(s.height)] {
            let ray = normalize([
                s.camera_to_world[0] * (x - s.cx) / s.fx - s.camera_to_world[1] * (y - s.cy) / s.fy
                    + s.camera_to_world[2],
                s.camera_to_world[3] * (x - s.cx) / s.fx - s.camera_to_world[4] * (y - s.cy) / s.fy
                    + s.camera_to_world[5],
                s.camera_to_world[6] * (x - s.cx) / s.fx - s.camera_to_world[7] * (y - s.cy) / s.fy
                    + s.camera_to_world[8],
            ]);
            let dot = (center[0] * ray[0] + center[1] * ray[1] + center[2] * ray[2]).clamp(-1., 1.);
            radius = radius.max(dot.acos());
        }
    }
    // A corrected image coordinate can extend outside the nominal source
    // rectangle by the bounded source-plane warp. Keep candidate selection
    // conservative so warped edge pixels are not omitted from render tiles.
    let warp_padding = if s.source_plane_warp.is_some() {
        SOURCE_WARP_MAX_DISPLACEMENT_PX / s.fx.min(s.fy)
    } else {
        0.0
    };
    (center, radius + warp_padding)
}
fn candidate(s: &Source, b: [f64; 4], x: u32, y: u32, w: u32, h: u32, fw: u32, fh: u32) -> bool {
    let yaw = b[0] + (f64::from(x) + f64::from(w) * 0.5) / f64::from(fw) * (b[1] - b[0]);
    let pitch = b[3] - (f64::from(y) + f64::from(h) * 0.5) / f64::from(fh) * (b[3] - b[2]);
    let p = [
        yaw.sin() * pitch.cos(),
        pitch.sin(),
        yaw.cos() * pitch.cos(),
    ];
    let d = (p[0] * s.center[0] + p[1] * s.center[1] + p[2] * s.center[2])
        .clamp(-1., 1.)
        .acos();
    let r = (b[1] - b[0]).abs() * f64::from(w) / f64::from(fw) * 0.5
        + (b[3] - b[2]).abs() * f64::from(h) / f64::from(fh) * 0.5;
    d <= s.cone_radius + r + 1e-5
}

fn dimensions(layout: &Value) -> crate::Result<(u32, u32, [f64; 4], Vec<Source>, BlendMode)> {
    if layout["schemaVersion"].as_u64() != Some(1)
        || layout["projection"].as_str() != Some("spherical")
    {
        return Err(crate::Error::Invalid(
            "unsupported spherical layout schema".into(),
        ));
    }
    let width = u32::try_from(layout["width"].as_u64().unwrap_or(0)).unwrap_or(0);
    let height = u32::try_from(layout["height"].as_u64().unwrap_or(0)).unwrap_or(0);
    if width == 0
        || height == 0
        || width > 131_072
        || height > 131_072
        || u64::from(width) * u64::from(height) > MAX_PIXELS
    {
        return Err(crate::Error::Invalid(format!(
            "unsupported spherical output dimensions {width}x{height}"
        )));
    }
    let bounds = ["yawMinRad", "yawMaxRad", "pitchMinRad", "pitchMaxRad"]
        .map(|key| layout[key].as_f64().unwrap_or(f64::NAN));
    if !bounds.iter().all(|v| v.is_finite())
        || bounds[1] <= bounds[0]
        || bounds[3] <= bounds[2]
        || bounds[3] > std::f64::consts::FRAC_PI_2
        || bounds[2] < -std::f64::consts::FRAC_PI_2
    {
        return Err(crate::Error::Invalid(
            "invalid spherical angular bounds".into(),
        ));
    }
    let tiles = layout["tiles"]
        .as_array()
        .ok_or_else(|| crate::Error::Invalid("layout has no tiles".into()))?;
    if tiles.is_empty() {
        return Err(crate::Error::Invalid(
            "layout must contain at least one tile".into(),
        ));
    }
    let mut sources = Vec::with_capacity(tiles.len());
    for tile in tiles {
        let get_num = |key: &str| tile[key].as_f64().unwrap_or(f64::NAN);
        let path = tile["path"]
            .as_str()
            .filter(|p| !p.is_empty())
            .ok_or_else(|| crate::Error::Invalid("layout tile path is empty".into()))?;
        let matrix: Vec<f64> = serde_json::from_value(tile["cameraToWorld"].clone())
            .map_err(|e| crate::Error::Invalid(format!("invalid cameraToWorld matrix: {e}")))?;
        if matrix.len() != 9 || !matrix.iter().all(|v| v.is_finite()) {
            return Err(crate::Error::Invalid(
                "cameraToWorld must contain nine finite values".into(),
            ));
        }
        let m: [f64; 9] = matrix.clone().try_into().unwrap();
        let det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6])
            + m[2] * (m[3] * m[7] - m[4] * m[6]);
        let orthogonal = (0..3).all(|a| {
            (0..3).all(|b| {
                let dot = (0..3).map(|k| m[a * 3 + k] * m[b * 3 + k]).sum::<f64>();
                (dot - if a == b { 1. } else { 0. }).abs() < 1e-3
            })
        });
        if !orthogonal || (det - 1.).abs() > 1e-3 {
            return Err(crate::Error::Invalid(
                "cameraToWorld must be a proper orthonormal rotation".into(),
            ));
        }
        let source_width = u32::try_from(tile["width"].as_u64().unwrap_or(0)).unwrap_or(0);
        let source_height = u32::try_from(tile["height"].as_u64().unwrap_or(0)).unwrap_or(0);
        let source_plane_warp = if let Some(warp_value) = tile.get("sourcePlaneWarp") {
            let warp: SourcePlaneWarp = serde_json::from_value(warp_value.clone())
                .map_err(|e| crate::Error::Invalid(format!("invalid sourcePlaneWarp: {e}")))?;
            let object = warp_value
                .as_object()
                .ok_or_else(|| crate::Error::Invalid("sourcePlaneWarp must be an object".into()))?;
            if object.len() != 3
                || !["columns", "rows", "offsets"]
                    .iter()
                    .all(|key| object.contains_key(*key))
            {
                return Err(crate::Error::Invalid(
                    "sourcePlaneWarp must contain exactly columns, rows and offsets".into(),
                ));
            }
            validate_source_plane_warp(&warp, source_width, source_height)
                .map_err(|e| crate::Error::Invalid(format!("invalid sourcePlaneWarp: {e}")))?;
            (!warp.is_zero()).then_some(warp)
        } else {
            None
        };
        let source = Source {
            path: PathBuf::from(path),
            width: source_width,
            height: source_height,
            fx: get_num("fx"),
            fy: get_num("fy"),
            cx: get_num("cx"),
            cy: get_num("cy"),
            camera_to_world: m,
            source_plane_warp,
            quality_map: Arc::new(Mutex::new(None)),
            center: [0.; 3],
            cone_radius: 0.,
        };
        if source.width == 0
            || source.height == 0
            || ![source.fx, source.fy, source.cx, source.cy]
                .iter()
                .all(|v| v.is_finite())
            || source.fx <= 0.
            || source.fy <= 0.
        {
            return Err(crate::Error::Invalid(
                "invalid spherical source geometry".into(),
            ));
        }
        let (center, cone_radius) = source_cone(&source);
        let mut source = source;
        source.center = center;
        source.cone_radius = cone_radius;
        sources.push(source);
    }
    let blend_mode = BlendMode::parse(layout["renderBlendMode"].as_str())?;
    if blend_mode == BlendMode::Deghost {
        sources.sort_by(|a, b| {
            a.path.cmp(&b.path).then_with(|| {
                a.camera_to_world
                    .iter()
                    .zip(b.camera_to_world.iter())
                    .map(|(left, right)| left.total_cmp(right))
                    .find(|ordering| *ordering != std::cmp::Ordering::Equal)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
        });
    }
    Ok((width, height, bounds, sources, blend_mode))
}

fn linear(c: f64) -> f64 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}
fn validate_cached_tile(path: &Path, expected: (u32, u32)) -> crate::Result<()> {
    let decoded = image::open(path).map_err(|e| {
        crate::Error::Invalid(format!(
            "existing cached tile {} cannot be decoded: {e}",
            path.display()
        ))
    })?;
    if decoded.dimensions() != expected {
        return Err(crate::Error::Invalid(format!(
            "existing cached tile {} has dimensions {:?}, expected {:?}",
            path.display(),
            decoded.dimensions(),
            expected
        )));
    }
    Ok(())
}

fn renderer_identity(blend_mode: BlendMode) -> Value {
    serde_json::json!({
        "schemaVersion": 1,
        "blendModel": blend_mode.model_name(),
        "algorithmVersion": if blend_mode == BlendMode::Deghost { 3 } else { 1 }
    })
}

fn renderer_identity_with_scene(
    blend_mode: BlendMode,
    scene_identity: &scene_render::SceneIdentity,
) -> Value {
    let mut identity = renderer_identity(blend_mode);
    if scene_identity.enabled {
        identity["sceneRendering"] = scene_identity.json();
    }
    identity
}

fn has_existing_render_tiles(output: &Path) -> crate::Result<bool> {
    if !output.is_dir() {
        return Ok(false);
    }
    for entry in fs::read_dir(output)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir()
            || !entry.file_name().to_string_lossy().starts_with("level-")
        {
            continue;
        }
        if fs::read_dir(entry.path())?.next().transpose()?.is_some() {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
fn validate_or_write_renderer_identity(output: &Path, blend_mode: BlendMode) -> crate::Result<()> {
    validate_or_write_renderer_identity_expected(output, renderer_identity(blend_mode))
}

fn validate_or_write_renderer_identity_expected(
    output: &Path,
    expected: Value,
) -> crate::Result<()> {
    let marker_path = output.join("renderer-identity.json");
    if marker_path.is_file() {
        let stored: Value = serde_json::from_slice(&fs::read(&marker_path).map_err(|error| {
            crate::Error::Invalid(format!(
                "cannot read renderer identity {}: {error}",
                marker_path.display()
            ))
        })?)
        .map_err(|error| {
            crate::Error::Invalid(format!(
                "renderer identity {} is invalid: {error}",
                marker_path.display()
            ))
        })?;
        if stored != expected {
            return Err(crate::Error::Invalid(
                "renderer algorithm changed; create a task copy and restitch to avoid mixing tiles"
                    .into(),
            ));
        }
        return Ok(());
    }

    // Legacy feather rendering is byte-compatible, so it can adopt an
    // identity marker in place. Deghost output predating this marker cannot be
    // safely resumed because some cached tiles may use the old ownership model.
    if expected["blendModel"] == "sharpness-aware-peer-coupled-coarse-ownership-v2"
        && has_existing_render_tiles(output)?
    {
        return Err(crate::Error::Invalid(
            "renderer algorithm changed; create a task copy and restitch to avoid mixing tiles"
                .into(),
        ));
    }

    fs::create_dir_all(output)?;
    let temporary = output.join(format!(
        ".renderer-identity-{}-{}.tmp",
        std::process::id(),
        RENDERER_IDENTITY_TEMP_ID.fetch_add(1, Ordering::Relaxed)
    ));
    fs::write(&temporary, serde_json::to_vec(&expected).unwrap())?;
    fs::rename(&temporary, marker_path)?;
    Ok(())
}
fn srgb(c: f64) -> u8 {
    let v = if c <= 0.0031308 {
        c * 12.92
    } else {
        1.055 * c.powf(1. / 2.4) - 0.055
    };
    (v.clamp(0., 1.) * 255. + 0.5) as u8
}

fn srgb_f32_thresholds() -> &'static [u32; 256] {
    SRGB_F32_THRESHOLDS.get_or_init(|| {
        let mut thresholds = [0u32; 256];
        let one = 1.0f32.to_bits();
        for byte in 1..=255u16 {
            let mut low = 0u32;
            let mut high = one;
            while low < high {
                let middle = low + (high - low) / 2;
                if srgb(f64::from(f32::from_bits(middle))) >= byte as u8 {
                    high = middle;
                } else {
                    low = middle + 1;
                }
            }
            thresholds[byte as usize] = low;
        }
        thresholds
    })
}

fn srgb_f32_bucket_base() -> &'static [u8] {
    SRGB_F32_BUCKET_BASE.get_or_init(|| {
        let max_bucket = 1.0f32.to_bits() >> 16;
        (0..=max_bucket)
            .map(|bucket| srgb(f64::from(f32::from_bits(bucket << 16))))
            .collect()
    })
}

/// Exact byte conversion for the f32 blend ratios used by level-zero output.
/// A coarse exponent/mantissa bucket supplies the starting byte; f32-bit
/// thresholds correct any sRGB rounding boundary crossed within that bucket.
fn srgb_from_blend_f32(value: f32) -> u8 {
    if value.is_nan() || value <= 0.0 {
        return srgb(f64::from(value));
    }
    if value >= 1.0 {
        return srgb(f64::from(value));
    }
    let bits = value.to_bits();
    let mut byte = srgb_f32_bucket_base()[(bits >> 16) as usize];
    let thresholds = srgb_f32_thresholds();
    while byte < 255 && bits >= thresholds[usize::from(byte) + 1] {
        byte += 1;
    }
    byte
}

fn sample_geometry(source: &Source, world: [f64; 3]) -> Option<(f64, f64, f64, f64)> {
    // Row-major cameraToWorld; its transpose maps world rays to camera rays.
    let m = source.camera_to_world;
    let camera = [
        m[0] * world[0] + m[3] * world[1] + m[6] * world[2],
        m[1] * world[0] + m[4] * world[1] + m[7] * world[2],
        m[2] * world[0] + m[5] * world[1] + m[8] * world[2],
    ];
    if camera[2] <= 1e-5 {
        return None;
    }
    let x = source.cx + source.fx * camera[0] / camera[2];
    let y = source.cy - source.fy * camera[1] / camera[2];
    let active_warp = source
        .source_plane_warp
        .as_ref()
        .filter(|warp| !warp.is_zero());
    let (x, y) = if let Some(warp) = active_warp {
        let (sx, sy) = corrected_to_source(warp, source.width, source.height, x, y)?;
        (sx, sy)
    } else {
        (x, y)
    };
    let inside_source = if active_warp.is_some() {
        x <= f64::from(source.width - 1) && y <= f64::from(source.height - 1)
    } else {
        // Preserve the legacy half-open source bounds. The sampler clamps the
        // final subpixel to the last texel exactly as it did before warping.
        x < f64::from(source.width) && y < f64::from(source.height)
    };
    if !x.is_finite() || !y.is_finite() || x < 0. || y < 0. || !inside_source {
        return None;
    }
    let edge = x
        .min(y)
        .min(f64::from(source.width) - x)
        .min(f64::from(source.height) - y);
    let t = (edge / (f64::from(source.width.min(source.height)) * 0.08)).clamp(0., 1.);
    let weight = t * t * (3. - 2. * t);
    let ownership = (edge / f64::from(source.width.min(source.height))).clamp(0., 0.5);
    Some((x, y, weight, ownership))
}

fn build_global_ownership_map(
    width: u32,
    height: u32,
    bounds: [f64; 4],
    sources: &[Source],
    mut checkpoint: impl FnMut() -> bool,
) -> crate::Result<CoarseOwnershipMap> {
    let started = Instant::now();
    let stride = coarse_stride(width, height, SEAM_OWNERSHIP_MAX_CELLS);
    let columns = (width as usize).div_ceil(stride);
    let rows = (height as usize).div_ceil(stride);
    let cell_count = columns.saturating_mul(rows);
    let mut stable_sources: Vec<usize> = (0..sources.len()).collect();
    stable_sources.sort_by(|left, right| {
        sources[*left]
            .path
            .to_string_lossy()
            .cmp(&sources[*right].path.to_string_lossy())
    });
    let mut candidates: Vec<Vec<OwnershipCandidate>> =
        std::iter::repeat_with(|| Vec::with_capacity(SEAM_OWNERSHIP_MAX_CANDIDATES))
            .take(cell_count)
            .collect();
    for (rank, &source_index) in stable_sources.iter().enumerate() {
        if !checkpoint() {
            return Err(crate::Error::Cancelled);
        }
        let source = &sources[source_index];
        let source_image = image::open(&source.path)?.into_rgba8();
        let quality = cache_source_quality_map(
            source,
            Arc::new(SourceQualityMap::from_image(&source_image)),
        );
        for cy in 0..rows {
            if !checkpoint() {
                return Err(crate::Error::Cancelled);
            }
            let py = (cy * stride + stride / 2).min(height as usize - 1) as u32;
            let pitch =
                bounds[3] - (f64::from(py) + 0.5) / f64::from(height) * (bounds[3] - bounds[2]);
            let (sp, cp) = pitch.sin_cos();
            for cx in 0..columns {
                let px = (cx * stride + stride / 2).min(width as usize - 1) as u32;
                let yaw =
                    bounds[0] + (f64::from(px) + 0.5) / f64::from(width) * (bounds[1] - bounds[0]);
                let (sy, cyaw) = yaw.sin_cos();
                let world = [sy * cp, sp, cyaw * cp];
                let Some((source_x, source_y, _, ownership)) = sample_geometry(source, world)
                else {
                    continue;
                };
                let sampled = source_image.get_pixel(
                    source_x.round().clamp(0.0, f64::from(source.width - 1)) as u32,
                    source_y.round().clamp(0.0, f64::from(source.height - 1)) as u32,
                );
                let (texture, obstruction) =
                    quality.sample(source.width, source.height, source_x, source_y);
                let sharpness = quality.sharpness(source.width, source.height, source_x, source_y);
                let cell = &mut candidates[cy * columns + cx];
                let obstruction_penalty = if obstruction >= SOURCE_QUALITY_SUSPECT_CONFIDENCE
                    && texture <= SOURCE_QUALITY_LOW_TEXTURE_MAX
                {
                    0.10
                } else {
                    0.0
                };
                let candidate = OwnershipCandidate {
                    source: rank,
                    unary_cost: (0.5 - ownership) as f32 + obstruction_penalty,
                    color: [sampled[0], sampled[1], sampled[2]],
                    texture: texture.round().clamp(0.0, 255.0) as u8,
                    sharpness: sharpness.round().clamp(0.0, 255.0) as u8,
                    obstruction: (obstruction * 255.0).round().clamp(0.0, 255.0) as u8,
                };
                if cell.len() < SEAM_OWNERSHIP_MAX_CANDIDATES {
                    cell.push(candidate);
                    continue;
                }
                let worst = cell
                    .iter()
                    .enumerate()
                    .max_by(|(_, left), (_, right)| left.unary_cost.total_cmp(&right.unary_cost))
                    .map(|(index, _)| index)
                    .expect("candidate set has its bounded capacity");
                if candidate.unary_cost < cell[worst].unary_cost
                    || (candidate.unary_cost == cell[worst].unary_cost
                        && candidate.source < cell[worst].source)
                {
                    cell[worst] = candidate;
                }
            }
        }
    }
    for cell in &mut candidates {
        adjust_candidates_for_content(
            cell,
            SOURCE_QUALITY_BLUR_PEER_TEXTURE as u8,
            SOURCE_QUALITY_BLUR_PEER_SHARPNESS as u8,
            SOURCE_QUALITY_BLUR_RELATIVE_MAX as f32,
        );
        cell.sort_by(|left, right| {
            left.unary_cost
                .total_cmp(&right.unary_cost)
                .then_with(|| left.source.cmp(&right.source))
        });
        cell.truncate(2);
    }
    let stable_owners = regularize_owners(
        columns,
        rows,
        &candidates,
        SEAM_OWNERSHIP_REGULARIZATION_COST,
        SEAM_OWNERSHIP_ITERATIONS,
        &mut checkpoint,
    )
    .ok_or(crate::Error::Cancelled)?;
    let confidence = candidates
        .iter()
        .zip(stable_owners.iter())
        .map(|(cell, owner)| {
            let Some(owner) = owner else {
                return 0.0;
            };
            let Some(owner_cost) = cell
                .iter()
                .find(|candidate| candidate.source == *owner)
                .map(|candidate| candidate.unary_cost)
            else {
                return 0.0;
            };
            let Some(other_cost) = cell
                .iter()
                .filter(|candidate| candidate.source != *owner)
                .map(|candidate| candidate.unary_cost)
                .min_by(f32::total_cmp)
            else {
                return 0.0;
            };
            let geometry_confidence = ((other_cost - owner_cost) / 0.20).clamp(0.0, 1.0);
            let content_confidence = if cell.len() >= 2 && owner_cost <= other_cost + 0.05 {
                let delta = content_disagreement(cell[0].color, cell[1].color);
                ((delta - 0.08) / 0.22).clamp(0.0, 1.0)
            } else {
                0.0
            };
            geometry_confidence.max(content_confidence)
        })
        .collect();
    let owners = stable_owners
        .into_iter()
        .map(|rank| rank.map(|rank| stable_sources[rank]))
        .collect();
    Ok(CoarseOwnershipMap {
        width: columns,
        height: rows,
        stride,
        owners,
        confidence,
        prepass_micros: started.elapsed().as_micros() as u64,
        decoded_sources: sources.len() as u64,
        scratch_bytes_reserved: (cell_count as u64).saturating_mul(seam_ownership_bytes_per_cell()),
    })
}

#[cfg(test)]
fn sample(
    source: &Source,
    image: &RgbaImage,
    world: [f64; 3],
) -> Option<([f64; 3], f64, f64, f64, f64)> {
    let (x, y, weight, ownership) = sample_geometry(source, world)?;
    Some(sample_with_geometry(
        source,
        image,
        (x, y, weight, ownership),
    ))
}

fn sample_with_geometry(
    source: &Source,
    image: &RgbaImage,
    geometry: (f64, f64, f64, f64),
) -> ([f64; 3], f64, f64, f64, f64) {
    let (x, y, weight, ownership) = geometry;
    // Texture coordinates use pixel centers, matching OpenGL's linear sampler.
    // The shader submits uv=(src+0.5)/size; GL's texel coordinate is src.
    let fx = x.clamp(0., f64::from(source.width - 1));
    let fy = y.clamp(0., f64::from(source.height - 1));
    let x0 = fx.floor() as u32;
    let y0 = fy.floor() as u32;
    let x1 = (x0 + 1).min(source.width - 1);
    let y1 = (y0 + 1).min(source.height - 1);
    let dx = fx - f64::from(x0);
    let dy = fy - f64::from(y0);
    let mut rgb = [0.; 3];
    for (px, py, w) in [
        (x0, y0, (1. - dx) * (1. - dy)),
        (x1, y0, dx * (1. - dy)),
        (x0, y1, (1. - dx) * dy),
        (x1, y1, dx * dy),
    ] {
        let p = image.get_pixel(px, py).0;
        for c in 0..3 {
            rgb[c] += f64::from(p[c]) / 255. * w;
        }
    }
    (
        [linear(rgb[0]), linear(rgb[1]), linear(rgb[2])],
        weight,
        ownership,
        x,
        y,
    )
}

fn geometry_from_source_xy(source: &Source, x: f64, y: f64) -> (f64, f64, f64, f64) {
    let edge = x
        .min(y)
        .min(f64::from(source.width) - x)
        .min(f64::from(source.height) - y);
    let t = (edge / (f64::from(source.width.min(source.height)) * 0.08)).clamp(0., 1.);
    let weight = t * t * (3. - 2. * t);
    let ownership = (edge / f64::from(source.width.min(source.height))).clamp(0., 0.5);
    (x, y, weight, ownership)
}

#[derive(Debug)]
struct TileGeometryCache {
    xs: Vec<f64>,
    ys: Vec<f64>,
    adjusted_ownership: Vec<f64>,
}

struct CandidateSourceIndices<'a> {
    cached: Option<std::slice::Iter<'a, usize>>,
    next_scan: usize,
    source_count: usize,
}

impl<'a> CandidateSourceIndices<'a> {
    fn new(cached: Option<&'a [usize]>, source_count: usize) -> Self {
        Self {
            cached: cached.map(|indices| indices.iter()),
            next_scan: 0,
            source_count,
        }
    }
}

impl Iterator for CandidateSourceIndices<'_> {
    type Item = usize;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(cached) = self.cached.as_mut() {
            cached.next().copied()
        } else if self.next_scan < self.source_count {
            let index = self.next_scan;
            self.next_scan += 1;
            Some(index)
        } else {
            None
        }
    }
}

impl TileGeometryCache {
    fn new(count: usize) -> Self {
        Self {
            xs: vec![f64::NAN; count],
            ys: vec![f64::NAN; count],
            adjusted_ownership: vec![f64::NAN; count],
        }
    }

    fn store(&mut self, index: usize, x: f64, y: f64) {
        self.xs[index] = x;
        self.ys[index] = y;
    }

    fn get(&self, source: &Source, index: usize) -> Option<(f64, f64, f64, f64)> {
        let x = self.xs[index];
        let y = self.ys[index];
        if x.is_nan() {
            None
        } else {
            Some(geometry_from_source_xy(source, x, y))
        }
    }

    fn store_adjusted_ownership(&mut self, index: usize, score: f64) {
        self.adjusted_ownership[index] = score;
    }

    fn get_adjusted_ownership(&self, index: usize) -> Option<f64> {
        let score = self.adjusted_ownership[index];
        (!score.is_nan()).then_some(score)
    }
}

#[derive(Debug)]
struct OwnerValidity {
    bits: Vec<u64>,
}

impl OwnerValidity {
    fn new(pixel_count: usize) -> Self {
        Self {
            bits: vec![0; pixel_count.div_ceil(u64::BITS as usize)],
        }
    }

    fn set(&mut self, index: usize, valid: bool) {
        if valid {
            self.bits[index / u64::BITS as usize] |= 1 << (index % u64::BITS as usize);
        }
    }

    fn get(&self, index: usize) -> bool {
        self.bits[index / u64::BITS as usize] & (1 << (index % u64::BITS as usize)) != 0
    }
}

fn source_geometry_is_valid(
    source_index: usize,
    pixel_index: usize,
    world: [f64; 3],
    sources: &[Source],
    tile_geometry: &[(usize, TileGeometryCache)],
) -> (bool, bool) {
    if let Some((_, geometry)) = tile_geometry
        .iter()
        .find(|(index, _)| *index == source_index)
    {
        (
            geometry.get(&sources[source_index], pixel_index).is_some(),
            true,
        )
    } else {
        (
            sample_geometry(&sources[source_index], world).is_some(),
            false,
        )
    }
}

fn best_other_source_quality(
    source_index: usize,
    pixel_index: usize,
    world: [f64; 3],
    sources: &[Source],
    quality_maps: &[Option<Arc<SourceQualityMap>>],
    tile_geometry: &[(usize, TileGeometryCache)],
    best_sources: &[usize],
    second_sources: &[usize],
    best_scores: &[f64],
    second_scores: &[f64],
) -> (f64, f64, f64) {
    let peer_index = if best_sources[pixel_index] == source_index {
        second_sources[pixel_index]
    } else {
        best_sources[pixel_index]
    };
    if peer_index >= sources.len() {
        return (f64::NEG_INFINITY, 0.0, 0.0);
    }
    let peer = &sources[peer_index];
    let peer_ownership = if peer_index == second_sources[pixel_index] {
        second_scores[pixel_index]
    } else {
        best_scores[pixel_index]
    };
    let peer_geometry = tile_geometry
        .iter()
        .find(|(candidate_index, _)| *candidate_index == peer_index)
        .and_then(|(_, cached)| cached.get(peer, pixel_index))
        .or_else(|| sample_geometry(peer, world));
    let (texture, sharpness) = peer_geometry
        .and_then(|(x, y, edge_support, _)| {
            let quality = quality_maps[peer_index].as_ref()?;
            let (texture, _) = quality.sample(peer.width, peer.height, x, y);
            Some((
                texture * edge_support,
                quality.sharpness(peer.width, peer.height, x, y) * edge_support,
            ))
        })
        .unwrap_or((0.0, 0.0));
    (peer_ownership, texture, sharpness)
}

fn deghost_weight(ownership: f64, max_ownership: f64, source_min_dimension: u32) -> f64 {
    if !ownership.is_finite() || !max_ownership.is_finite() {
        return 1.0;
    }
    let temperature =
        DEGHOST_OWNERSHIP_TEMPERATURE_SOURCE_PIXELS / f64::from(source_min_dimension.max(1));
    let exponent = ((ownership - max_ownership) / temperature).clamp(-80.0, 0.0);
    exponent.exp()
}

fn insert_top_two_ownership(
    score: f64,
    source_index: usize,
    stable_ranks: &[usize],
    best_score: &mut f64,
    best_source: &mut usize,
    second_score: &mut f64,
    second_source: &mut usize,
) {
    // Break equal-score ties by a stable path/camera rank so input iteration
    // order cannot change which other source supplies quality evidence.
    let outranks_best = score > *best_score
        || (score == *best_score
            && (*best_source == usize::MAX
                || stable_ranks[source_index] < stable_ranks[*best_source]));
    if outranks_best {
        *second_score = *best_score;
        *second_source = *best_source;
        *best_score = score;
        *best_source = source_index;
    } else if score > *second_score
        || (score == *second_score
            && (*second_source == usize::MAX
                || stable_ranks[source_index] < stable_ranks[*second_source]))
    {
        *second_score = score;
        *second_source = source_index;
    }
}

fn smoothstep(edge0: f64, edge1: f64, value: f64) -> f64 {
    if !value.is_finite() {
        return 0.0;
    }
    let t = ((value - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn quality_suppression_strength(
    max_structured_peer_texture: f64,
    obstruction_confidence: f64,
    texture_energy: f64,
    normalized_sharpness: f64,
    max_peer_sharpness: f64,
) -> f64 {
    let blur_texture_support = smoothstep(
        SOURCE_QUALITY_BLUR_PEER_TEXTURE - 2.0,
        SOURCE_QUALITY_BLUR_PEER_TEXTURE + 2.0,
        max_structured_peer_texture,
    );
    let obstruction_peer_support = smoothstep(
        SOURCE_QUALITY_STRUCTURED_PEER_TEXTURE - 2.0,
        SOURCE_QUALITY_STRUCTURED_PEER_TEXTURE + 2.0,
        max_structured_peer_texture,
    );
    let blur_support = if max_peer_sharpness > 0.0 {
        blur_texture_support
            * smoothstep(15.0, 21.0, max_peer_sharpness)
            * (1.0 - smoothstep(0.55, 0.85, normalized_sharpness / max_peer_sharpness))
    } else {
        0.0
    };
    let obstruction_support = smoothstep(0.50, 0.80, obstruction_confidence)
        * (1.0
            - smoothstep(
                SOURCE_QUALITY_LOW_TEXTURE_MAX * 0.6,
                SOURCE_QUALITY_LOW_TEXTURE_MAX * 1.4,
                texture_energy,
            ))
        * obstruction_peer_support;
    blur_support.max(obstruction_support).clamp(0.0, 1.0)
}

fn adjusted_ownership(
    ownership: f64,
    best_peer_ownership: f64,
    max_structured_peer_texture: f64,
    obstruction_confidence: f64,
    texture_energy: f64,
    normalized_sharpness: f64,
    max_peer_sharpness: f64,
    source_min_dimension: u32,
) -> f64 {
    if !ownership.is_finite() {
        return ownership;
    }
    let strength = quality_suppression_strength(
        max_structured_peer_texture,
        obstruction_confidence,
        texture_energy,
        normalized_sharpness,
        max_peer_sharpness,
    );
    if !best_peer_ownership.is_finite() || strength <= 0.0 {
        return ownership;
    }
    let margin = SOURCE_QUALITY_OVERRIDE_MARGIN_SOURCE_PX / f64::from(source_min_dimension.max(1));
    ownership - strength * (ownership - best_peer_ownership + margin).max(0.0)
}

fn accumulate_weighted(cell: &mut [f32; 4], rgb: [f64; 3], weight: f64) {
    for c in 0..3 {
        cell[c] += (rgb[c] * weight) as f32;
    }
    cell[3] += weight as f32;
}

/// Render a saved layout into independent `row-column.png` level-zero tiles.
/// This public layout-only entry point supports deterministic tests and callers
/// that already possess an aligned layout.
pub fn render_layout_tiles(
    layout: &Value,
    output: &Path,
    memory_budget_mib: usize,
    cancel: impl Fn() -> bool,
) -> crate::Result<Value> {
    render_layout_tiles_with_progress(layout, output, memory_budget_mib, |_, _| !cancel())
}

pub fn render_layout_tiles_with_progress(
    layout: &Value,
    output: &Path,
    memory_budget_mib: usize,
    mut checkpoint: impl FnMut(u64, u64) -> bool,
) -> crate::Result<Value> {
    render_layout_tiles_with_options(layout, output, memory_budget_mib, 1, true, &mut checkpoint)
}

pub fn render_layout_tiles_with_options(
    layout: &Value,
    output: &Path,
    memory_budget_mib: usize,
    workers_requested: usize,
    use_source_cache: bool,
    checkpoint: impl FnMut(u64, u64) -> bool,
) -> crate::Result<Value> {
    render_layout_tiles_with_options_internal(
        layout,
        output,
        memory_budget_mib,
        workers_requested,
        use_source_cache,
        checkpoint,
        true,
    )
}

fn render_layout_tiles_with_options_internal(
    layout: &Value,
    output: &Path,
    memory_budget_mib: usize,
    workers_requested: usize,
    use_source_cache: bool,
    checkpoint: impl FnMut(u64, u64) -> bool,
    sharpness_aware: bool,
) -> crate::Result<Value> {
    render_layout_tiles_with_options_internal_and_ownership(
        layout,
        output,
        memory_budget_mib,
        workers_requested,
        use_source_cache,
        checkpoint,
        sharpness_aware,
        sharpness_aware,
    )
}

fn render_layout_tiles_with_options_internal_and_ownership(
    layout: &Value,
    output: &Path,
    memory_budget_mib: usize,
    workers_requested: usize,
    use_source_cache: bool,
    mut checkpoint: impl FnMut(u64, u64) -> bool,
    sharpness_aware: bool,
    ownership_aware: bool,
) -> crate::Result<Value> {
    if !(32..=crate::job_resources::MAX_JOB_MEMORY_MIB).contains(&memory_budget_mib) {
        return Err(crate::Error::Invalid(format!(
            "memoryBudgetMiB must be 32..={}",
            crate::job_resources::MAX_JOB_MEMORY_MIB
        )));
    }
    if !(1..=32).contains(&workers_requested) {
        return Err(crate::Error::Invalid("workers must be 1..=32".into()));
    }
    let (width, height, bounds, sources, blend_mode) = dimensions(layout)?;
    let protect_people = layout["protectPeople"].as_bool().unwrap_or(false);
    let smooth_water = layout["smoothWater"].as_bool().unwrap_or(false);
    let scene_identity = scene_render::identity(layout, &sources, protect_people, smooth_water)?;
    validate_or_write_renderer_identity_expected(
        output,
        renderer_identity_with_scene(blend_mode, &scene_identity),
    )?;
    let dir = output.join("level-0");
    fs::create_dir_all(&dir)?;
    let cols = width.div_ceil(TILE);
    let rows = height.div_ceil(TILE);
    let total = u64::from(cols) * u64::from(rows);
    let mut completed = 0u64;
    let started = Instant::now();
    let budget_bytes = crate::job_resources::checked_memory_budget_bytes(memory_budget_mib)
        .ok_or_else(|| crate::Error::Invalid("memoryBudgetMiB overflows byte accounting".into()))?;
    let scene_plan = scene_render::prepare(
        layout,
        &sources,
        scene_identity,
        output,
        bounds,
        width,
        height,
        budget_bytes,
        || checkpoint(completed, total),
    )?;
    let mut source_bytes = Vec::with_capacity(sources.len());
    let mut max_decode = 0u64;
    for s in &sources {
        let reader = image::ImageReader::open(&s.path)?.with_guessed_format()?;
        let (iw, ih) = reader.into_dimensions()?;
        if (iw, ih) != (s.width, s.height) {
            return Err(crate::Error::Invalid(format!(
                "source dimensions changed for {}: declared {}x{}, decoded header {iw}x{ih}",
                s.path.display(),
                s.width,
                s.height
            )));
        }
        let bytes = u64::from(iw)
            .checked_mul(u64::from(ih))
            .and_then(|pixels| pixels.checked_mul(4))
            .ok_or_else(|| {
                crate::Error::Invalid(format!(
                    "source byte size overflows memory accounting for {}",
                    s.path.display()
                ))
            })?;
        source_bytes.push(bytes);
        max_decode = max_decode.max(bytes.saturating_mul(2));
    }
    let tile_bytes_per_pixel = if blend_mode == BlendMode::Deghost {
        // accum[4] (16 bytes), adjusted and top-two raw ownership scores
        // (24 bytes), and the winning plus runner-up source indices (16 bytes).
        // The 64-byte reserve leaves 8 bytes/pixel for alignment, Vec headers,
        // and the packed ownership-validity bitset (1/8 byte/pixel).
        64
    } else {
        24
    };
    let tile_reserve = u64::from(TILE) * u64::from(TILE) * tile_bytes_per_pixel;
    let owner_validity_reserve = if blend_mode == BlendMode::Deghost && ownership_aware {
        let words = (u64::from(TILE) * u64::from(TILE)).div_ceil(u64::BITS as u64);
        words
            .checked_mul(std::mem::size_of::<u64>() as u64)
            .and_then(|bytes| bytes.checked_add(std::mem::size_of::<Vec<u64>>() as u64))
            .ok_or_else(|| {
                crate::Error::Invalid("owner validity bitset accounting overflowed".into())
            })?
    } else {
        0
    };
    let owner_validity_scratch_margin =
        tile_reserve.saturating_sub(u64::from(TILE) * u64::from(TILE) * 56);
    if owner_validity_reserve > owner_validity_scratch_margin {
        return Err(crate::Error::Invalid(
            "owner validity bitset exceeds renderer tile scratch reserve".into(),
        ));
    }
    let source_quality_enabled = blend_mode == BlendMode::Deghost || protect_people;
    let source_quality_map_reserve = if source_quality_enabled {
        let per_source = SourceQualityMap::byte_len()
            .checked_add(std::mem::size_of::<SourceQualityMap>() as u64)
            .and_then(|bytes| {
                bytes.checked_add(std::mem::size_of::<Arc<SourceQualityMap>>() as u64)
            })
            .ok_or_else(|| {
                crate::Error::Invalid("source quality map accounting overflowed".into())
            })?;
        per_source
            .checked_mul(sources.len() as u64)
            .ok_or_else(|| {
                crate::Error::Invalid("source quality map accounting overflowed".into())
            })?
    } else {
        0
    };
    let source_quality_refs_per_worker = if source_quality_enabled {
        sources.len() as u64 * std::mem::size_of::<Option<Arc<SourceQualityMap>>>() as u64
    } else {
        0
    };
    let worker_base = tile_reserve
        .checked_add(max_decode / 2)
        .and_then(|bytes| bytes.checked_add(source_quality_refs_per_worker))
        .and_then(|bytes| {
            bytes.checked_add(
                scene_plan
                    .as_ref()
                    .map_or(0, scene_render::ScenePlan::worker_bytes),
            )
        })
        .ok_or_else(|| {
            crate::Error::Invalid("renderer worker memory accounting overflowed".into())
        })?;
    let decode_slot_bytes = max_decode / 2;
    let one_worker = worker_base.checked_add(decode_slot_bytes).ok_or_else(|| {
        crate::Error::Invalid("renderer decode memory accounting overflowed".into())
    })?;
    let seam_ownership_reserve = if blend_mode == BlendMode::Deghost && ownership_aware {
        (coarse_cell_count(width, height, SEAM_OWNERSHIP_MAX_CELLS) as u64)
            .saturating_mul(seam_ownership_bytes_per_cell())
    } else {
        0
    };
    let fixed_reserve = source_quality_map_reserve
        .saturating_add(seam_ownership_reserve)
        .saturating_add(
            scene_plan
                .as_ref()
                .map_or(0, scene_render::ScenePlan::shared_bytes),
        );
    if one_worker
        .checked_add(fixed_reserve)
        .map_or(true, |bytes| bytes > budget_bytes)
    {
        return Err(crate::Error::Invalid(format!(
            "one tile worker and source decode exceed memoryBudgetMiB={memory_budget_mib}"
        )));
    }
    let requested_cache_min = if use_source_cache {
        source_bytes.iter().copied().min().unwrap_or(0)
    } else {
        0
    };
    let requested_total = one_worker
        .checked_add(fixed_reserve)
        .and_then(|bytes| bytes.checked_add(requested_cache_min));
    let cache_min_reserve = if requested_total.map_or(false, |bytes| bytes <= budget_bytes) {
        requested_cache_min
    } else {
        0
    };
    let affordable =
        ((budget_bytes - fixed_reserve - cache_min_reserve) / one_worker).max(1) as usize;
    let effective_workers = workers_requested.min(affordable).min(total as usize).max(1);
    let decode_slot_reserve = decode_slot_bytes
        .checked_mul(effective_workers as u64)
        .ok_or_else(|| {
            crate::Error::Invalid("renderer decode slot reservation overflowed".into())
        })?;
    let active_reserve = worker_base
        .checked_mul(effective_workers as u64)
        .and_then(|bytes| bytes.checked_add(decode_slot_reserve))
        .and_then(|bytes| bytes.checked_add(source_quality_map_reserve))
        .and_then(|bytes| bytes.checked_add(seam_ownership_reserve))
        .ok_or_else(|| {
            crate::Error::Invalid("renderer active memory reservation overflowed".into())
        })?;
    let geometry_slot_bytes = geometry_cache_slot_bytes()?;
    let geometry_headroom = budget_bytes
        .saturating_sub(active_reserve)
        .saturating_sub(cache_min_reserve);
    let source_count = u64::try_from(sources.len()).map_err(|_| {
        crate::Error::Invalid("renderer source count exceeds memory accounting".into())
    })?;
    let candidate_index_bytes_per_worker = source_count
        .checked_mul(std::mem::size_of::<usize>() as u64)
        .and_then(|bytes| bytes.checked_add(std::mem::size_of::<Vec<usize>>() as u64))
        .ok_or_else(|| {
            crate::Error::Invalid("candidate list memory accounting overflowed".into())
        })?;
    let candidate_index_bytes_reserved = if blend_mode == BlendMode::Deghost {
        candidate_index_bytes_per_worker
            .checked_mul(effective_workers as u64)
            .ok_or_else(|| crate::Error::Invalid("candidate list reserve overflowed".into()))?
    } else {
        0
    };
    let candidate_list_enabled =
        blend_mode == BlendMode::Deghost && candidate_index_bytes_reserved <= geometry_headroom;
    let candidate_list_reserve = if candidate_list_enabled {
        candidate_index_bytes_reserved
    } else {
        0
    };
    let geometry_array_headroom = geometry_headroom.saturating_sub(candidate_list_reserve);
    let geometry_vector_header_bytes =
        std::mem::size_of::<Vec<(usize, TileGeometryCache)>>() as u64;
    let (geometry_cache_source_slots, geometry_cache_per_worker_cap) =
        if blend_mode == BlendMode::Deghost && candidate_list_enabled {
            bounded_geometry_cache_slots(
                geometry_array_headroom,
                effective_workers,
                geometry_slot_bytes,
                GEOMETRY_CACHE_MAX_BYTES_PER_WORKER,
                geometry_vector_header_bytes,
            )
            .ok_or_else(|| crate::Error::Invalid("geometry cache reserve overflowed".into()))?
        } else {
            (0, 0)
        };
    let geometry_cache_reserve = geometry_cache_per_worker_cap
        .checked_mul(effective_workers as u64)
        .ok_or_else(|| crate::Error::Invalid("geometry cache reserve overflowed".into()))?;
    let render_feature_reserve = geometry_cache_reserve
        .checked_add(candidate_list_reserve)
        .ok_or_else(|| crate::Error::Invalid("render feature reserve overflowed".into()))?;
    let cache_limit = if use_source_cache {
        budget_bytes
            .saturating_sub(active_reserve)
            .saturating_sub(render_feature_reserve)
            .max(cache_min_reserve)
    } else {
        0
    };
    let cache = Arc::new(DecodeCache::new(cache_limit, effective_workers.max(1)));
    let ownership_map = if blend_mode == BlendMode::Deghost && ownership_aware {
        Some(build_global_ownership_map(
            width,
            height,
            bounds,
            &sources,
            || checkpoint(completed, total),
        )?)
    } else {
        None
    };
    let hits = AtomicU64::new(0);
    let misses = AtomicU64::new(0);
    let decodes = AtomicU64::new(0);
    let visits = AtomicU64::new(0);
    let active_workers = AtomicU64::new(0);
    let peak_workers = AtomicU64::new(0);
    let decode_micros = AtomicU64::new(0);
    let encode_micros = AtomicU64::new(0);
    let geometry_cached_sources = AtomicU64::new(0);
    let geometry_projection_reuses = AtomicU64::new(0);
    let adjusted_ownership_reuses = AtomicU64::new(0);
    let owner_geometry_reuses = AtomicU64::new(0);
    let ownership_micros = AtomicU64::new(0);
    let classification_micros = AtomicU64::new(0);
    let blend_micros = AtomicU64::new(0);
    let output_micros = AtomicU64::new(0);
    let scene_person_pixels = AtomicU64::new(0);
    let scene_water_pixels = AtomicU64::new(0);
    let scene_object_fallbacks = AtomicU64::new(0);
    let mut tasks = Vec::new();
    for i in 0..total {
        if !checkpoint(completed, total) {
            return Err(crate::Error::Cancelled);
        }
        let row = i / u64::from(cols);
        let col = i % u64::from(cols);
        let path = dir.join(format!("{row}-{col}.png"));
        if path.exists() {
            validate_cached_tile(
                &path,
                (
                    (width - col as u32 * TILE).min(TILE),
                    (height - row as u32 * TILE).min(TILE),
                ),
            )?;
            completed += 1;
            if !checkpoint(completed, total) {
                return Err(crate::Error::Cancelled);
            }
        } else {
            tasks.push((row as u32, col as u32));
        }
    }
    tasks = spatial_block_order(tasks, cols as u32, rows as u32, 4);
    let ownership_map_ref = ownership_map.as_ref();
    for batch in tasks.chunks(effective_workers) {
        if !checkpoint(completed, total) {
            return Err(crate::Error::Cancelled);
        }
        let results = std::thread::scope(|scope| {
            let mut joins = Vec::new();
            for &(row, col) in batch {
                let ownership_map_ref = ownership_map_ref;
                let cache = cache.clone();
                let hits = &hits;
                let misses = &misses;
                let decodes = &decodes;
                let visits = &visits;
                let active_workers = &active_workers;
                let peak_workers = &peak_workers;
                let decode_micros = &decode_micros;
                let encode_micros = &encode_micros;
                let geometry_cached_sources = &geometry_cached_sources;
                let geometry_projection_reuses = &geometry_projection_reuses;
                let adjusted_ownership_reuses = &adjusted_ownership_reuses;
                let owner_geometry_reuses = &owner_geometry_reuses;
                let ownership_micros = &ownership_micros;
                let classification_micros = &classification_micros;
                let blend_micros = &blend_micros;
                let output_micros = &output_micros;
                let scene_person_pixels = &scene_person_pixels;
                let scene_water_pixels = &scene_water_pixels;
                let scene_object_fallbacks = &scene_object_fallbacks;
                let scene_plan_ref = scene_plan.as_ref();
                let sources_ref = sources.as_slice();
                let source_bytes_ref = source_bytes.as_slice();
                let dir_ref = dir.as_path();
                joins.push(scope.spawn(move || {
                    render_one_tile(
                        row,
                        col,
                        width,
                        height,
                        bounds,
                        sources_ref,
                        source_bytes_ref,
                        dir_ref,
                        &cache,
                        &hits,
                        &misses,
                        &decodes,
                        &visits,
                        &active_workers,
                        &peak_workers,
                        &decode_micros,
                        &encode_micros,
                        candidate_list_enabled,
                        geometry_cache_source_slots,
                        &geometry_cached_sources,
                        &geometry_projection_reuses,
                        &adjusted_ownership_reuses,
                        &owner_geometry_reuses,
                        &ownership_micros,
                        &classification_micros,
                        &blend_micros,
                        &output_micros,
                        use_source_cache,
                        blend_mode,
                        sharpness_aware,
                        ownership_map_ref,
                        scene_plan_ref,
                        scene_person_pixels,
                        scene_water_pixels,
                        scene_object_fallbacks,
                    )
                }));
            }
            joins
                .into_iter()
                .map(|j| {
                    j.join().unwrap_or_else(|_| {
                        Err(crate::Error::Invalid("tile worker panicked".into()))
                    })
                })
                .collect::<Vec<_>>()
        });
        for result in results {
            result?;
            completed += 1;
            if !checkpoint(completed, total) {
                return Err(crate::Error::Cancelled);
            }
        }
    }
    let seam_diagnostics = ownership_map.as_ref().map_or_else(
        || serde_json::json!({"enabled":false,"stridePx":0,"cellCount":0,"prepassMs":0.0,"decodedSourceCount":0,"mapAndScratchBytesReserved":0}),
        |map| serde_json::json!({"enabled":true,"stridePx":map.stride,"cellCount":map.owners.len(),"prepassMs":map.prepass_micros as f64/1000.0,"decodedSourceCount":map.decoded_sources,"mapAndScratchBytesReserved":map.scratch_bytes_reserved}),
    );
    let cache_guard = cache.state.lock().expect("decode cache lock");
    let render_ms = started.elapsed().as_secs_f64() * 1000.0;
    Ok(
        serde_json::json!({"width":width,"height":height,"tileSize":TILE,"tileBytesPerPixelReserved":tile_bytes_per_pixel,"rows":rows,"columns":cols,"completedTiles":completed,"backend":"cpu-rust-tiled","blendModel":blend_mode.model_name(),"workersRequested":workers_requested,"workersEffective":effective_workers,"peakConcurrentWorkers":peak_workers.load(Ordering::Relaxed),"workers":effective_workers,"sourceCacheEnabled":use_source_cache,"sourceCacheLimitBytes":cache_limit,"sourceCacheMinimumReserveBytes":cache_min_reserve,"peakSourceCacheBytes":cache_guard.peak_bytes,"sourceQualityMapBytesReserved":source_quality_map_reserve,"sourceQualityMapRefsPerWorkerBytesReserved":source_quality_refs_per_worker,"decodeSlotBytesReserved":decode_slot_bytes,"reservedDecodeSlots":effective_workers,"decodeSlotReserveBytes":decode_slot_reserve,"candidateListEnabled":candidate_list_enabled,"candidateIndexBytesPerWorkerReserved":if candidate_list_enabled { candidate_index_bytes_per_worker } else { 0 },"candidateIndexBytesReserved":candidate_list_reserve,"geometryCacheEnabled":geometry_cache_source_slots>0,"geometryCacheBytesPerWorkerReserved":geometry_cache_per_worker_cap,"geometryCacheBytesReserved":geometry_cache_reserve,"geometryCacheSourceSlotsPerTile":geometry_cache_source_slots,"estimatedActiveMemoryBytes":active_reserve+render_feature_reserve+cache_guard.peak_bytes,"memoryAccounting":"conservativeEstimate","sourceCacheHits":hits.load(Ordering::Relaxed),"sourceCacheMisses":misses.load(Ordering::Relaxed),"sourceDecodes":decodes.load(Ordering::Relaxed),"sourceDecodeWaits":cache.decode_waits.load(Ordering::Relaxed),"sourceDecodeErrors":cache.decode_errors.load(Ordering::Relaxed),"sourceDecodePeakInFlight":cache.peak_decode_slots.load(Ordering::Relaxed),"sourceDecodeMs":decode_micros.load(Ordering::Relaxed) as f64/1000.0,"tileEncodeMs":encode_micros.load(Ordering::Relaxed) as f64/1000.0,"sourceCandidateVisits":visits.load(Ordering::Relaxed),"geometryCachedSourceTileCount":geometry_cached_sources.load(Ordering::Relaxed),"geometryProjectionEvaluationsAvoided":geometry_projection_reuses.load(Ordering::Relaxed),"adjustedOwnershipScoresReused":adjusted_ownership_reuses.load(Ordering::Relaxed),"ownerGeometryValidityProjectionsReused":owner_geometry_reuses.load(Ordering::Relaxed),"ownershipPassMs":ownership_micros.load(Ordering::Relaxed) as f64/1000.0,"classificationPassMs":classification_micros.load(Ordering::Relaxed) as f64/1000.0,"blendPassMs":blend_micros.load(Ordering::Relaxed) as f64/1000.0,"finalOutputPassMs":output_micros.load(Ordering::Relaxed) as f64/1000.0,"schedule":"2d-block","scheduleBlockSize":4,"seamOwnership":seam_diagnostics,"sceneRendering":{"enabled":scene_plan.is_some(),"protectPeople":protect_people,"smoothWater":smooth_water,"personComponents":scene_plan.as_ref().map_or(0, scene_render::ScenePlan::component_count),"personObjects":scene_plan.as_ref().map_or(0, scene_render::ScenePlan::object_count),"personPixels":scene_person_pixels.load(Ordering::Relaxed),"waterOverlapPixels":scene_water_pixels.load(Ordering::Relaxed),"objectCoverageFallbacks":scene_object_fallbacks.load(Ordering::Relaxed),"sceneBytesReserved":scene_plan.as_ref().map_or(0, scene_render::ScenePlan::estimated_bytes),"sceneWorkerBytesReserved":scene_plan.as_ref().map_or(0, scene_render::ScenePlan::worker_bytes)},"renderMs":render_ms}),
    )
}

struct DecodeCache {
    state: Mutex<DecodeCacheState>,
    flights: Mutex<HashMap<usize, Arc<DecodeFlight>>>,
    decode_slots: Mutex<usize>,
    decode_ready: Condvar,
    decode_limit: usize,
    active_decode_slots: AtomicU64,
    peak_decode_slots: AtomicU64,
    decode_waits: AtomicU64,
    decode_errors: AtomicU64,
}
struct DecodeCacheState {
    map: HashMap<usize, Arc<RgbaImage>>,
    lru: VecDeque<usize>,
    bytes: u64,
    limit: u64,
    peak_bytes: u64,
}
struct DecodeFlight {
    result: Mutex<Option<std::result::Result<Arc<RgbaImage>, String>>>,
    ready: Condvar,
}
struct DecodeSlotGuard<'a> {
    cache: &'a DecodeCache,
}
impl Drop for DecodeSlotGuard<'_> {
    fn drop(&mut self) {
        self.cache
            .active_decode_slots
            .fetch_sub(1, Ordering::Relaxed);
        let mut slots = self.cache.decode_slots.lock().expect("decode gate lock");
        *slots = slots.saturating_sub(1);
        self.cache.decode_ready.notify_one();
    }
}
struct DecodeFlightGuard<'a> {
    cache: &'a DecodeCache,
    source_index: usize,
    flight: Arc<DecodeFlight>,
    completed: bool,
}
impl DecodeFlightGuard<'_> {
    fn complete(&mut self, result: std::result::Result<Arc<RgbaImage>, String>) {
        *self
            .flight
            .result
            .lock()
            .expect("decode flight result lock") = Some(result);
        self.completed = true;
        self.flight.ready.notify_all();
        self.cache
            .flights
            .lock()
            .expect("decode flights lock")
            .remove(&self.source_index);
    }
}
impl Drop for DecodeFlightGuard<'_> {
    fn drop(&mut self) {
        if !self.completed {
            self.cache.decode_errors.fetch_add(1, Ordering::Relaxed);
            *self
                .flight
                .result
                .lock()
                .expect("decode flight result lock") =
                Some(Err("source decode worker terminated unexpectedly".into()));
            self.flight.ready.notify_all();
            self.cache
                .flights
                .lock()
                .expect("decode flights lock")
                .remove(&self.source_index);
        }
    }
}
impl DecodeCache {
    fn new(limit: u64, decode_limit: usize) -> Self {
        Self {
            state: Mutex::new(DecodeCacheState {
                map: HashMap::new(),
                lru: VecDeque::new(),
                bytes: 0,
                limit,
                peak_bytes: 0,
            }),
            flights: Mutex::new(HashMap::new()),
            decode_slots: Mutex::new(0),
            decode_ready: Condvar::new(),
            decode_limit: decode_limit.max(1),
            active_decode_slots: AtomicU64::new(0),
            peak_decode_slots: AtomicU64::new(0),
            decode_waits: AtomicU64::new(0),
            decode_errors: AtomicU64::new(0),
        }
    }
}

fn spatial_block_order(
    mut tasks: Vec<(u32, u32)>,
    _cols: u32,
    _rows: u32,
    block: u32,
) -> Vec<(u32, u32)> {
    tasks.sort_by_key(|(row, col)| ((row / block, col / block), *row, *col));
    tasks
}

#[allow(clippy::too_many_arguments)]
fn source_image(
    source_index: usize,
    source: &Source,
    source_bytes: &[u64],
    cache: &DecodeCache,
    hits: &AtomicU64,
    misses: &AtomicU64,
    decodes: &AtomicU64,
    decode_micros: &AtomicU64,
    use_cache: bool,
) -> crate::Result<Arc<RgbaImage>> {
    source_image_with(
        source_index,
        source,
        source_bytes,
        cache,
        hits,
        misses,
        decodes,
        decode_micros,
        use_cache,
        |source| {
            image::open(&source.path)
                .map(|image| Arc::new(image.into_rgba8()))
                .map_err(|e| format!("failed to decode source {}: {e}", source.path.display()))
        },
    )
}

#[allow(clippy::too_many_arguments)]
fn source_image_with(
    source_index: usize,
    source: &Source,
    source_bytes: &[u64],
    cache: &DecodeCache,
    hits: &AtomicU64,
    misses: &AtomicU64,
    decodes: &AtomicU64,
    decode_micros: &AtomicU64,
    use_cache: bool,
    decode_source: impl FnOnce(&Source) -> std::result::Result<Arc<RgbaImage>, String>,
) -> crate::Result<Arc<RgbaImage>> {
    let mut state = cache.state.lock().expect("decode cache lock");
    if let Some(image) = state.map.get(&source_index).cloned() {
        hits.fetch_add(1, Ordering::Relaxed);
        if let Some(pos) = state.lru.iter().position(|index| *index == source_index) {
            state.lru.remove(pos);
        }
        state.lru.push_back(source_index);
        return Ok(image);
    }
    drop(state);
    let (flight, leader) = {
        let mut flights = cache.flights.lock().expect("decode flights lock");
        if let Some(flight) = flights.get(&source_index) {
            misses.fetch_add(1, Ordering::Relaxed);
            cache.decode_waits.fetch_add(1, Ordering::Relaxed);
            (flight.clone(), false)
        } else {
            // A caller may have missed the resident map just before another
            // decode completed. Recheck under the flight lock before creating
            // another load; completion never holds the state and flight locks
            // together, so this lock order cannot deadlock.
            if use_cache {
                let mut state = cache.state.lock().expect("decode cache lock");
                if let Some(image) = state.map.get(&source_index).cloned() {
                    hits.fetch_add(1, Ordering::Relaxed);
                    if let Some(pos) = state.lru.iter().position(|index| *index == source_index) {
                        state.lru.remove(pos);
                    }
                    state.lru.push_back(source_index);
                    return Ok(image);
                }
            }
            misses.fetch_add(1, Ordering::Relaxed);
            let flight = Arc::new(DecodeFlight {
                result: Mutex::new(None),
                ready: Condvar::new(),
            });
            flights.insert(source_index, flight.clone());
            (flight, true)
        }
    };
    if !leader {
        let mut result = flight.result.lock().expect("decode flight result lock");
        while result.is_none() {
            result = flight.ready.wait(result).expect("decode flight wait");
        }
        return result
            .as_ref()
            .unwrap()
            .clone()
            .map_err(crate::Error::Invalid);
    }
    let mut flight_guard = DecodeFlightGuard {
        cache,
        source_index,
        flight: flight.clone(),
        completed: false,
    };
    decodes.fetch_add(1, Ordering::Relaxed);
    let mut slots = cache.decode_slots.lock().expect("decode gate lock");
    while *slots >= cache.decode_limit {
        cache.decode_waits.fetch_add(1, Ordering::Relaxed);
        slots = cache.decode_ready.wait(slots).expect("decode gate wait");
    }
    *slots += 1;
    let active = cache.active_decode_slots.fetch_add(1, Ordering::Relaxed) + 1;
    cache.peak_decode_slots.fetch_max(active, Ordering::Relaxed);
    drop(slots);
    let slot_guard = DecodeSlotGuard { cache };
    let decode_started = Instant::now();
    let decoded = decode_source(source);
    decode_micros.fetch_add(
        decode_started.elapsed().as_micros() as u64,
        Ordering::Relaxed,
    );
    let decoded = decoded.and_then(|image| {
        if image.width() != source.width || image.height() != source.height {
            Err(format!(
                "source dimensions changed for {}",
                source.path.display()
            ))
        } else {
            Ok(image)
        }
    });
    drop(slot_guard);
    if decoded.is_err() {
        cache.decode_errors.fetch_add(1, Ordering::Relaxed);
    }
    let image = match decoded {
        Ok(image) => image,
        Err(message) => {
            flight_guard.complete(Err(message.clone()));
            return Err(crate::Error::Invalid(message));
        }
    };
    let mut state = cache.state.lock().expect("decode cache lock");
    if use_cache && state.limit > 0 && source_bytes[source_index] <= state.limit {
        while state.bytes.saturating_add(source_bytes[source_index]) > state.limit {
            if let Some(old) = state.lru.pop_front() {
                if let Some(old_image) = state.map.remove(&old) {
                    state.bytes -= u64::from(old_image.width()) * u64::from(old_image.height()) * 4;
                }
            } else {
                break;
            }
        }
        state.bytes = state
            .bytes
            .saturating_add(u64::from(image.width()) * u64::from(image.height()) * 4);
        state.peak_bytes = state.peak_bytes.max(state.bytes);
        state.map.insert(source_index, image.clone());
        state.lru.push_back(source_index);
    }
    drop(state);
    flight_guard.complete(Ok(image.clone()));
    Ok(image)
}

#[allow(clippy::too_many_arguments)]
fn source_quality_map(
    source_index: usize,
    source: &Source,
    source_bytes: &[u64],
    cache: &DecodeCache,
    hits: &AtomicU64,
    misses: &AtomicU64,
    decodes: &AtomicU64,
    decode_micros: &AtomicU64,
    use_cache: bool,
) -> crate::Result<Arc<SourceQualityMap>> {
    let mut quality = source.quality_map.lock().expect("source quality map lock");
    if let Some(map) = quality.as_ref() {
        return Ok(map.clone());
    }
    let image = source_image(
        source_index,
        source,
        source_bytes,
        cache,
        hits,
        misses,
        decodes,
        decode_micros,
        use_cache,
    )?;
    let map = Arc::new(SourceQualityMap::from_image(&image));
    *quality = Some(map.clone());
    Ok(map)
}

struct ActiveWorker<'a>(&'a AtomicU64);
impl Drop for ActiveWorker<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

fn render_one_tile(
    row: u32,
    col: u32,
    width: u32,
    height: u32,
    bounds: [f64; 4],
    sources: &[Source],
    source_bytes: &[u64],
    dir: &Path,
    cache: &DecodeCache,
    hits: &AtomicU64,
    misses: &AtomicU64,
    decodes: &AtomicU64,
    visits: &AtomicU64,
    active_workers: &AtomicU64,
    peak_workers: &AtomicU64,
    decode_micros: &AtomicU64,
    encode_micros: &AtomicU64,
    candidate_list_enabled: bool,
    geometry_cache_source_slots: usize,
    geometry_cached_sources: &AtomicU64,
    geometry_projection_reuses: &AtomicU64,
    adjusted_ownership_reuses: &AtomicU64,
    owner_geometry_reuses: &AtomicU64,
    ownership_micros: &AtomicU64,
    classification_micros: &AtomicU64,
    blend_micros: &AtomicU64,
    output_micros: &AtomicU64,
    use_cache: bool,
    blend_mode: BlendMode,
    sharpness_aware: bool,
    ownership_map: Option<&CoarseOwnershipMap>,
    scene_plan: Option<&scene_render::ScenePlan>,
    scene_person_pixels: &AtomicU64,
    scene_water_pixels: &AtomicU64,
    scene_object_fallbacks: &AtomicU64,
) -> crate::Result<()> {
    let active = active_workers.fetch_add(1, Ordering::Relaxed) + 1;
    peak_workers.fetch_max(active, Ordering::Relaxed);
    let _active_guard = ActiveWorker(active_workers);
    let left = col * TILE;
    let top = row * TILE;
    let tw = (width - left).min(TILE);
    let th = (height - top).min(TILE);
    let count = usize::try_from(tw).unwrap() * usize::try_from(th).unwrap();
    let mut accum = vec![[0.0f32; 4]; count];
    let x_rays: Vec<(f64, f64)> = (0..tw)
        .map(|px| {
            let yaw = bounds[0]
                + (f64::from(left + px) + 0.5) / f64::from(width) * (bounds[1] - bounds[0]);
            (yaw.sin(), yaw.cos())
        })
        .collect();
    let y_rays: Vec<(f64, f64)> = (0..th)
        .map(|py| {
            let pitch = bounds[3]
                - (f64::from(top + py) + 0.5) / f64::from(height) * (bounds[3] - bounds[2]);
            (pitch.sin(), pitch.cos())
        })
        .collect();
    let scene_tile = scene_plan
        .map(|plan| plan.tile(row, col, &x_rays, &y_rays, bounds, sources))
        .transpose()?
        .unwrap_or_default();
    scene_person_pixels.fetch_add(scene_tile.person_pixels, Ordering::Relaxed);
    scene_water_pixels.fetch_add(scene_tile.water_pixels, Ordering::Relaxed);
    scene_object_fallbacks.fetch_add(scene_tile.object_fallbacks, Ordering::Relaxed);
    let mut max_adjusted_ownership =
        (blend_mode == BlendMode::Deghost).then(|| vec![f64::NEG_INFINITY; count]);
    let mut max_ownership =
        (blend_mode == BlendMode::Deghost).then(|| vec![f64::NEG_INFINITY; count]);
    let mut second_ownership =
        (blend_mode == BlendMode::Deghost).then(|| vec![f64::NEG_INFINITY; count]);
    let mut max_owner_source = (blend_mode == BlendMode::Deghost).then(|| vec![usize::MAX; count]);
    let mut second_owner_source =
        (blend_mode == BlendMode::Deghost).then(|| vec![usize::MAX; count]);
    let stable_source_ranks = if blend_mode == BlendMode::Deghost {
        let mut source_order: Vec<usize> = (0..sources.len()).collect();
        source_order.sort_by(|&left, &right| {
            let left = &sources[left];
            let right = &sources[right];
            left.path
                .cmp(&right.path)
                .then_with(|| {
                    left.camera_to_world
                        .iter()
                        .map(|value| value.to_bits())
                        .cmp(right.camera_to_world.iter().map(|value| value.to_bits()))
                })
                .then_with(|| {
                    match (
                        left.source_plane_warp.as_ref(),
                        right.source_plane_warp.as_ref(),
                    ) {
                        (None, None) => std::cmp::Ordering::Equal,
                        (None, Some(_)) => std::cmp::Ordering::Less,
                        (Some(_), None) => std::cmp::Ordering::Greater,
                        (Some(left), Some(right)) => left
                            .columns
                            .cmp(&right.columns)
                            .then_with(|| left.rows.cmp(&right.rows))
                            .then_with(|| {
                                left.offsets
                                    .iter()
                                    .flatten()
                                    .map(|value| value.to_bits())
                                    .cmp(
                                        right.offsets.iter().flatten().map(|value| value.to_bits()),
                                    )
                            }),
                    }
                })
                .then_with(|| left.width.cmp(&right.width))
                .then_with(|| left.height.cmp(&right.height))
                .then_with(|| left.fx.to_bits().cmp(&right.fx.to_bits()))
                .then_with(|| left.fy.to_bits().cmp(&right.fy.to_bits()))
                .then_with(|| left.cx.to_bits().cmp(&right.cx.to_bits()))
                .then_with(|| left.cy.to_bits().cmp(&right.cy.to_bits()))
        });
        let mut ranks = vec![0usize; sources.len()];
        for (rank, source_index) in source_order.into_iter().enumerate() {
            ranks[source_index] = rank;
        }
        Some(ranks)
    } else {
        None
    };
    let mut source_quality_maps = vec![None; sources.len()];
    let candidate_sources = if candidate_list_enabled {
        let mut indices = Vec::new();
        indices.try_reserve_exact(sources.len()).map_err(|error| {
            crate::Error::Invalid(format!(
                "cannot reserve renderer candidate indices: {error}"
            ))
        })?;
        for (index, source) in sources.iter().enumerate() {
            if candidate(source, bounds, left, top, tw, th, width, height) {
                indices.push(index);
            }
        }
        Some(indices)
    } else {
        None
    };
    let mut tile_geometry = Vec::<(usize, TileGeometryCache)>::new();
    if geometry_cache_source_slots > 0 {
        tile_geometry
            .try_reserve_exact(geometry_cache_source_slots)
            .map_err(|error| {
                crate::Error::Invalid(format!("cannot reserve renderer geometry slots: {error}"))
            })?;
        let candidates = candidate_sources
            .as_deref()
            .expect("geometry cache reserves the candidate list");
        // Warp candidates are selected first; each class retains source order.
        for active_warp in [true, false] {
            for &index in candidates {
                if tile_geometry.len() == geometry_cache_source_slots {
                    break;
                }
                let has_active_warp = sources[index]
                    .source_plane_warp
                    .as_ref()
                    .is_some_and(|warp| !warp.is_zero());
                if has_active_warp == active_warp {
                    tile_geometry.push((index, TileGeometryCache::new(count)));
                }
            }
        }
    }
    let mut tile_cached_source_count = 0u64;
    let mut tile_projection_reuses = 0u64;
    let mut tile_adjusted_ownership_reuses = 0u64;
    let mut tile_owner_geometry_reuses = 0u64;
    if blend_mode == BlendMode::Deghost {
        let ownership_started = Instant::now();
        for source_index in CandidateSourceIndices::new(candidate_sources.as_deref(), sources.len())
        {
            if candidate_sources.is_none()
                && !candidate(
                    &sources[source_index],
                    bounds,
                    left,
                    top,
                    tw,
                    th,
                    width,
                    height,
                )
            {
                continue;
            }
            let source = &sources[source_index];
            let quality = source_quality_map(
                source_index,
                source,
                source_bytes,
                cache,
                hits,
                misses,
                decodes,
                decode_micros,
                use_cache,
            )?;
            source_quality_maps[source_index] = Some(quality.clone());
            let mut cached_geometry = tile_geometry
                .iter_mut()
                .find(|(index, _)| *index == source_index)
                .map(|(_, geometry)| geometry);
            for py in 0..th {
                for px in 0..tw {
                    let (sy, cy) = x_rays[px as usize];
                    let (sp, cp) = y_rays[py as usize];
                    let world = [sy * cp, sp, cy * cp];
                    let index = (py * tw + px) as usize;
                    if let Some((source_x, source_y, _, ownership)) = sample_geometry(source, world)
                    {
                        if let Some(geometry) = cached_geometry.as_mut() {
                            geometry.store(index, source_x, source_y);
                        }
                        let scores = max_ownership.as_mut().unwrap();
                        let runner_up = second_ownership.as_mut().unwrap();
                        let owners = max_owner_source.as_mut().unwrap();
                        insert_top_two_ownership(
                            ownership,
                            source_index,
                            stable_source_ranks.as_ref().unwrap(),
                            &mut scores[index],
                            &mut owners[index],
                            &mut runner_up[index],
                            &mut second_owner_source.as_mut().unwrap()[index],
                        );
                    }
                }
            }
        }
        ownership_micros.fetch_add(
            ownership_started.elapsed().as_micros() as u64,
            Ordering::Relaxed,
        );
        // Apply continuous quality suppression only after peer sharpness is
        // known, then use the same adjusted score as the softmax reference.
        // This keeps source ordering irrelevant and removes gate-dependent
        // changes to the reference score.
        let classification_started = Instant::now();
        for source_index in CandidateSourceIndices::new(candidate_sources.as_deref(), sources.len())
        {
            if candidate_sources.is_none()
                && !candidate(
                    &sources[source_index],
                    bounds,
                    left,
                    top,
                    tw,
                    th,
                    width,
                    height,
                )
            {
                continue;
            }
            let source = &sources[source_index];
            let quality = source_quality_maps[source_index]
                .as_ref()
                .expect("quality map prepared in geometry pass");
            let cached_geometry_index = tile_geometry
                .iter()
                .position(|(index, _)| *index == source_index);
            for py in 0..th {
                for px in 0..tw {
                    let (sy, cy) = x_rays[px as usize];
                    let (sp, cp) = y_rays[py as usize];
                    let world = [sy * cp, sp, cy * cp];
                    let index = (py * tw + px) as usize;
                    let geometry = if let Some(cached_index) = cached_geometry_index {
                        tile_geometry[cached_index].1.get(source, index)
                    } else {
                        sample_geometry(source, world)
                    };
                    if let Some((source_x, source_y, _, ownership)) = geometry {
                        let (texture_energy, obstruction_confidence) =
                            quality.sample(source.width, source.height, source_x, source_y);
                        let sharpness =
                            quality.sharpness(source.width, source.height, source_x, source_y);
                        let (peer_ownership, peer_texture, peer_sharp) = best_other_source_quality(
                            source_index,
                            index,
                            world,
                            sources,
                            &source_quality_maps,
                            &tile_geometry,
                            max_owner_source.as_ref().unwrap(),
                            second_owner_source.as_ref().unwrap(),
                            max_ownership.as_ref().unwrap(),
                            second_ownership.as_ref().unwrap(),
                        );
                        let adjusted = adjusted_ownership(
                            ownership,
                            peer_ownership,
                            peer_texture,
                            obstruction_confidence,
                            texture_energy,
                            sharpness,
                            if sharpness_aware { peer_sharp } else { 0.0 },
                            source.width.min(source.height),
                        );
                        if let Some(cached_index) = cached_geometry_index {
                            tile_geometry[cached_index]
                                .1
                                .store_adjusted_ownership(index, adjusted);
                        }
                        let scores = max_adjusted_ownership.as_mut().unwrap();
                        scores[index] = scores[index].max(adjusted);
                    }
                }
            }
            if tile_geometry
                .iter()
                .any(|(index, _)| *index == source_index)
            {
                tile_projection_reuses += count as u64;
            }
        }
        classification_micros.fetch_add(
            classification_started.elapsed().as_micros() as u64,
            Ordering::Relaxed,
        );
        geometry_projection_reuses.fetch_add(tile_projection_reuses, Ordering::Relaxed);
        tile_projection_reuses = 0;
    }
    let blend_started = Instant::now();
    // The ownership prior asks whether the same map-selected source projects
    // at each output pixel for every overlapping blend source. Cache that
    // answer once per tile in a packed bitset. Its worst-case storage is
    // 1/8 byte per pixel plus one Vec header, within the existing 8 B/pixel
    // margin in the full 512x512 tile reservation (including edge tiles).
    let owner_validity = ownership_map.map(|ownership_map| {
        let mut validity = OwnerValidity::new(count);
        for py in 0..th {
            for px in 0..tw {
                let index = (py * tw + px) as usize;
                let (sy, cy) = x_rays[px as usize];
                let (sp, cp) = y_rays[py as usize];
                let world = [sy * cp, sp, cy * cp];
                let scene_override = scene_blend_override(
                    scene_plan.is_some_and(|plan| plan.identity.protect_people),
                    scene_plan.is_some_and(|plan| plan.identity.smooth_water),
                    scene_tile.person_owner.get(index).copied().flatten(),
                    scene_tile.water_blend.get(index).copied().unwrap_or(0),
                );
                if scene_override == SceneBlendOverride::Base {
                    let Some(owner) = ownership_map.owner_at(left + px, top + py) else {
                        continue;
                    };
                    let (valid, cached) =
                        source_geometry_is_valid(owner, index, world, sources, &tile_geometry);
                    validity.set(index, valid);
                    tile_owner_geometry_reuses += u64::from(cached);
                }
            }
        }
        validity
    });
    for source_index in CandidateSourceIndices::new(candidate_sources.as_deref(), sources.len()) {
        if candidate_sources.is_none()
            && !candidate(
                &sources[source_index],
                bounds,
                left,
                top,
                tw,
                th,
                width,
                height,
            )
        {
            continue;
        }
        let source = &sources[source_index];
        visits.fetch_add(1, Ordering::Relaxed);
        let cached = tile_geometry
            .iter()
            .find(|(index, _)| *index == source_index)
            .map(|(_, geometry)| geometry);
        if cached.is_some() {
            tile_cached_source_count += 1;
        }
        let image = source_image(
            source_index,
            source,
            source_bytes,
            cache,
            hits,
            misses,
            decodes,
            decode_micros,
            use_cache,
        )?;
        for py in 0..th {
            for px in 0..tw {
                let (sy, cy) = x_rays[px as usize];
                let (sp, cp) = y_rays[py as usize];
                let world = [sy * cp, sp, cy * cp];
                let index = (py * tw + px) as usize;
                let geometry = if let Some(cached) = cached {
                    cached.get(source, index)
                } else {
                    sample_geometry(source, world)
                };
                if let Some(geometry) = geometry {
                    let (rgb, weight, ownership, x, y) =
                        sample_with_geometry(source, &image, geometry);
                    let mut blend_weight = match blend_mode {
                        BlendMode::Feather => weight,
                        BlendMode::Deghost => {
                            let index = (py * tw + px) as usize;
                            let cached_adjusted =
                                cached.and_then(|geometry| geometry.get_adjusted_ownership(index));
                            let adjusted = if let Some(adjusted) = cached_adjusted {
                                tile_adjusted_ownership_reuses += 1;
                                adjusted
                            } else {
                                let quality = source_quality_maps[source_index]
                                    .as_ref()
                                    .expect("deghost quality map prepared in geometry pass");
                                let (texture_energy, obstruction_confidence) =
                                    quality.sample(source.width, source.height, x, y);
                                let sharpness =
                                    quality.sharpness(source.width, source.height, x, y);
                                let (peer_ownership, peer_texture, peer_sharpness) =
                                    best_other_source_quality(
                                        source_index,
                                        index,
                                        world,
                                        sources,
                                        &source_quality_maps,
                                        &tile_geometry,
                                        max_owner_source.as_ref().unwrap(),
                                        second_owner_source.as_ref().unwrap(),
                                        max_ownership.as_ref().unwrap(),
                                        second_ownership.as_ref().unwrap(),
                                    );
                                adjusted_ownership(
                                    ownership,
                                    peer_ownership,
                                    peer_texture,
                                    obstruction_confidence,
                                    texture_energy,
                                    sharpness,
                                    if sharpness_aware { peer_sharpness } else { 0.0 },
                                    source.width.min(source.height),
                                )
                            };
                            deghost_weight(
                                adjusted,
                                max_adjusted_ownership.as_ref().unwrap()[index],
                                source.width.min(source.height),
                            )
                        }
                    };
                    let scene_override = scene_blend_override(
                        scene_plan.is_some_and(|plan| plan.identity.protect_people),
                        scene_plan.is_some_and(|plan| plan.identity.smooth_water),
                        scene_tile.person_owner.get(index).copied().flatten(),
                        scene_tile.water_blend.get(index).copied().unwrap_or(0),
                    );
                    match scene_override {
                        SceneBlendOverride::Person(person_owner) => {
                            if source_index != person_owner {
                                continue;
                            }
                            // Copy the selected view through the whole dilated
                            // object union, including its narrow background band.
                            blend_weight = 1.0;
                        }
                        SceneBlendOverride::SmoothWater(strength) => {
                            // Water keeps valid views in the feather profile,
                            // even when the base panorama mode is deghost.
                            let strength = f64::from(strength) / 255.0;
                            blend_weight += (weight - blend_weight) * strength;
                        }
                        SceneBlendOverride::Base => {}
                    }
                    if blend_mode == BlendMode::Deghost
                        && scene_override == SceneBlendOverride::Base
                    {
                        if let Some(ownership_map) = ownership_map {
                            let global_x = left + px;
                            let global_y = top + py;
                            let owner_valid = owner_validity
                                .as_ref()
                                .is_some_and(|validity| validity.get(index));
                            let probability = if owner_valid {
                                ownership_map.source_probability(
                                    source_index,
                                    global_x,
                                    global_y,
                                    4,
                                )
                            } else {
                                1.0
                            };
                            let confidence = ownership_map.confidence_at(global_x, global_y);
                            let prior = 1.0 - confidence + confidence * probability;
                            blend_weight *= f64::from(0.05 + 0.95 * prior);
                        }
                    }
                    accumulate_weighted(&mut accum[index], rgb, blend_weight);
                }
            }
        }
        if cached.is_some() {
            tile_projection_reuses += count as u64;
        }
    }
    geometry_cached_sources.fetch_add(tile_cached_source_count, Ordering::Relaxed);
    geometry_projection_reuses.fetch_add(tile_projection_reuses, Ordering::Relaxed);
    adjusted_ownership_reuses.fetch_add(tile_adjusted_ownership_reuses, Ordering::Relaxed);
    owner_geometry_reuses.fetch_add(tile_owner_geometry_reuses, Ordering::Relaxed);
    blend_micros.fetch_add(
        blend_started.elapsed().as_micros() as u64,
        Ordering::Relaxed,
    );
    let mut tile: RgbaImage = ImageBuffer::from_pixel(tw, th, Rgba([0, 0, 0, 0]));
    let output_started = Instant::now();
    for py in 0..th {
        for px in 0..tw {
            let cell = accum[(py * tw + px) as usize];
            if cell[3] > 0. {
                tile.put_pixel(
                    px,
                    py,
                    Rgba([
                        srgb_from_blend_f32(cell[0] / cell[3]),
                        srgb_from_blend_f32(cell[1] / cell[3]),
                        srgb_from_blend_f32(cell[2] / cell[3]),
                        255,
                    ]),
                );
            }
        }
    }
    output_micros.fetch_add(
        output_started.elapsed().as_micros() as u64,
        Ordering::Relaxed,
    );
    let out = dir.join(format!("{row}-{col}.png"));
    let temp = dir.join(format!(
        "{row}-{col}.tmp-{}-{:?}.png",
        std::process::id(),
        std::thread::current().id()
    ));
    let encode_started = Instant::now();
    tile.save(&temp)?;
    encode_micros.fetch_add(
        encode_started.elapsed().as_micros() as u64,
        Ordering::Relaxed,
    );
    if out.exists() {
        let _ = fs::remove_file(temp);
        return Err(crate::Error::Invalid(format!(
            "tile destination already exists: {}",
            out.display()
        )));
    }
    fs::rename(temp, out)?;
    Ok(())
}

/// Derive each lower-resolution pyramid level from its predecessor. Returns
/// manifest-compatible level records; no original source is reprojected.
pub fn build_pyramid_levels(
    output: &Path,
    width: u32,
    height: u32,
    checkpoint: impl FnMut(u64, u64) -> bool,
) -> crate::Result<Vec<Value>> {
    build_pyramid_levels_with_options(output, width, height, 4096, 1, checkpoint)
        .map(|(levels, _)| levels)
}

pub fn build_pyramid_levels_with_options(
    output: &Path,
    width: u32,
    height: u32,
    memory_budget_mib: usize,
    workers_requested: usize,
    mut checkpoint: impl FnMut(u64, u64) -> bool,
) -> crate::Result<(Vec<Value>, Value)> {
    if !(32..=crate::job_resources::MAX_JOB_MEMORY_MIB).contains(&memory_budget_mib) {
        return Err(crate::Error::Invalid(format!(
            "memoryBudgetMiB must be 32..={}",
            crate::job_resources::MAX_JOB_MEMORY_MIB
        )));
    }
    if !(1..=32).contains(&workers_requested) {
        return Err(crate::Error::Invalid("workers must be 1..=32".into()));
    }
    const WORKER_RESERVE_BYTES: u64 = crate::job_resources::PYRAMID_WORKER_RESERVE_BYTES;
    let memory_workers = (crate::job_resources::checked_memory_budget_bytes(memory_budget_mib)
        .ok_or_else(|| crate::Error::Invalid("memoryBudgetMiB overflows byte accounting".into()))?
        / WORKER_RESERVE_BYTES)
        .max(1) as usize;
    let started = Instant::now();
    let mut levels = Vec::new();
    let mut peak_workers = 0usize;
    let mut workers_effective = 1usize;
    let mut level = 0u32;
    let mut w = width;
    let mut h = height;
    loop {
        let cols = w.div_ceil(TILE);
        let rows = h.div_ceil(TILE);
        let mut occupied = Vec::new();
        for r in 0..rows {
            for c in 0..cols {
                let p = format!("level-{level}/{r}-{c}.png");
                occupied.push(serde_json::json!({"row":r,"column":c,"path":p,"width":w.saturating_sub(c*TILE).min(TILE),"height":h.saturating_sub(r*TILE).min(TILE)}));
            }
        }
        levels.push(serde_json::json!({"level":level,"width":w,"height":h,"columns":cols,"rows":rows,"occupied":occupied}));
        if w == 1 && h == 1 {
            break;
        }
        let nw = w.div_ceil(2);
        let nh = h.div_ceil(2);
        let ncols = nw.div_ceil(TILE);
        let nrows = nh.div_ceil(TILE);
        let total = u64::from(ncols) * u64::from(nrows);
        let mut done = 0u64;
        let prev = output.join(format!("level-{level}"));
        let next = output.join(format!("level-{}", level + 1));
        fs::create_dir_all(&next)?;
        let mut tasks = Vec::new();
        for tr in 0..nrows {
            for tc in 0..ncols {
                if !checkpoint(done, total) {
                    return Err(crate::Error::Cancelled);
                }
                let tw = (nw - tc * TILE).min(TILE);
                let th = (nh - tr * TILE).min(TILE);
                let dest = next.join(format!("{tr}-{tc}.png"));
                if dest.is_file() {
                    validate_cached_tile(&dest, (tw, th))?;
                    done += 1;
                    if !checkpoint(done, total) {
                        return Err(crate::Error::Cancelled);
                    }
                    continue;
                }
                tasks.push((tr, tc));
            }
        }
        let effective_workers = workers_requested
            .min(memory_workers)
            .min(tasks.len().max(1));
        workers_effective = workers_effective.max(effective_workers);
        for batch in tasks.chunks(effective_workers) {
            if !checkpoint(done, total) {
                return Err(crate::Error::Cancelled);
            }
            let prev_ref = prev.as_path();
            let next_ref = next.as_path();
            std::thread::scope(|scope| {
                let joins = batch
                    .iter()
                    .map(|&(tr, tc)| {
                        scope.spawn(move || {
                            render_pyramid_tile(prev_ref, next_ref, w, h, nw, nh, tr, tc)
                        })
                    })
                    .collect::<Vec<_>>();
                for join in joins {
                    match join.join() {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => return Err(e),
                        Err(_) => {
                            return Err(crate::Error::Invalid("pyramid worker panicked".into()))
                        }
                    }
                }
                Ok(())
            })?;
            peak_workers = peak_workers.max(batch.len());
            for _ in batch {
                done += 1;
                if !checkpoint(done, total) {
                    return Err(crate::Error::Cancelled);
                }
            }
        }
        w = nw;
        h = nh;
        level += 1;
    }
    Ok((
        levels,
        serde_json::json!({"workersRequested":workers_requested,"workersEffective":workers_effective,"peakConcurrentWorkers":peak_workers,"estimatedActiveMemoryBytes":(peak_workers as u64)*WORKER_RESERVE_BYTES,"memoryAccounting":"conservativeEstimate","pyramidMs":started.elapsed().as_secs_f64()*1000.0}),
    ))
}

fn render_pyramid_tile(
    prev: &Path,
    next: &Path,
    w: u32,
    h: u32,
    nw: u32,
    nh: u32,
    tr: u32,
    tc: u32,
) -> crate::Result<()> {
    let tw = (nw - tc * TILE).min(TILE);
    let th = (nh - tr * TILE).min(TILE);
    let mut cache: HashMap<(u32, u32), RgbaImage> = HashMap::new();
    let mut img = RgbaImage::new(tw, th);
    for y in 0..th {
        for x in 0..tw {
            let gx = (tc * TILE + x) * 2;
            let gy = (tr * TILE + y) * 2;
            let mut premul = [0f64; 3];
            let mut alpha = 0f64;
            let mut count = 0f64;
            for oy in 0..2 {
                for ox in 0..2 {
                    let sx = gx + ox;
                    let sy = gy + oy;
                    if sx >= w || sy >= h {
                        continue;
                    }
                    count += 1.;
                    let sr = sy / TILE;
                    let sc = sx / TILE;
                    let key = (sr, sc);
                    if !cache.contains_key(&key) {
                        let path = prev.join(format!("{sr}-{sc}.png"));
                        if !path.is_file() {
                            return Err(crate::Error::Invalid(format!(
                                "missing pyramid source tile {}",
                                path.display()
                            )));
                        }
                        let expected = ((w - sc * TILE).min(TILE), (h - sr * TILE).min(TILE));
                        let source_image = image::open(&path)?.to_rgba8();
                        if source_image.dimensions() != expected {
                            return Err(crate::Error::Invalid(format!(
                                "pyramid source tile {} has invalid dimensions",
                                path.display()
                            )));
                        }
                        cache.insert(key, source_image);
                    }
                    let p = cache[&key].get_pixel(sx % TILE, sy % TILE).0;
                    let a = f64::from(p[3]) / 255.;
                    alpha += a;
                    for k in 0..3 {
                        premul[k] += linear(f64::from(p[k]) / 255.) * a;
                    }
                }
            }
            if alpha > 0. {
                img.put_pixel(
                    x,
                    y,
                    Rgba([
                        srgb(premul[0] / alpha),
                        srgb(premul[1] / alpha),
                        srgb(premul[2] / alpha),
                        (alpha / count * 255. + 0.5) as u8,
                    ]),
                );
            }
        }
    }
    let dest = next.join(format!("{tr}-{tc}.png"));
    let temp = next.join(format!(
        "{tr}-{tc}.tmp-{}-{:?}.png",
        std::process::id(),
        std::thread::current().id()
    ));
    img.save(&temp)?;
    if dest.exists() {
        let _ = fs::remove_file(&temp);
        return Err(crate::Error::Invalid(format!(
            "pyramid tile destination already exists: {}",
            dest.display()
        )));
    }
    fs::rename(temp, dest)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    #[test]
    fn geometry_cache_reservation_includes_vector_header_at_exact_budget_edges() {
        let slot_bytes = geometry_cache_slot_bytes().unwrap();
        assert_eq!(
            slot_bytes,
            512 * 512 * 3 * std::mem::size_of::<f64>() as u64
                + std::mem::size_of::<(usize, TileGeometryCache)>() as u64
        );
        let header_bytes = std::mem::size_of::<Vec<(usize, TileGeometryCache)>>() as u64;
        let per_worker_limit = GEOMETRY_CACHE_MAX_BYTES_PER_WORKER;

        for workers in 1usize..=8 {
            let workers_bytes = workers as u64;
            for slots_requested in 0u64..=4 {
                let exact_per_worker = if slots_requested == 0 {
                    0
                } else {
                    header_bytes + slots_requested * slot_bytes
                };
                let exact_budget = exact_per_worker * workers_bytes;
                for available in [
                    exact_budget.saturating_sub(1),
                    exact_budget,
                    exact_budget.saturating_add(workers_bytes - 1),
                ] {
                    let (slots, reserved_per_worker) = bounded_geometry_cache_slots(
                        available,
                        workers,
                        slot_bytes,
                        per_worker_limit,
                        header_bytes,
                    )
                    .unwrap();
                    let reserved_total = reserved_per_worker * workers_bytes;
                    assert!(reserved_total <= available);
                    assert!(reserved_per_worker <= per_worker_limit);
                    if slots > 0 {
                        assert_eq!(
                            reserved_per_worker,
                            header_bytes + slots as u64 * slot_bytes
                        );
                    } else {
                        assert_eq!(reserved_per_worker, 0);
                    }
                }
            }
        }
    }

    #[test]
    fn owner_validity_uses_cached_geometry_and_missing_slots_fall_back() {
        let source = cache_test_source(PathBuf::from("owner"));
        let sources = vec![source];
        let world = [0.0, 0.0, 1.0];
        let mut cache = TileGeometryCache::new(2);
        let supported = sample_geometry(&sources[0], world).unwrap();
        cache.store(0, supported.0, supported.1);
        let cached = source_geometry_is_valid(0, 0, world, &sources, &[(0, cache)]);
        assert_eq!(cached, (true, true));

        let invalid_cache = TileGeometryCache::new(1);
        let invalid =
            source_geometry_is_valid(0, 0, [0.0, 0.0, -1.0], &sources, &[(0, invalid_cache)]);
        assert_eq!(invalid, (false, true));

        let uncached_valid = source_geometry_is_valid(0, 0, world, &sources, &[]);
        assert_eq!(uncached_valid, (true, false));
        let uncached_invalid = source_geometry_is_valid(0, 0, [0.0, 0.0, -1.0], &sources, &[]);
        assert_eq!(uncached_invalid, (false, false));

        let mut bits = OwnerValidity::new(65);
        bits.set(0, true);
        bits.set(63, true);
        bits.set(64, true);
        assert!(bits.get(0));
        assert!(bits.get(63));
        assert!(bits.get(64));
        assert!(!bits.get(1));
    }

    #[test]
    fn global_ownership_prepass_populates_reusable_source_quality_map() {
        let root = std::env::temp_dir().join(format!(
            "lumia-quality-prepass-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("source.png");
        RgbaImage::from_pixel(16, 16, Rgba([80, 90, 100, 255]))
            .save(&path)
            .unwrap();
        let mut source = cache_test_source(path);
        source.width = 16;
        source.height = 16;
        source.fx = 8.0;
        source.fy = 8.0;
        source.cx = 7.5;
        source.cy = 7.5;
        let sources = vec![source];
        let _ownership =
            build_global_ownership_map(16, 16, [-0.1, 0.1, -0.1, 0.1], &sources, || true).unwrap();
        let prepass_quality = sources[0]
            .quality_map
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .clone();
        let cache = DecodeCache::new(0, 1);
        let hits = AtomicU64::new(0);
        let misses = AtomicU64::new(0);
        let decodes = AtomicU64::new(0);
        let decode_micros = AtomicU64::new(0);
        let post_prepass_quality = source_quality_map(
            0,
            &sources[0],
            &[16 * 16 * 4],
            &cache,
            &hits,
            &misses,
            &decodes,
            &decode_micros,
            false,
        )
        .unwrap();
        assert!(Arc::ptr_eq(&prepass_quality, &post_prepass_quality));
        assert_eq!(decodes.load(Ordering::Relaxed), 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn final_blend_f32_lut_matches_reference_around_every_byte_boundary() {
        let thresholds = srgb_f32_thresholds();
        for byte in 1..=255usize {
            let boundary = thresholds[byte];
            let start = boundary.saturating_sub(256);
            let end = boundary.saturating_add(256).min(1.0f32.to_bits());
            for bits in start..=end {
                let value = f32::from_bits(bits);
                assert_eq!(
                    srgb_from_blend_f32(value),
                    srgb(f64::from(value)),
                    "f32 sRGB lookup mismatch near byte {byte} at bits {bits:#010x}"
                );
            }
        }

        // Exercise actual blend-ratio-shaped values plus the complete coarse
        // bucket boundaries without relying on host random-number libraries.
        let bucket_base = srgb_f32_bucket_base();
        for bucket in 0..bucket_base.len() as u32 {
            let bits = bucket << 16;
            let value = f32::from_bits(bits);
            assert_eq!(srgb_from_blend_f32(value), srgb(f64::from(value)));
        }
        let mut state = 0x8d12_7a49u32;
        for _ in 0..100_000 {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            let bits = state & 1.0f32.to_bits();
            let value = f32::from_bits(bits);
            assert_eq!(srgb_from_blend_f32(value), srgb(f64::from(value)));
        }
    }

    fn wait_for_decode_waiters(cache: &DecodeCache, expected: u64) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while cache.decode_waits.load(Ordering::Relaxed) < expected {
            assert!(
                Instant::now() < deadline,
                "decode waiters did not register before deadline"
            );
            std::thread::yield_now();
        }
    }

    fn cache_test_source(path: PathBuf) -> Source {
        Source {
            path,
            width: 4,
            height: 4,
            fx: 1.0,
            fy: 1.0,
            cx: 1.5,
            cy: 1.5,
            camera_to_world: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
            source_plane_warp: None,
            quality_map: Arc::new(Mutex::new(None)),
            center: [0.0, 0.0, 1.0],
            cone_radius: 1.0,
        }
    }

    #[test]
    fn decode_single_flight_shares_success_and_failure_with_concurrent_waiters() {
        for should_fail in [false, true] {
            let cache = Arc::new(DecodeCache::new(1024, 4));
            let source = cache_test_source(PathBuf::from("injected"));
            let source_bytes = [64];
            let hits = AtomicU64::new(0);
            let misses = AtomicU64::new(0);
            let decodes = AtomicU64::new(0);
            let decode_micros = AtomicU64::new(0);
            let decode_calls = AtomicU64::new(0);
            let barrier = Arc::new(std::sync::Barrier::new(8));
            std::thread::scope(|scope| {
                let mut joins = Vec::new();
                for _ in 0..8 {
                    let cache = cache.clone();
                    let barrier = barrier.clone();
                    let source = &source;
                    let source_bytes_ref = &source_bytes;
                    let hits_ref = &hits;
                    let misses_ref = &misses;
                    let decodes_ref = &decodes;
                    let decode_micros_ref = &decode_micros;
                    let decode_calls_ref = &decode_calls;
                    let cache_wait = cache.clone();
                    joins.push(scope.spawn(move || {
                        barrier.wait();
                        source_image_with(
                            0,
                            source,
                            source_bytes_ref,
                            &cache,
                            hits_ref,
                            misses_ref,
                            decodes_ref,
                            decode_micros_ref,
                            true,
                            |_| {
                                decode_calls_ref.fetch_add(1, Ordering::Relaxed);
                                wait_for_decode_waiters(&cache_wait, 7);
                                if should_fail {
                                    Err("injected decode failure".into())
                                } else {
                                    Ok(Arc::new(RgbaImage::from_pixel(4, 4, Rgba([1, 2, 3, 255]))))
                                }
                            },
                        )
                    }));
                }
                let results = joins
                    .into_iter()
                    .map(|join| join.join().unwrap())
                    .collect::<Vec<_>>();
                if should_fail {
                    assert!(results.iter().all(|result| result.is_err()));
                    assert!(results.iter().all(|result| result
                        .as_ref()
                        .unwrap_err()
                        .to_string()
                        .contains("injected decode failure")));
                    assert_eq!(cache.decode_errors.load(Ordering::Relaxed), 1);
                } else {
                    assert!(results.iter().all(|result| result.is_ok()));
                    assert!(results
                        .windows(2)
                        .all(|pair| pair[0].as_ref().unwrap().as_raw()
                            == pair[1].as_ref().unwrap().as_raw()));
                }
            });
            assert_eq!(decode_calls.load(Ordering::Relaxed), 1);
            assert_eq!(decodes.load(Ordering::Relaxed), 1);
            if should_fail {
                assert!(cache.flights.lock().unwrap().is_empty());
            }
        }
    }

    #[test]
    fn decoder_panic_releases_slot_and_wakes_all_flight_waiters() {
        let cache = Arc::new(DecodeCache::new(1024, 4));
        let source = cache_test_source(PathBuf::from("panic-injected"));
        let source_bytes = [64];
        let hits = AtomicU64::new(0);
        let misses = AtomicU64::new(0);
        let decodes = AtomicU64::new(0);
        let decode_micros = AtomicU64::new(0);
        let barrier = Arc::new(std::sync::Barrier::new(8));
        let results = std::thread::scope(|scope| {
            let mut joins = Vec::new();
            for _ in 0..8 {
                let cache = cache.clone();
                let barrier = barrier.clone();
                let source = &source;
                let source_bytes_ref = &source_bytes;
                let hits_ref = &hits;
                let misses_ref = &misses;
                let decodes_ref = &decodes;
                let decode_micros_ref = &decode_micros;
                let cache_wait = cache.clone();
                joins.push(scope.spawn(move || {
                    barrier.wait();
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        source_image_with(
                            0,
                            source,
                            source_bytes_ref,
                            &cache,
                            hits_ref,
                            misses_ref,
                            decodes_ref,
                            decode_micros_ref,
                            true,
                            |_| -> std::result::Result<Arc<RgbaImage>, String> {
                                wait_for_decode_waiters(&cache_wait, 7);
                                panic!("injected decoder panic");
                            },
                        )
                    }))
                }));
            }
            joins
                .into_iter()
                .map(|join| join.join().unwrap())
                .collect::<Vec<_>>()
        });
        assert_eq!(results.iter().filter(|result| result.is_err()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| result.as_ref().map_or(false, |value| value.is_err()))
                .count(),
            7
        );
        assert!(results
            .iter()
            .filter_map(|result| result.as_ref().ok())
            .all(|result| {
                result
                    .as_ref()
                    .unwrap_err()
                    .to_string()
                    .contains("terminated unexpectedly")
            }));
        assert_eq!(decodes.load(Ordering::Relaxed), 1);
        assert_eq!(cache.decode_errors.load(Ordering::Relaxed), 1);
        assert_eq!(cache.active_decode_slots.load(Ordering::Relaxed), 0);
        assert_eq!(*cache.decode_slots.lock().unwrap(), 0);
        assert!(cache.flights.lock().unwrap().is_empty());
    }

    #[test]
    fn decode_gate_bounds_distinct_source_loads() {
        let cache = Arc::new(DecodeCache::new(0, 2));
        let sources = (0..6)
            .map(|index| cache_test_source(PathBuf::from(format!("{index}"))))
            .collect::<Vec<_>>();
        let source_bytes = vec![64; sources.len()];
        let hits = AtomicU64::new(0);
        let misses = AtomicU64::new(0);
        let decodes = AtomicU64::new(0);
        let decode_micros = AtomicU64::new(0);
        let active = AtomicU64::new(0);
        let peak = AtomicU64::new(0);
        let barrier = Arc::new(std::sync::Barrier::new(sources.len()));
        std::thread::scope(|scope| {
            let mut joins = Vec::new();
            for (index, source) in sources.iter().enumerate() {
                let cache = cache.clone();
                let barrier = barrier.clone();
                let source_bytes_ref = source_bytes.as_slice();
                let hits_ref = &hits;
                let misses_ref = &misses;
                let decodes_ref = &decodes;
                let decode_micros_ref = &decode_micros;
                let active_ref = &active;
                let peak_ref = &peak;
                joins.push(scope.spawn(move || {
                    barrier.wait();
                    source_image_with(
                        index,
                        source,
                        source_bytes_ref,
                        &cache,
                        hits_ref,
                        misses_ref,
                        decodes_ref,
                        decode_micros_ref,
                        false,
                        |_| {
                            let current = active_ref.fetch_add(1, Ordering::Relaxed) + 1;
                            peak_ref.fetch_max(current, Ordering::Relaxed);
                            std::thread::sleep(Duration::from_millis(30));
                            active_ref.fetch_sub(1, Ordering::Relaxed);
                            Ok(Arc::new(RgbaImage::from_pixel(4, 4, Rgba([1, 2, 3, 255]))))
                        },
                    )
                    .unwrap()
                }));
            }
            for join in joins {
                join.join().unwrap();
            }
        });
        assert_eq!(decodes.load(Ordering::Relaxed), 6);
        let decode_peak = cache.peak_decode_slots.load(Ordering::Relaxed);
        assert!((1..=2).contains(&decode_peak));
        assert!(peak.load(Ordering::Relaxed) <= 2);
    }

    #[test]
    fn spatial_schedule_visits_each_tile_once_inside_bounded_two_dimensional_blocks() {
        let tasks = (0..9)
            .flat_map(|row| (0..11).map(move |col| (row, col)))
            .collect();
        let ordered = spatial_block_order(tasks, 11, 9, 4);
        assert_eq!(ordered.len(), 99);
        let unique = ordered
            .iter()
            .copied()
            .collect::<std::collections::HashSet<_>>();
        assert_eq!(unique.len(), 99);
        for block_row in 0..3 {
            for block_col in 0..3 {
                let group = ordered
                    .iter()
                    .copied()
                    .filter(|(row, col)| row / 4 == block_row && col / 4 == block_col)
                    .collect::<Vec<_>>();
                assert_eq!(
                    group.len(),
                    (9 - block_row * 4).min(4) as usize * (11 - block_col * 4).min(4) as usize
                );
                assert!(group
                    .iter()
                    .all(|(row, col)| *row / 4 == block_row && *col / 4 == block_col));
            }
        }
    }

    #[test]
    fn sampler_uses_shader_pixel_center_and_srgb_interpolation_order() {
        let source = Source {
            path: PathBuf::new(),
            width: 2,
            height: 2,
            fx: 1.,
            fy: 1.,
            cx: 0.5,
            cy: 0.5,
            camera_to_world: [1., 0., 0., 0., 1., 0., 0., 0., 1.],
            source_plane_warp: None,
            quality_map: Arc::new(Mutex::new(None)),
            center: [0., 0., 1.],
            cone_radius: 0.,
        };
        let mut img = RgbaImage::new(2, 2);
        img.put_pixel(0, 0, Rgba([0, 0, 0, 255]));
        img.put_pixel(1, 0, Rgba([100, 100, 100, 255]));
        img.put_pixel(0, 1, Rgba([200, 200, 200, 255]));
        img.put_pixel(1, 1, Rgba([255, 255, 255, 255]));
        let (rgb, weight, ownership, _, _) = sample(&source, &img, [0., 0., 1.]).unwrap();
        let geometry = sample_geometry(&source, [0., 0., 1.]).unwrap();
        assert_eq!(
            sample_with_geometry(&source, &img, geometry),
            (rgb, weight, ownership, geometry.0, geometry.1),
            "prepared exact geometry must preserve the reference feather sample"
        );
        let expected = linear((0. + 100. + 200. + 255.) / 4. / 255.);
        assert!((rgb[0] - expected).abs() < 1e-12);
        assert_eq!(weight, 1.);
        assert_eq!(ownership, 0.25);
    }

    #[test]
    fn warp_maps_corrected_coordinates_back_to_source_with_row_major_xy_orientation() {
        let warp = SourcePlaneWarp {
            columns: 3,
            rows: 3,
            offsets: vec![
                [2., 4.],
                [4., 4.],
                [6., 4.],
                [2., 2.],
                [4., 2.],
                [6., 2.],
                [2., 0.],
                [4., 0.],
                [6., 0.],
            ],
        };
        // Center knot is (4,2) in source pixel coordinates. The renderer
        // inverts corrected = source + offset, preserving x-right/y-down.
        let corrected = crate::texture_warp::source_to_corrected(&warp, 101, 81, 50., 40.)
            .expect("forward warp");
        assert!((corrected.0 - 54.).abs() < 1e-10);
        assert!((corrected.1 - 42.).abs() < 1e-10);
        let source =
            corrected_to_source(&warp, 101, 81, corrected.0, corrected.1).expect("inverse warp");
        assert!(
            (source.0 - 50.).abs() < 0.002,
            "inverse source was {source:?}"
        );
        assert!((source.1 - 40.).abs() < 0.002);

        let constant = SourcePlaneWarp {
            columns: 3,
            rows: 3,
            offsets: vec![[3., -2.]; 9],
        };
        let sample_source = corrected_to_source(&constant, 101, 81, 40., 30.).unwrap();
        assert!((sample_source.0 - 37.).abs() < 1e-9);
        assert!((sample_source.1 - 32.).abs() < 1e-9);
        let source = Source {
            path: PathBuf::new(),
            width: 101,
            height: 81,
            fx: 10.,
            fy: 10.,
            cx: 50.,
            cy: 40.,
            camera_to_world: [1., 0., 0., 0., 1., 0., 0., 0., 1.],
            source_plane_warp: Some(SourcePlaneWarp {
                columns: 3,
                rows: 3,
                offsets: vec![[4., 2.]; 9],
            }),
            quality_map: Arc::new(Mutex::new(None)),
            center: [0., 0., 1.],
            cone_radius: 0.,
        };
        let ideal_corrected_ray = [0.4, -0.2, 1.];
        let geometry = sample_geometry(&source, ideal_corrected_ray).unwrap();
        assert!((geometry.0 - 50.).abs() < 1e-9);
        assert!((geometry.1 - 40.).abs() < 1e-9);

        let mut outward = source;
        outward.source_plane_warp = Some(SourcePlaneWarp {
            columns: 3,
            rows: 3,
            offsets: vec![[-4., 0.]; 9],
        });
        let edge_geometry = sample_geometry(&outward, [-5.4, 0., 1.]).unwrap();
        assert!(edge_geometry.0.abs() < 0.002);
    }

    #[test]
    fn zero_warp_preserves_legacy_fractional_last_pixel_sampling() {
        let mut source = Source {
            path: PathBuf::new(),
            width: 101,
            height: 81,
            fx: 10.,
            fy: 10.,
            cx: 50.,
            cy: 40.,
            camera_to_world: [1., 0., 0., 0., 1., 0., 0., 0., 1.],
            source_plane_warp: None,
            quality_map: Arc::new(Mutex::new(None)),
            center: [0., 0., 1.],
            cone_radius: 0.,
        };
        let world = [5.05, 0., 1.]; // source x = 100.5, inside legacy half-open bounds.
        let legacy = sample_geometry(&source, world).expect("legacy fractional edge sample");
        source.source_plane_warp = Some(SourcePlaneWarp::zero());
        let identity = sample_geometry(&source, world).expect("zero warp is legacy identity");
        assert_eq!(legacy, identity);
    }

    #[test]
    fn candidate_cone_includes_maximum_bounded_warp_extension() {
        let mut source = Source {
            path: PathBuf::new(),
            width: 100,
            height: 100,
            fx: 100.,
            fy: 100.,
            cx: 49.5,
            cy: 49.5,
            camera_to_world: [1., 0., 0., 0., 1., 0., 0., 0., 1.],
            source_plane_warp: None,
            quality_map: Arc::new(Mutex::new(None)),
            center: [0., 0., 1.],
            cone_radius: 0.,
        };
        let (_, plain_radius) = source_cone(&source);
        source.source_plane_warp = Some(SourcePlaneWarp {
            columns: 3,
            rows: 3,
            offsets: vec![[64., 0.]; 9],
        });
        let (center, warped_radius) = source_cone(&source);
        source.center = center;
        source.cone_radius = warped_radius;
        assert!(warped_radius > plain_radius);
        let outside_unwarped = [0.7, 0.700001, -0.000001, 0.000001];
        let mut plain = source.clone();
        plain.source_plane_warp = None;
        plain.cone_radius = plain_radius;
        assert!(!candidate(&plain, outside_unwarped, 0, 0, 1, 1, 1, 1));
        assert!(candidate(&source, outside_unwarped, 0, 0, 1, 1, 1, 1));
        let near_extension = [0.95, 0.950001, -0.000001, 0.000001];
        assert!(candidate(&source, near_extension, 0, 0, 1, 1, 1, 1));
    }

    #[test]
    fn layout_rejects_malformed_large_or_folding_source_warps() {
        let base = serde_json::json!({
            "schemaVersion":1,"projection":"spherical","width":8,"height":8,
            "yawMinRad":-0.1,"yawMaxRad":0.1,"pitchMinRad":-0.1,"pitchMaxRad":0.1,
            "tiles":[{"path":"unused.png","width":100,"height":100,
                "fx":100.0,"fy":100.0,"cx":49.5,"cy":49.5,
                "cameraToWorld":[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]}]
        });
        let mut malformed = base.clone();
        malformed["tiles"][0]["sourcePlaneWarp"] = serde_json::json!({
            "columns":3,"rows":3,"offsets":[[0.0,0.0]]
        });
        assert!(dimensions(&malformed)
            .unwrap_err()
            .to_string()
            .contains("sourcePlaneWarp"));

        let mut extra_field = base.clone();
        extra_field["tiles"][0]["sourcePlaneWarp"] = serde_json::json!({
            "columns":3,"rows":3,"offsets":[
                [0.0,0.0],[0.0,0.0],[0.0,0.0],
                [0.0,0.0],[0.0,0.0],[0.0,0.0],
                [0.0,0.0],[0.0,0.0],[0.0,0.0]
            ],"ignored":true
        });
        assert!(dimensions(&extra_field)
            .unwrap_err()
            .to_string()
            .contains("exactly columns, rows and offsets"));

        let mut too_large = base.clone();
        too_large["tiles"][0]["sourcePlaneWarp"] = serde_json::json!({
            "columns":3,"rows":3,"offsets":[
                [65.0,0.0],[65.0,0.0],[65.0,0.0],
                [65.0,0.0],[65.0,0.0],[65.0,0.0],
                [65.0,0.0],[65.0,0.0],[65.0,0.0]
            ]
        });
        assert!(dimensions(&too_large)
            .unwrap_err()
            .to_string()
            .contains("sourcePlaneWarp"));

        let mut folded = base;
        folded["tiles"][0]["sourcePlaneWarp"] = serde_json::json!({
            "columns":3,"rows":3,"offsets":[
                [0.0,0.0],[10.0,0.0],[20.0,0.0],
                [0.0,0.0],[10.0,0.0],[20.0,0.0],
                [0.0,0.0],[10.0,0.0],[20.0,0.0]
            ]
        });
        assert!(dimensions(&folded)
            .unwrap_err()
            .to_string()
            .contains("sourcePlaneWarp"));
    }

    fn deghost_composite(samples: &[([f64; 3], f64)], source_min_dimension: u32) -> [f32; 3] {
        let max_ownership = samples
            .iter()
            .map(|(_, ownership)| *ownership)
            .fold(f64::NEG_INFINITY, f64::max);
        let mut cell = [0.0; 4];
        for (rgb, ownership) in samples {
            let weight = deghost_weight(*ownership, max_ownership, source_min_dimension);
            accumulate_weighted(&mut cell, *rgb, weight);
        }
        [cell[0] / cell[3], cell[1] / cell[3], cell[2] / cell[3]]
    }

    fn permutations<T: Clone>(values: &mut [T], start: usize, output: &mut Vec<Vec<T>>) {
        if start == values.len() {
            output.push(values.to_vec());
            return;
        }
        for index in start..values.len() {
            values.swap(start, index);
            permutations(values, start + 1, output);
            values.swap(start, index);
        }
    }

    #[test]
    fn deghost_softmax_is_independent_of_three_and_four_source_order() {
        let cases = [
            vec![([0.0; 3], 0.25), ([0.5; 3], 0.25), ([1.0; 3], 0.25)],
            vec![
                ([0.0; 3], 0.25),
                ([1. / 3.; 3], 0.25),
                ([2. / 3.; 3], 0.25),
                ([1.0; 3], 0.25),
            ],
        ];
        for case in cases {
            let expected = deghost_composite(&case, 100);
            let mut all = Vec::new();
            let mut permutable = case.clone();
            permutations(&mut permutable, 0, &mut all);
            for order in all {
                let actual = deghost_composite(&order, 100);
                for channel in 0..3 {
                    assert!((actual[channel] - expected[channel]).abs() < 1e-6);
                }
            }
        }
        let equal_score =
            deghost_composite(&[([0.0; 3], 0.25), ([0.5; 3], 0.25), ([1.0; 3], 0.25)], 100);
        assert!((equal_score[0] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn deghost_ownership_is_a_narrow_soft_transition() {
        let samples = [([0.0; 3], 0.20), ([0.5; 3], 0.24), ([1.0; 3], 0.28)];
        let composite = deghost_composite(&samples, 100);
        assert!(composite[0] > 0.75 && composite[0] < 0.85);
        let tied = deghost_composite(&[([0.0; 3], 0.25), ([0.5; 3], 0.25), ([1.0; 3], 0.25)], 100);
        assert!(composite[0] > tied[0]);
        assert!(composite[0] < 1.0);
    }

    fn patterned_source(width: u32, height: u32) -> RgbaImage {
        let mut image = RgbaImage::new(width, height);
        for y in 0..height {
            for x in 0..width {
                let value = 112 + ((x * 37 + y * 19 + x * y * 3) % 48) as u8;
                image.put_pixel(x, y, Rgba([value, value, value, 255]));
            }
        }
        image
    }

    fn synthetic_scene_value(yaw: f64, pitch: f64) -> u8 {
        let x = ((yaw + std::f64::consts::PI) / 0.003).floor() as i64;
        let y = ((std::f64::consts::FRAC_PI_2 - pitch) / 0.003).floor() as i64;
        let mut hash = (x as u64).wrapping_mul(0x9e3779b97f4a7c15)
            ^ (y as u64).wrapping_mul(0xbf58476d1ce4e5b9);
        hash ^= hash >> 30;
        hash = hash.wrapping_mul(0xbf58476d1ce4e5b9);
        hash ^= hash >> 27;
        hash = hash.wrapping_mul(0x94d049bb133111eb);
        hash ^= hash >> 31;
        (40 + hash % 200) as u8
    }

    fn synthetic_scene_source(path: &Path, yaw_offset: f64) {
        const WIDTH: u32 = 2048;
        const HEIGHT: u32 = 1152;
        const FX: f64 = 1216.0;
        const FY: f64 = 900.0;
        const CX: f64 = (WIDTH as f64 - 1.0) * 0.5;
        const CY: f64 = (HEIGHT as f64 - 1.0) * 0.5;
        let (sin_yaw, cos_yaw) = yaw_offset.sin_cos();
        let mut image = RgbaImage::new(WIDTH, HEIGHT);
        for y in 0..HEIGHT {
            for x in 0..WIDTH {
                let camera_x = (f64::from(x) - CX) / FX;
                let camera_y = -(f64::from(y) - CY) / FY;
                let world_x = cos_yaw * camera_x + sin_yaw;
                let world_y = camera_y;
                let world_z = -sin_yaw * camera_x + cos_yaw;
                let yaw = world_x.atan2(world_z);
                let pitch = world_y.atan2((world_x * world_x + world_z * world_z).sqrt());
                let value = synthetic_scene_value(yaw, pitch);
                image.put_pixel(x, y, Rgba([value, value, value, 255]));
            }
        }
        image.save(path).unwrap();
    }

    fn collect_level_zero(output: &Path, width: u32, height: u32) -> RgbaImage {
        let mut image = RgbaImage::new(width, height);
        for row in 0..height.div_ceil(TILE) {
            for col in 0..width.div_ceil(TILE) {
                let tile = image::open(output.join("level-0").join(format!("{row}-{col}.png")))
                    .unwrap()
                    .into_rgba8();
                for y in 0..tile.height() {
                    for x in 0..tile.width() {
                        image.put_pixel(col * TILE + x, row * TILE + y, *tile.get_pixel(x, y));
                    }
                }
            }
        }
        image
    }

    fn save_scene_mask(path: &Path, width: u32, height: u32, rect: [u32; 4]) {
        let mut bytes = vec![0u8; width as usize * height as usize * 2];
        for y in rect[1]..rect[3] {
            for x in rect[0]..rect[2] {
                let index = (y as usize * width as usize + x as usize) * 2;
                bytes[index] = 255;
                bytes[index + 1] = 255;
            }
        }
        let file = fs::File::create(path).unwrap();
        let mut encoder = png::Encoder::new(file, width, height);
        encoder.set_color(png::ColorType::GrayscaleAlpha);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(&bytes).unwrap();
    }

    fn two_source_scene_layout(root: &Path) -> serde_json::Value {
        let source_dir = root.join("sources");
        let mask_dir = root.join("masks");
        fs::create_dir_all(&source_dir).unwrap();
        fs::create_dir_all(&mask_dir).unwrap();
        let a_path = source_dir.join("a.png");
        let b_path = source_dir.join("b.png");
        RgbaImage::from_pixel(1024, 512, Rgba([200, 30, 20, 255]))
            .save(&a_path)
            .unwrap();
        RgbaImage::from_pixel(1024, 512, Rgba([20, 30, 200, 255]))
            .save(&b_path)
            .unwrap();
        let a_mask = mask_dir.join("a-mask.png");
        let b_mask = mask_dir.join("b-mask.png");
        save_scene_mask(&a_mask, 1024, 512, [490, 245, 521, 267]);
        save_scene_mask(&b_mask, 1024, 512, [510, 245, 541, 267]);
        let source = |path: &Path| {
            serde_json::json!({
                "path":path.to_string_lossy(),
                "width":1024,"height":512,
                "fx":800.0,"fy":800.0,"cx":511.5,"cy":255.5,
                "cameraToWorld":[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]
            })
        };
        let descriptor = |path: &Path, mask: &Path| {
            // Job manifests store canonical paths; the layout tile retains its
            // original absolute spelling. This intentionally exercises the
            // Windows `\\?\` versus ordinary-path renderer handoff.
            let canonical_path = path.canonicalize().unwrap();
            serde_json::json!({
                "path":canonical_path.to_string_lossy(),"width":1024,"height":512,
                "maskPath":mask.to_string_lossy(),
                "maskSha256":crate::fingerprint::sha256_file(mask).unwrap()
            })
        };
        serde_json::json!({
            "schemaVersion":1,"projection":"spherical","width":1024,"height":512,
            "yawMinRad":-0.5,"yawMaxRad":0.5,
            "pitchMinRad":-0.25,"pitchMaxRad":0.25,
            "renderBlendMode":"feather","protectPeople":true,"smoothWater":true,
            "tiles":[source(&a_path),source(&b_path)],
            "semanticAnalysis":{
                "schemaVersion":1,"algorithmVersion":1,"modelId":"test-scene-v1",
                "modelSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "sources":[descriptor(&a_path,&a_mask),descriptor(&b_path,&b_mask)]
            }
        })
    }

    fn render_scene_variant(
        layout: &serde_json::Value,
        output: &Path,
        blend_mode: &str,
        protect_people: bool,
        smooth_water: bool,
        workers: usize,
    ) -> serde_json::Value {
        let mut variant = layout.clone();
        variant["renderBlendMode"] = serde_json::json!(blend_mode);
        variant["protectPeople"] = serde_json::json!(protect_people);
        variant["smoothWater"] = serde_json::json!(smooth_water);
        render_layout_tiles_with_options(&variant, output, 128, workers, true, |_, _| true).unwrap()
    }

    #[test]
    fn semantic_person_owner_is_stable_across_tile_edge_and_resume_identity() {
        let root = std::env::temp_dir().join(format!(
            "lumia-scene-person-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let layout = two_source_scene_layout(&root);
        #[cfg(windows)]
        {
            let layout_path = layout["tiles"][0]["path"].as_str().unwrap();
            let manifest_path = layout["semanticAnalysis"]["sources"][0]["path"]
                .as_str()
                .unwrap();
            assert!(!layout_path.starts_with(r"\\?\"));
            assert!(manifest_path.starts_with(r"\\?\"));
        }
        let output = root.join("render-a");
        let stats =
            render_layout_tiles_with_options(&layout, &output, 128, 1, true, |_, _| true).unwrap();
        assert_eq!(stats["sceneRendering"]["personObjects"].as_u64(), Some(1));
        let image = collect_level_zero(&output, 1024, 512);
        // Both sources tie on completeness, projection coverage, confidence,
        // and flat-image sharpness, so stable path ranking selects b.png.
        assert_eq!(*image.get_pixel(510, 256), Rgba([20, 30, 200, 255]));
        // x=490 belongs only to source A's person mask and x=540 only to B's.
        // Both lie in the grouped silhouette union, so the selected B view's
        // background must be copied across the whole union.
        assert_eq!(*image.get_pixel(490, 256), Rgba([20, 30, 200, 255]));
        assert_eq!(*image.get_pixel(540, 256), Rgba([20, 30, 200, 255]));
        let old_tile = fs::read(output.join("level-0/0-1.png")).unwrap();

        let mut changed_flags = layout.clone();
        changed_flags["smoothWater"] = serde_json::json!(false);
        assert!(
            render_layout_tiles_with_options(&changed_flags, &output, 128, 1, true, |_, _| true,)
                .is_err()
        );
        assert_eq!(fs::read(output.join("level-0/0-1.png")).unwrap(), old_tile);

        let mut changed_model = layout.clone();
        changed_model["semanticAnalysis"]["modelSha256"] =
            serde_json::json!("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        assert!(
            render_layout_tiles_with_options(&changed_model, &output, 128, 1, true, |_, _| true,)
                .is_err()
        );
        assert_eq!(fs::read(output.join("level-0/0-1.png")).unwrap(), old_tile);

        let changed_mask = root.join("masks/b-mask-changed.png");
        save_scene_mask(&changed_mask, 1024, 512, [508, 245, 541, 267]);
        let mut changed_mask_layout = layout.clone();
        changed_mask_layout["semanticAnalysis"]["sources"][1]["maskPath"] =
            serde_json::json!(changed_mask.to_string_lossy());
        changed_mask_layout["semanticAnalysis"]["sources"][1]["maskSha256"] =
            serde_json::json!(crate::fingerprint::sha256_file(&changed_mask).unwrap());
        assert!(render_layout_tiles_with_options(
            &changed_mask_layout,
            &output,
            128,
            1,
            true,
            |_, _| true,
        )
        .is_err());
        assert_eq!(fs::read(output.join("level-0/0-1.png")).unwrap(), old_tile);

        // Disabled scene controls keep the legacy renderer identity and tile
        // bytes exactly, for both independently selectable base blend modes.
        for blend_mode in ["feather", "deghost"] {
            let mut legacy = layout.clone();
            legacy.as_object_mut().unwrap().remove("protectPeople");
            legacy.as_object_mut().unwrap().remove("smoothWater");
            legacy.as_object_mut().unwrap().remove("semanticAnalysis");
            legacy["renderBlendMode"] = serde_json::json!(blend_mode);
            let legacy_output = root.join(format!("legacy-{blend_mode}"));
            render_layout_tiles_with_options(&legacy, &legacy_output, 128, 1, true, |_, _| true)
                .unwrap();
            let off_output = root.join(format!("off-{blend_mode}"));
            render_scene_variant(&legacy, &off_output, blend_mode, false, false, 2);
            for col in 0..2 {
                let name = format!("level-0/0-{col}.png");
                assert_eq!(
                    fs::read(legacy_output.join(&name)).unwrap(),
                    fs::read(off_output.join(name)).unwrap()
                );
            }

            for (protect, water) in [(true, false), (false, true), (true, true)] {
                let name = format!("{}-{}-{blend_mode}", protect as u8, water as u8);
                let output_variant = root.join(name);
                let variant_stats =
                    render_scene_variant(&layout, &output_variant, blend_mode, protect, water, 2);
                assert_eq!(
                    variant_stats["sceneRendering"]["protectPeople"].as_bool(),
                    Some(protect)
                );
                assert_eq!(
                    variant_stats["sceneRendering"]["smoothWater"].as_bool(),
                    Some(water)
                );
                if protect && !water {
                    assert!(
                        variant_stats["sceneRendering"]["personPixels"]
                            .as_u64()
                            .unwrap()
                            > 0
                    );
                    assert_eq!(
                        variant_stats["sceneRendering"]["waterOverlapPixels"].as_u64(),
                        Some(0)
                    );
                } else if water && !protect {
                    assert_eq!(
                        variant_stats["sceneRendering"]["personPixels"].as_u64(),
                        Some(0)
                    );
                    assert!(
                        variant_stats["sceneRendering"]["waterOverlapPixels"]
                            .as_u64()
                            .unwrap()
                            > 0
                    );
                }
            }
        }

        let reversed = {
            let mut value = layout.clone();
            value["tiles"].as_array_mut().unwrap().reverse();
            value
        };
        let reverse_output = root.join("render-reversed");
        render_layout_tiles_with_options(&reversed, &reverse_output, 128, 2, true, |_, _| true)
            .unwrap();
        assert_eq!(
            fs::read(output.join("level-0/0-1.png")).unwrap(),
            fs::read(reverse_output.join("level-0/0-1.png")).unwrap()
        );

        let mut warped = layout.clone();
        warped["tiles"][1]["sourcePlaneWarp"] = serde_json::json!({
            "columns":3,"rows":3,"offsets":[
                [6.0,0.0],[6.0,0.0],[6.0,0.0],
                [6.0,0.0],[6.0,0.0],[6.0,0.0],
                [6.0,0.0],[6.0,0.0],[6.0,0.0]
            ]
        });
        let warped_output = root.join("render-warped");
        render_layout_tiles_with_options(&warped, &warped_output, 128, 1, true, |_, _| true)
            .unwrap();
        let warped_image = collect_level_zero(&warped_output, 1024, 512);
        // The source-to-output projection maps B's right edge to about x=550;
        // its +6 source-plane correction moves that edge about 8 px farther.
        // x=554 is outside the unwarped 3 px owner buffer but inside the
        // corrected union buffer.
        let outside_unwarped_union = *image.get_pixel(554, 256);
        assert_ne!(outside_unwarped_union, Rgba([20, 30, 200, 255]));
        assert!(outside_unwarped_union[0] > 0 && outside_unwarped_union[2] > 0);
        assert_eq!(*warped_image.get_pixel(554, 256), Rgba([20, 30, 200, 255]));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn global_ownership_reduces_moving_patch_ghosts_without_softening_static_detail() {
        const SIZE: u32 = 128;
        let root = std::env::temp_dir().join(format!(
            "lumia-seam-patch-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let source_a = root.join("a.png");
        let source_b = root.join("b.png");
        let mut image_a = patterned_source(SIZE, SIZE);
        let mut image_b = image_a.clone();
        for y in 52..76 {
            for x in 20..40 {
                image_a.put_pixel(x, y, Rgba([242, 28, 24, 255]));
            }
            for x in 82..102 {
                image_b.put_pixel(x, y, Rgba([18, 38, 244, 255]));
            }
        }
        image_a.save(&source_a).unwrap();
        image_b.save(&source_b).unwrap();
        let layout = serde_json::json!({
            "schemaVersion":1,"projection":"spherical","width":SIZE,"height":SIZE,
            "yawMinRad":-0.7,"yawMaxRad":0.7,"pitchMinRad":-0.7,"pitchMaxRad":0.7,
            "renderBlendMode":"deghost",
            "tiles":[
                {"path":source_b,"width":SIZE,"height":SIZE,"fx":72.0,"fy":72.0,
                 "cx":63.5,"cy":63.5,"cameraToWorld":[1,0,0,0,1,0,0,0,1]},
                {"path":source_a,"width":SIZE,"height":SIZE,"fx":72.0,"fy":72.0,
                 "cx":63.5,"cy":63.5,"cameraToWorld":[1,0,0,0,1,0,0,0,1]}
            ]
        });
        let legacy_dir = root.join("legacy");
        let masked_dir = root.join("masked");
        let expected_dir = root.join("expected-source-a");
        let alternative_dir = root.join("expected-source-b");
        let checkpoint = |_, _| true;
        render_layout_tiles_with_options_internal_and_ownership(
            &layout,
            &legacy_dir,
            32,
            1,
            false,
            checkpoint,
            true,
            false,
        )
        .unwrap();
        let mut alternative_layout = layout.clone();
        alternative_layout["tiles"] = serde_json::json!([layout["tiles"][0].clone()]);
        render_layout_tiles_with_options_internal(
            &alternative_layout,
            &alternative_dir,
            32,
            1,
            false,
            checkpoint,
            false,
        )
        .unwrap();
        render_layout_tiles_with_options_internal(
            &layout,
            &masked_dir,
            32,
            1,
            false,
            checkpoint,
            true,
        )
        .unwrap();
        let mut expected_layout = layout.clone();
        expected_layout["tiles"] = serde_json::json!([layout["tiles"][1].clone()]);
        render_layout_tiles_with_options_internal(
            &expected_layout,
            &expected_dir,
            32,
            1,
            false,
            checkpoint,
            false,
        )
        .unwrap();
        let legacy = collect_level_zero(&legacy_dir, SIZE, SIZE);
        let masked = collect_level_zero(&masked_dir, SIZE, SIZE);
        let expected = collect_level_zero(&expected_dir, SIZE, SIZE);
        let alternative = collect_level_zero(&alternative_dir, SIZE, SIZE);
        let mut legacy_patch_error = 0u64;
        let mut masked_patch_error = 0u64;
        for y in 0..SIZE {
            for x in 0..SIZE {
                let expected_a = expected.get_pixel(x, y).0;
                let expected_b = alternative.get_pixel(x, y).0;
                let error_to_either_source = |pixel: &[u8; 4]| {
                    let to_a = pixel
                        .iter()
                        .zip(expected_a.iter())
                        .map(|(a, b)| u64::from(a.abs_diff(*b)))
                        .sum::<u64>();
                    let to_b = pixel
                        .iter()
                        .zip(expected_b.iter())
                        .map(|(a, b)| u64::from(a.abs_diff(*b)))
                        .sum::<u64>();
                    to_a.min(to_b)
                };
                legacy_patch_error += error_to_either_source(&legacy.get_pixel(x, y).0);
                masked_patch_error += error_to_either_source(&masked.get_pixel(x, y).0);
            }
        }
        assert!(
            masked_patch_error * 5 < legacy_patch_error * 4,
            "coherent ownership should suppress the shifted patch ghost: legacy={legacy_patch_error}, masked={masked_patch_error}"
        );
        let mut static_error = 0u64;
        for y in 0..SIZE {
            for x in 0..SIZE {
                let in_moving_patch =
                    (49..81).contains(&y) && ((14..37).contains(&x) || (86..111).contains(&x));
                if in_moving_patch {
                    continue;
                }
                static_error += masked
                    .get_pixel(x, y)
                    .0
                    .iter()
                    .zip(expected.get_pixel(x, y).0.iter())
                    .map(|(a, b)| u64::from(a.abs_diff(*b)))
                    .sum::<u64>();
            }
        }
        let static_samples = u64::from(SIZE * SIZE - (23 * 32) - (25 * 32)) * 3;
        assert!(
            static_error as f64 / (static_samples as f64) < 0.05,
            "static source detail changed by {static_error} total error over {static_samples} channel samples"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn source_quality_map_flags_only_broad_dark_smooth_border_occlusion() {
        // Preserve the original moderate-contrast fixture as a conservative
        // false-positive guard: its sampled ring contrast is ~22.8, just
        // below the production 24-luma evidence floor, so it must keep legacy
        // ownership even when another source is structured.
        let mut moderate_contrast = patterned_source(640, 360);
        for y in 0..360 {
            for x in 500..640 {
                moderate_contrast.put_pixel(x, y, Rgba([24, 22, 20, 255]));
            }
        }
        let moderate_map = SourceQualityMap::from_image(&moderate_contrast);
        let (moderate_texture, moderate_confidence) = moderate_map.sample(640, 360, 580., 180.);
        assert!(moderate_texture <= SOURCE_QUALITY_LOW_TEXTURE_MAX);
        assert!(moderate_confidence < SOURCE_QUALITY_SUSPECT_CONFIDENCE);
        let weak_strength =
            quality_suppression_strength(10., moderate_confidence, moderate_texture, 0., 0.);
        assert!(weak_strength < 0.01);

        // Keep a textured, bright scene outside the flat border so the
        // detector sees strong peer/boundary evidence even after 64x36
        // coarse sampling.
        let mut occluded = RgbaImage::new(640, 360);
        for y in 0..360 {
            for x in 0..640 {
                let value = 220 + ((x * 37 + y * 19 + x * y * 3) % 32) as u8;
                occluded.put_pixel(x, y, Rgba([value, value, value, 255]));
            }
        }
        for y in 0..360 {
            for x in 500..640 {
                occluded.put_pixel(x, y, Rgba([24, 22, 20, 255]));
            }
        }
        let occlusion_map = SourceQualityMap::from_image(&occluded);
        let (occlusion_texture, occlusion_confidence) = occlusion_map.sample(640, 360, 580., 180.);
        assert!(occlusion_texture <= SOURCE_QUALITY_LOW_TEXTURE_MAX);
        assert!(occlusion_confidence >= SOURCE_QUALITY_SUSPECT_CONFIDENCE);
        let (scene_texture, scene_confidence) = occlusion_map.sample(640, 360, 420., 180.);
        assert!(scene_texture >= SOURCE_QUALITY_STRUCTURED_PEER_TEXTURE);
        assert!(scene_confidence < SOURCE_QUALITY_SUSPECT_CONFIDENCE);

        let mut dark_windows = patterned_source(640, 360);
        for (left, top) in [(170, 90), (270, 90), (370, 90)] {
            for y in top..top + 80 {
                for x in left..left + 70 {
                    dark_windows.put_pixel(x, y, Rgba([18, 18, 18, 255]));
                }
            }
        }
        let windows_map = SourceQualityMap::from_image(&dark_windows);
        let (_, window_confidence) = windows_map.sample(640, 360, 200., 130.);
        assert!(window_confidence < SOURCE_QUALITY_SUSPECT_CONFIDENCE);

        let mut narrow_trunk = patterned_source(640, 360);
        for y in 0..360 {
            for x in 0..20 {
                narrow_trunk.put_pixel(x, y, Rgba([16, 16, 16, 255]));
            }
        }
        let trunk_map = SourceQualityMap::from_image(&narrow_trunk);
        let (_, trunk_confidence) = trunk_map.sample(640, 360, 10., 180.);
        assert!(trunk_confidence < SOURCE_QUALITY_SUSPECT_CONFIDENCE);

        let mut dark_foliage = RgbaImage::new(640, 360);
        for y in 0..360 {
            for x in 0..640 {
                let leaf = ((x * 13 + y * 17 + x * y) % 36) as u8;
                dark_foliage.put_pixel(x, y, Rgba([12 + leaf, 20 + leaf, 8 + leaf, 255]));
            }
        }
        let foliage_map = SourceQualityMap::from_image(&dark_foliage);
        let (_, foliage_confidence) = foliage_map.sample(640, 360, 2., 180.);
        assert!(foliage_confidence < SOURCE_QUALITY_SUSPECT_CONFIDENCE);

        let flat_dark = RgbaImage::from_pixel(640, 360, Rgba([12, 12, 12, 255]));
        let flat_map = SourceQualityMap::from_image(&flat_dark);
        let (_, flat_confidence) = flat_map.sample(640, 360, 320., 180.);
        assert!(flat_confidence < SOURCE_QUALITY_SUSPECT_CONFIDENCE);
    }

    #[test]
    fn normalized_local_sharpness_detects_blur_and_resists_exposure_shift() {
        const WIDTH: u32 = 2048;
        const HEIGHT: u32 = 1152;
        let mut crisp = RgbaImage::new(WIDTH, HEIGHT);
        for y in 0..HEIGHT {
            for x in 0..WIDTH {
                let broad = if (x / 64 + y / 64) % 2 == 0 {
                    105i16
                } else {
                    155i16
                };
                let detail = if (x / 4 + y / 4) % 2 == 0 {
                    -30i16
                } else {
                    30i16
                };
                let value = (broad + detail) as u8;
                crisp.put_pixel(x, y, Rgba([value, value, value, 255]));
            }
        }
        let mildly_blurred = image::imageops::blur(&crisp, 1.0);
        let blurred = image::imageops::blur(&crisp, 1.5);
        let exposure_shifted = RgbaImage::from_fn(WIDTH, HEIGHT, |x, y| {
            let pixel = crisp.get_pixel(x, y).0[0];
            let shifted = (f64::from(pixel) * 0.72 + 35.0).round() as u8;
            Rgba([shifted, shifted, shifted, 255])
        });
        let crisp_map = SourceQualityMap::from_image(&crisp);
        let mild_map = SourceQualityMap::from_image(&mildly_blurred);
        let blurred_map = SourceQualityMap::from_image(&blurred);
        let shifted_map = SourceQualityMap::from_image(&exposure_shifted);
        let (crisp_texture, _) = crisp_map.sample(WIDTH, HEIGHT, 1024.0, 576.0);
        let (mild_texture, _) = mild_map.sample(WIDTH, HEIGHT, 1024.0, 576.0);
        let (blurred_texture, _) = blurred_map.sample(WIDTH, HEIGHT, 1024.0, 576.0);
        let crisp_sharpness = crisp_map.sharpness(WIDTH, HEIGHT, 1024.0, 576.0);
        let mild_sharpness = mild_map.sharpness(WIDTH, HEIGHT, 1024.0, 576.0);
        let blurred_sharpness = blurred_map.sharpness(WIDTH, HEIGHT, 1024.0, 576.0);
        let shifted_sharpness = shifted_map.sharpness(WIDTH, HEIGHT, 1024.0, 576.0);
        assert!(crisp_texture >= SOURCE_QUALITY_BLUR_PEER_TEXTURE);
        assert!(mild_texture >= SOURCE_QUALITY_BLUR_PEER_TEXTURE);
        assert!(blurred_texture >= SOURCE_QUALITY_BLUR_PEER_TEXTURE);
        assert!(crisp_sharpness >= SOURCE_QUALITY_BLUR_PEER_SHARPNESS);
        assert!(
            crisp_sharpness > mild_sharpness && mild_sharpness > blurred_sharpness,
            "sharpness should decrease monotonically with blur: crisp={crisp_sharpness}, sigma1={mild_sharpness}, sigma1.5={blurred_sharpness}"
        );
        assert!(
            blurred_sharpness < crisp_sharpness * SOURCE_QUALITY_BLUR_RELATIVE_MAX,
            "mild blur did not reduce normalized local sharpness enough: crisp={crisp_sharpness}, blurred={blurred_sharpness}"
        );
        assert!(
            (shifted_sharpness / crisp_sharpness).clamp(0.0, 1.0) > 0.75,
            "exposure shift changed normalized sharpness too much: crisp={crisp_sharpness}, shifted={shifted_sharpness}"
        );

        // A single-scale checker can lose broad contrast at the same time as
        // fine detail. Keep it as a conservative limitation check: sharpness
        // must still move monotonically, while the peer rule may decline to
        // suppress when the relative evidence does not clear its threshold.
        let mut single_scale = RgbaImage::new(WIDTH, HEIGHT);
        for y in 0..HEIGHT {
            for x in 0..WIDTH {
                let value = if (x / 4 + y / 4) % 2 == 0 { 35 } else { 220 };
                single_scale.put_pixel(x, y, Rgba([value, value, value, 255]));
            }
        }
        let single_blur = image::imageops::blur(&single_scale, 1.0);
        let single_crisp_map = SourceQualityMap::from_image(&single_scale);
        let single_blur_map = SourceQualityMap::from_image(&single_blur);
        let single_crisp_texture = single_crisp_map.sample(WIDTH, HEIGHT, 1024.0, 576.0).0;
        let single_blur_texture = single_blur_map.sample(WIDTH, HEIGHT, 1024.0, 576.0).0;
        let single_crisp_sharpness = single_crisp_map.sharpness(WIDTH, HEIGHT, 1024.0, 576.0);
        let single_blur_sharpness = single_blur_map.sharpness(WIDTH, HEIGHT, 1024.0, 576.0);
        assert!(
            single_blur_sharpness < single_crisp_sharpness,
            "single-scale blur should lower sharpness even when it may not meet suppression cutoff: crisp={single_crisp_sharpness}, blurred={single_blur_sharpness}"
        );
        let single_blur_strength = quality_suppression_strength(
            single_crisp_texture,
            0.0,
            single_blur_texture,
            single_blur_sharpness,
            single_crisp_sharpness,
        );
        assert!(single_blur_strength > 0.0);

        let flat = RgbaImage::from_pixel(WIDTH, HEIGHT, Rgba([128, 128, 128, 255]));
        let flat_map = SourceQualityMap::from_image(&flat);
        let (flat_texture, _) = flat_map.sample(WIDTH, HEIGHT, 1024.0, 576.0);
        let flat_sharpness = flat_map.sharpness(WIDTH, HEIGHT, 1024.0, 576.0);
        assert!(flat_texture < SOURCE_QUALITY_BLUR_PEER_TEXTURE);
        let flat_adjusted = adjusted_ownership(
            0.3,
            f64::NEG_INFINITY,
            flat_texture,
            0.95,
            flat_texture,
            flat_sharpness,
            crisp_sharpness,
            2160,
        );
        assert_eq!(flat_adjusted, 0.3);

        let blurred_adjusted = adjusted_ownership(
            0.35,
            0.25,
            crisp_texture,
            0.0,
            blurred_texture,
            blurred_sharpness,
            crisp_sharpness,
            2160,
        );
        let crisp_adjusted = adjusted_ownership(
            0.25,
            0.35,
            crisp_texture,
            0.0,
            crisp_texture,
            crisp_sharpness,
            crisp_sharpness,
            2160,
        );
        assert!(blurred_adjusted < 0.35);
        assert_eq!(crisp_adjusted, 0.25);
    }

    #[test]
    fn blur_suppression_changes_continuously_across_former_cutoff() {
        let peer_ownership = 0.30;
        let source_ownership = 0.30;
        let peer_texture = 80.0;
        let peer_sharpness = 100.0;
        let weights: Vec<f64> = (0..=10)
            .map(|step| {
                let ratio = 0.69 + step as f64 * 0.002;
                let adjusted = adjusted_ownership(
                    source_ownership,
                    peer_ownership,
                    peer_texture,
                    0.0,
                    40.0,
                    ratio * peer_sharpness,
                    peer_sharpness,
                    2160,
                );
                let peer_adjusted = adjusted_ownership(
                    peer_ownership,
                    source_ownership,
                    peer_texture,
                    0.0,
                    40.0,
                    peer_sharpness,
                    peer_sharpness,
                    2160,
                );
                deghost_weight(adjusted, adjusted.max(peer_adjusted), 2160)
            })
            .collect();
        let largest_step = weights
            .windows(2)
            .map(|pair| (pair[1] - pair[0]).abs())
            .fold(0.0, f64::max);
        assert!(
            largest_step < 0.05,
            "softmax weight jumped near former 0.70 cutoff: {largest_step}, weights={weights:?}"
        );

        let peer_ownership = 0.30;
        let obstruction_weights: Vec<f64> = (0..=150)
            .map(|step| {
                let confidence = 0.50 + step as f64 * 0.002;
                let adjusted = adjusted_ownership(
                    peer_ownership,
                    peer_ownership,
                    40.0,
                    confidence,
                    0.0,
                    0.0,
                    0.0,
                    2160,
                );
                deghost_weight(adjusted, adjusted.max(peer_ownership), 2160)
            })
            .collect();
        let largest_obstruction_step = obstruction_weights
            .windows(2)
            .map(|pair| (pair[1] - pair[0]).abs())
            .fold(0.0, f64::max);
        assert!(
            largest_obstruction_step < 0.05,
            "softmax weight jumped near former obstruction cutoff: {largest_obstruction_step}, weights={obstruction_weights:?}"
        );
        assert!(obstruction_weights[0] > 0.99);
        assert!(obstruction_weights[150] < 0.001);
    }

    #[test]
    fn quality_peer_edge_support_fades_without_losing_interior_suppression() {
        let peer_texture = 80.0;
        let peer_sharpness = 100.0;
        let blur_weights: Vec<f64> = (0..=100_000)
            .map(|step| {
                let edge_support = step as f64 / 100_000.0;
                let adjusted = adjusted_ownership(
                    0.30,
                    0.30,
                    peer_texture * edge_support,
                    0.0,
                    40.0,
                    30.0,
                    peer_sharpness * edge_support,
                    2160,
                );
                deghost_weight(adjusted, 0.30, 2160)
            })
            .collect();
        assert!(blur_weights[0] > 0.99);
        assert!(blur_weights[100_000] < 0.01);
        assert!(blur_weights.windows(2).all(|pair| pair[0] >= pair[1]));
        let largest_blur_step = blur_weights
            .windows(2)
            .map(|pair| pair[0] - pair[1])
            .fold(0.0, f64::max);
        assert!(
            largest_blur_step < 0.001,
            "blur support jump={largest_blur_step}"
        );

        let obstruction_weights: Vec<f64> = (0..=100_000)
            .map(|step| {
                let edge_support = step as f64 / 100_000.0;
                let adjusted = adjusted_ownership(
                    0.30,
                    0.30,
                    peer_texture * edge_support,
                    0.95,
                    0.0,
                    0.0,
                    0.0,
                    2160,
                );
                deghost_weight(adjusted, 0.30, 2160)
            })
            .collect();
        assert!(obstruction_weights[0] > 0.99);
        assert!(obstruction_weights[100_000] < 0.01);
        assert!(obstruction_weights
            .windows(2)
            .all(|pair| pair[0] >= pair[1]));
        let largest_obstruction_step = obstruction_weights
            .windows(2)
            .map(|pair| pair[0] - pair[1])
            .fold(0.0, f64::max);
        assert!(
            largest_obstruction_step < 0.001,
            "obstruction support jump={largest_obstruction_step}"
        );
    }

    #[test]
    fn top_two_ownership_ties_use_stable_source_rank() {
        fn select(order: &[usize], stable_ranks: &[usize]) -> (usize, usize) {
            let mut best_score = f64::NEG_INFINITY;
            let mut best_source = usize::MAX;
            let mut second_score = f64::NEG_INFINITY;
            let mut second_source = usize::MAX;
            for &source_index in order {
                insert_top_two_ownership(
                    0.25,
                    source_index,
                    stable_ranks,
                    &mut best_score,
                    &mut best_source,
                    &mut second_score,
                    &mut second_source,
                );
            }
            (best_source, second_source)
        }

        let stable_ranks = [2, 0, 1];
        assert_eq!(select(&[0, 1, 2], &stable_ranks), (1, 2));
        assert_eq!(select(&[2, 1, 0], &stable_ranks), (1, 2));
        assert_eq!(select(&[1, 0, 2], &stable_ranks), (1, 2));
    }

    #[test]
    fn best_other_quality_uses_second_owner_and_tapers_source_edge() {
        let make_source = |name: &str| Source {
            path: PathBuf::from(name),
            width: 640,
            height: 360,
            fx: 1.0,
            fy: 1.0,
            cx: 319.5,
            cy: 179.5,
            camera_to_world: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
            source_plane_warp: None,
            quality_map: Arc::new(Mutex::new(None)),
            center: [0.0, 0.0, 1.0],
            cone_radius: 1.0,
        };
        let sources = vec![
            make_source("third-crisp.jpg"),
            make_source("owner.jpg"),
            make_source("edge-peer.jpg"),
        ];
        let crisp_image = patterned_source(640, 360);
        let blurred_image = image::imageops::blur(&crisp_image, 1.5);
        let crisp_quality = Arc::new(SourceQualityMap::from_image(&crisp_image));
        let blurred_quality = Arc::new(SourceQualityMap::from_image(&blurred_image));
        let quality_maps = vec![
            Some(crisp_quality.clone()),
            Some(blurred_quality.clone()),
            Some(blurred_quality),
        ];
        let mut peer_edge = TileGeometryCache::new(1);
        peer_edge.store(0, 320.0, 4.0);
        let mut tile_geometry = vec![(2, peer_edge)];
        let best_sources = [1usize];
        let second_sources = [2usize];
        let best_scores = [0.30];
        let second_scores = [0.29];
        let edge_result = best_other_source_quality(
            1,
            0,
            [0.0, 0.0, 1.0],
            &sources,
            &quality_maps,
            &tile_geometry,
            &best_sources,
            &second_sources,
            &best_scores,
            &second_scores,
        );
        tile_geometry[0].1.store(0, 320.0, 180.0);
        let interior_result = best_other_source_quality(
            1,
            0,
            [0.0, 0.0, 1.0],
            &sources,
            &quality_maps,
            &tile_geometry,
            &best_sources,
            &second_sources,
            &best_scores,
            &second_scores,
        );
        assert_eq!(edge_result.0, 0.29);
        assert_eq!(interior_result.0, 0.29);
        assert!(edge_result.1 > 0.0 && edge_result.1 < interior_result.1);
        assert!(edge_result.2 > 0.0 && edge_result.2 < interior_result.2);

        let no_peer = best_other_source_quality(
            1,
            0,
            [0.0, 0.0, 1.0],
            &sources,
            &quality_maps,
            &tile_geometry,
            &[1],
            &[usize::MAX],
            &[0.30],
            &[f64::NEG_INFINITY],
        );
        assert_eq!(no_peer, (f64::NEG_INFINITY, 0.0, 0.0));

        // The sharp third source is not the geometric runner-up and cannot
        // donate quality evidence to suppress the current owner.
        let third_peer_excluded = best_other_source_quality(
            1,
            0,
            [0.0, 0.0, 1.0],
            &sources,
            &quality_maps,
            &tile_geometry,
            &[1],
            &[2],
            &[0.30],
            &[0.29],
        );
        assert!(crisp_quality.sharpness(640, 360, 320.0, 180.0) > interior_result.2);
        assert_eq!(third_peer_excluded.1, interior_result.1);
        assert_eq!(third_peer_excluded.2, interior_result.2);
    }

    #[test]
    fn quality_adjusted_softmax_is_order_invariant_and_keeps_flat_no_peer() {
        let candidates = [
            (0.31, 80.0, 0.0, 40.0, 48.0),
            (0.29, 72.0, 0.0, 40.0, 100.0),
            (0.28, 64.0, 0.0, 40.0, 85.0),
        ];
        let render_order = |order: [usize; 3]| {
            let peer_texture = candidates
                .iter()
                .map(|candidate| candidate.1)
                .fold(0.0, f64::max);
            let peer_sharpness = candidates
                .iter()
                .map(|candidate| candidate.4)
                .fold(0.0, f64::max);
            let adjusted: Vec<f64> = order
                .iter()
                .map(|&index| {
                    let (ownership, _, obstruction, texture, sharpness) = candidates[index];
                    let best_peer = candidates
                        .iter()
                        .enumerate()
                        .filter(|(other, _)| *other != index)
                        .map(|(_, candidate)| candidate.0)
                        .fold(f64::NEG_INFINITY, f64::max);
                    adjusted_ownership(
                        ownership,
                        best_peer,
                        peer_texture,
                        obstruction,
                        texture,
                        sharpness,
                        peer_sharpness,
                        2160,
                    )
                })
                .collect();
            let maximum = adjusted.iter().copied().fold(f64::NEG_INFINITY, f64::max);
            order
                .iter()
                .enumerate()
                .map(|(position, &index)| {
                    (index, deghost_weight(adjusted[position], maximum, 2160))
                })
                .collect::<std::collections::BTreeMap<_, _>>()
        };
        assert_eq!(render_order([0, 1, 2]), render_order([2, 0, 1]));

        let flat_adjusted =
            adjusted_ownership(0.25, f64::NEG_INFINITY, 0.0, 0.95, 0.0, 0.0, 0.0, 2160);
        assert_eq!(flat_adjusted, 0.25);
        assert_eq!(deghost_weight(flat_adjusted, flat_adjusted, 2160), 1.0);
        assert_eq!(deghost_weight(0.25, f64::NEG_INFINITY, 2160), 1.0);
    }

    #[test]
    fn sharpness_aware_render_improves_over_legacy_deghost_on_same_blurred_overlap() {
        const WIDTH: u32 = 1025;
        const HEIGHT: u32 = 512;
        const SOURCE_WIDTH: u32 = 2048;
        const SOURCE_HEIGHT: u32 = 1152;
        const FX: f64 = 1216.0;
        const FY: f64 = 900.0;
        const CX: f64 = (SOURCE_WIDTH as f64 - 1.0) * 0.5;
        const CY: f64 = (SOURCE_HEIGHT as f64 - 1.0) * 0.5;
        let root = std::env::temp_dir().join(format!(
            "lumia-blur-render-compare-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let center_path = root.join("blur-center.png");
        let peer_path = root.join("sharp-peer.png");
        synthetic_scene_source(&center_path, 0.0);
        synthetic_scene_source(&peer_path, -0.6);
        let center = image::open(&center_path).unwrap().into_rgba8();
        image::imageops::blur(&center, 1.5)
            .save(&center_path)
            .unwrap();
        let (sin_yaw, cos_yaw) = (-0.6f64).sin_cos();
        let layout = serde_json::json!({
            "schemaVersion":1,"projection":"spherical",
            "width":WIDTH,"height":HEIGHT,
            "yawMinRad":-0.8,"yawMaxRad":0.2,
            "pitchMinRad":-0.2,"pitchMaxRad":0.2,
            "renderBlendMode":"deghost",
            "tiles":[
                {"path":center_path,"width":SOURCE_WIDTH,"height":SOURCE_HEIGHT,
                 "fx":FX,"fy":FY,"cx":CX,"cy":CY,
                 "cameraToWorld":[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]},
                {"path":peer_path,"width":SOURCE_WIDTH,"height":SOURCE_HEIGHT,
                 "fx":FX,"fy":FY,"cx":CX,"cy":CY,
                 "cameraToWorld":[cos_yaw,0.0,sin_yaw,0.0,1.0,0.0,-sin_yaw,0.0,cos_yaw]}
            ]
        });
        let legacy_dir = root.join("legacy");
        let sharp_dir = root.join("sharpness-aware");
        let checkpoint = |_, _| true;
        render_layout_tiles_with_options_internal(
            &layout,
            &legacy_dir,
            40,
            1,
            true,
            checkpoint,
            false,
        )
        .unwrap();
        render_layout_tiles_with_options_internal_and_ownership(
            &layout, &sharp_dir, 40, 1, true, checkpoint, true, false,
        )
        .unwrap();
        let legacy = collect_level_zero(&legacy_dir, WIDTH, HEIGHT);
        let sharp = collect_level_zero(&sharp_dir, WIDTH, HEIGHT);
        let mut legacy_error = 0.0;
        let mut sharp_error = 0.0;
        let mut samples = 0usize;
        for y in 0..HEIGHT {
            let pitch = 0.2 - (f64::from(y) + 0.5) / f64::from(HEIGHT) * 0.4;
            if pitch.abs() > 0.09 {
                continue;
            }
            for x in 0..WIDTH {
                let yaw = -0.8 + (f64::from(x) + 0.5) / f64::from(WIDTH);
                if (yaw + 0.3).abs() > 0.08 {
                    continue;
                }
                let expected = f64::from(synthetic_scene_value(yaw, pitch));
                let old = legacy.get_pixel(x, y).0;
                let new = sharp.get_pixel(x, y).0;
                assert_eq!(old[3], 255, "legacy overlap unexpectedly uncovered");
                assert_eq!(new[3], old[3], "blur repair changed overlap coverage");
                legacy_error += (f64::from(old[0]) - expected).abs();
                sharp_error += (f64::from(new[0]) - expected).abs();
                samples += 1;
            }
        }
        assert!(samples > 1000);
        legacy_error /= samples as f64;
        sharp_error /= samples as f64;
        assert!(
            sharp_error + 1.0 < legacy_error,
            "sharpness-aware render should beat legacy deghost on the identical blur fixture: legacy MAE={legacy_error:.2}, sharpness-aware MAE={sharp_error:.2}, samples={samples}"
        );
        println!(
            "blur-aware render ROI MAE: legacy={legacy_error:.2}, sharpness-aware={sharp_error:.2}, samples={samples}"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn obstruction_ownership_yields_to_structured_peer_but_falls_back_without_one() {
        let obstructed_ownership = 550. / 2160.;
        let clean_ownership = 250. / 2160.;
        let old_obstruction_weight =
            deghost_weight(obstructed_ownership, obstructed_ownership, 2160);
        assert_eq!(old_obstruction_weight, 1.0);

        let adjusted_obstruction = adjusted_ownership(
            obstructed_ownership,
            clean_ownership,
            40.,
            0.9,
            0.0,
            0.0,
            0.0,
            2160,
        );
        let adjusted_clean = adjusted_ownership(
            clean_ownership,
            obstructed_ownership,
            40.,
            0.0,
            10.0,
            0.0,
            0.0,
            2160,
        );
        let max_adjusted = adjusted_obstruction.max(adjusted_clean);
        let corrected_obstruction_weight = deghost_weight(adjusted_obstruction, max_adjusted, 2160);
        let clean_peer_weight = deghost_weight(adjusted_clean, max_adjusted, 2160);
        assert!(corrected_obstruction_weight < 0.001);
        assert_eq!(clean_peer_weight, 1.0);
        let mut overlap = [0.0f32; 4];
        accumulate_weighted(&mut overlap, [0.0; 3], corrected_obstruction_weight);
        accumulate_weighted(&mut overlap, [0.5; 3], clean_peer_weight);
        let blended = overlap[0] / overlap[3];
        assert!(
            blended > 0.499,
            "obstruction still dominated blend: {blended}"
        );

        let no_peer_adjusted = adjusted_ownership(
            obstructed_ownership,
            f64::NEG_INFINITY,
            0.0,
            0.9,
            0.0,
            0.0,
            0.0,
            2160,
        );
        assert_eq!(no_peer_adjusted, obstructed_ownership);
        let smooth_sky_adjusted = adjusted_ownership(
            obstructed_ownership,
            clean_ownership,
            SOURCE_QUALITY_STRUCTURED_PEER_TEXTURE - 4.,
            0.9,
            0.0,
            0.0,
            0.0,
            2160,
        );
        assert_eq!(smooth_sky_adjusted, obstructed_ownership);
        assert!(deghost_weight(f64::NEG_INFINITY, f64::NEG_INFINITY, 2160).is_finite());
    }

    #[test]
    #[ignore = "manual full-lattice truck/SUV edge ablation; set LUMIA_TRIANGLE_TASK_DIR and LUMIA_TRIANGLE_OUTPUT_DIR"]
    fn real_source_hard_triangle_full_lattice_ablation() {
        let task = PathBuf::from(
            std::env::var("LUMIA_TRIANGLE_TASK_DIR")
                .expect("set LUMIA_TRIANGLE_TASK_DIR to the completed task directory"),
        );
        let output = PathBuf::from(std::env::var("LUMIA_TRIANGLE_OUTPUT_DIR").unwrap_or_else(
            |_| {
                std::env::temp_dir()
                    .join(format!("lumia-triangle-ablation-{}", std::process::id()))
                    .to_string_lossy()
                    .into_owned()
            },
        ));
        fs::create_dir_all(&output).unwrap();
        let layout: Value = serde_json::from_slice(
            &fs::read(task.join("output/layout.json")).expect("read full task layout"),
        )
        .unwrap();
        let (width, height, bounds, sources, _) = dimensions(&layout).unwrap();
        let no_warp_sources: Vec<Source> = sources
            .iter()
            .cloned()
            .map(|mut source| {
                source.source_plane_warp = None;
                source
            })
            .collect();
        let warp_checkpoint = || true;
        let source_warp_count = sources
            .iter()
            .filter(|source| source.source_plane_warp.is_some())
            .count();
        let warped_map =
            build_global_ownership_map(width, height, bounds, &sources, warp_checkpoint)
                .expect("build full-resolution-coordinate ownership map");
        let plain_map = if source_warp_count == 0 {
            None
        } else {
            Some(
                build_global_ownership_map(
                    width,
                    height,
                    bounds,
                    &no_warp_sources,
                    warp_checkpoint,
                )
                .expect("build no-warp ownership map on the same full lattice"),
            )
        };

        let target_points = [
            (59_200u32, 15_875u32),
            (59_621u32, 15_870u32),
            (59_200u32, 15_920u32),
            (59_621u32, 15_920u32),
        ];
        let source_ids = [
            sources
                .iter()
                .position(|source| {
                    source
                        .path
                        .file_name()
                        .is_some_and(|name| name == "0227.jpg")
                })
                .expect("source 0227 exists"),
            sources
                .iter()
                .position(|source| {
                    source
                        .path
                        .file_name()
                        .is_some_and(|name| name == "0253.jpg")
                })
                .expect("source 0253 exists"),
        ];
        let map_report = |map: &CoarseOwnershipMap, x: u32, y: u32| {
            let owner = map.owner_at(x, y);
            serde_json::json!({
                "stridePx": map.stride,
                "owner": owner.map(|index| sources[index].path.file_name().unwrap().to_string_lossy().into_owned()),
                "confidence": map.confidence_at(x,y),
                "sourceProbabilities": source_ids.iter().map(|&index| serde_json::json!({
                    "source": sources[index].path.file_name().unwrap().to_string_lossy().into_owned(),
                    "probability": map.source_probability(index,x,y,4)
                })).collect::<Vec<_>>()
            })
        };
        let mut samples = Vec::new();
        for (x, y) in target_points {
            let yaw = bounds[0] + (f64::from(x) + 0.5) / f64::from(width) * (bounds[1] - bounds[0]);
            let pitch =
                bounds[3] - (f64::from(y) + 0.5) / f64::from(height) * (bounds[3] - bounds[2]);
            let world = [
                yaw.sin() * pitch.cos(),
                pitch.sin(),
                yaw.cos() * pitch.cos(),
            ];
            let source_metrics: Vec<Value> = source_ids
                .iter()
                .map(|&index| {
                    let source = &sources[index];
                    let image = image::open(&source.path).unwrap().into_rgba8();
                    let quality = SourceQualityMap::from_image(&image);
                    match sample_geometry(source, world) {
                        Some((sx, sy, _, ownership)) => {
                            let (texture, obstruction) =
                                quality.sample(source.width, source.height, sx, sy);
                            serde_json::json!({
                                "source": source.path.file_name().unwrap().to_string_lossy(),
                                "sourceXY": [sx,sy],
                                "edgePx": (sx.min(sy).min(f64::from(source.width)-sx).min(f64::from(source.height)-sy)),
                                "geometryOwnership": ownership,
                                "texture": texture,
                                "sharpness": quality.sharpness(source.width,source.height,sx,sy),
                                "obstructionConfidence": obstruction,
                                "sampledRgb": sample(source,&image,world).map(|value| value.0)
                            })
                        }
                        None => serde_json::json!({
                            "source": source.path.file_name().unwrap().to_string_lossy(),
                            "covered": false
                        }),
                    }
                })
                .collect();
            samples.push(serde_json::json!({
                "pixel": [x,y],
                "warpedOwnership": map_report(&warped_map,x,y),
                "noWarpOwnership": plain_map.as_ref().map(|map| map_report(map,x,y)),
                "edgeSourceMetrics": source_metrics
            }));
        }

        let source_bytes: Vec<u64> = sources
            .iter()
            .map(|source| u64::from(source.width) * u64::from(source.height) * 4)
            .collect();
        let rows: std::collections::BTreeSet<u32> =
            target_points.iter().map(|&(_, y)| y / TILE).collect();
        let cols: std::collections::BTreeSet<u32> =
            target_points.iter().map(|&(x, _)| x / TILE).collect();
        let tiles: Vec<(u32, u32)> = rows
            .iter()
            .flat_map(|&row| cols.iter().map(move |&col| (row, col)))
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        let render_variant =
            |name: &str,
             mode: BlendMode,
             variant_sources: &[Source],
             ownership_map: Option<&CoarseOwnershipMap>| {
                let dir = output.join(name);
                fs::create_dir_all(&dir).unwrap();
                let cache = DecodeCache::new(0, 1);
                let counters: Vec<AtomicU64> = (0..20).map(|_| AtomicU64::new(0)).collect();
                for (row, col) in &tiles {
                    render_one_tile(
                        *row,
                        *col,
                        width,
                        height,
                        bounds,
                        variant_sources,
                        &source_bytes,
                        &dir,
                        &cache,
                        &counters[0],
                        &counters[1],
                        &counters[2],
                        &counters[3],
                        &counters[4],
                        &counters[5],
                        &counters[6],
                        &counters[7],
                        true,
                        0,
                        &counters[8],
                        &counters[9],
                        &counters[10],
                        &counters[11],
                        &counters[12],
                        &counters[13],
                        &counters[14],
                        &counters[15],
                        true,
                        mode,
                        true,
                        ownership_map,
                        None,
                        &counters[16],
                        &counters[17],
                        &counters[18],
                    )
                    .expect("render selected full-layout output tile");
                }
            };
        render_variant(
            "deghost-warped-owner",
            BlendMode::Deghost,
            &sources,
            Some(&warped_map),
        );
        render_variant(
            "deghost-warped-no-owner",
            BlendMode::Deghost,
            &sources,
            None,
        );
        render_variant(
            "deghost-no-warp-owner",
            BlendMode::Deghost,
            &no_warp_sources,
            Some(plain_map.as_ref().unwrap_or(&warped_map)),
        );
        render_variant("feather-warped", BlendMode::Feather, &sources, None);
        render_variant(
            "feather-no-warp",
            BlendMode::Feather,
            &no_warp_sources,
            None,
        );
        fs::write(
            output.join("diagnostic.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "task": task,
                "layoutDimensions": [width,height],
                "ownershipMapDimensions": [warped_map.width,warped_map.height],
                "sourceWarpCount": source_warp_count,
                "targetTiles": tiles,
                "variants": [
                    "deghost-warped-owner", "deghost-warped-no-owner",
                    "deghost-no-warp-owner", "feather-warped", "feather-no-warp"
                ],
                "samples": samples
            }))
            .unwrap(),
        )
        .unwrap();
        println!("triangle ablation outputs: {}", output.display());
    }

    #[test]
    #[ignore = "set LUMIA_RENDERER_TASK_DIR to the preserved 384-photo task to run this real-source regression"]
    fn real_source_obstruction_roi_0171_0172_prefers_the_clean_overlap() {
        let task = PathBuf::from(
            std::env::var("LUMIA_RENDERER_TASK_DIR")
                .expect("set LUMIA_RENDERER_TASK_DIR to the preserved task directory"),
        );
        let layout: Value = serde_json::from_slice(
            &fs::read(task.join("output/layout.json")).expect("read preserved layout"),
        )
        .unwrap();
        let (_, _, bounds, sources, _) = dimensions(&layout).unwrap();
        let find_source = |file: &str| {
            sources
                .iter()
                .find(|source| source.path.file_name().is_some_and(|name| name == file))
                .expect("source exists in real task layout")
        };
        let obstruction_source = find_source("0171.jpg");
        let clean_source = find_source("0172.jpg");
        let output_x = 215u32;
        let output_y = 228u32;
        let base_x = f64::from(output_x) * 64.0 + 31.5;
        let base_y = f64::from(output_y) * 64.0 + 31.5;
        let yaw = bounds[0]
            + (base_x + 0.5) / f64::from(layout["width"].as_u64().unwrap() as u32)
                * (bounds[1] - bounds[0]);
        let pitch = bounds[3]
            - (base_y + 0.5) / f64::from(layout["height"].as_u64().unwrap() as u32)
                * (bounds[3] - bounds[2]);
        let world = [
            yaw.sin() * pitch.cos(),
            pitch.sin(),
            yaw.cos() * pitch.cos(),
        ];
        let bad_geometry = sample_geometry(obstruction_source, world).unwrap();
        let good_geometry = sample_geometry(clean_source, world).unwrap();
        let obstruction = image::open(&obstruction_source.path).unwrap().into_rgba8();
        let clean = image::open(&clean_source.path).unwrap().into_rgba8();
        let obstruction_map = SourceQualityMap::from_image(&obstruction);
        let clean_map = SourceQualityMap::from_image(&clean);
        let (bad_texture, confidence) = obstruction_map.sample(
            obstruction_source.width,
            obstruction_source.height,
            bad_geometry.0,
            bad_geometry.1,
        );
        let (good_texture, good_confidence) = clean_map.sample(
            clean_source.width,
            clean_source.height,
            good_geometry.0,
            good_geometry.1,
        );
        assert!(confidence >= SOURCE_QUALITY_SUSPECT_CONFIDENCE);
        assert!(bad_texture <= SOURCE_QUALITY_LOW_TEXTURE_MAX);
        assert!(good_texture >= SOURCE_QUALITY_STRUCTURED_PEER_TEXTURE);
        assert!(good_confidence < SOURCE_QUALITY_SUSPECT_CONFIDENCE);
        assert!(bad_geometry.3 > good_geometry.3);
        let max_ownership = bad_geometry.3.max(good_geometry.3);
        let bad_before = deghost_weight(bad_geometry.3, max_ownership, 2160);
        let good_before = deghost_weight(good_geometry.3, max_ownership, 2160);
        assert!(bad_before > good_before * 1.0e20);
        let bad_adjusted = adjusted_ownership(
            bad_geometry.3,
            good_geometry.3,
            good_texture,
            confidence,
            bad_texture,
            obstruction_map.sharpness(
                obstruction_source.width,
                obstruction_source.height,
                bad_geometry.0,
                bad_geometry.1,
            ),
            clean_map.sharpness(
                clean_source.width,
                clean_source.height,
                good_geometry.0,
                good_geometry.1,
            ),
            2160,
        );
        let good_adjusted = adjusted_ownership(
            good_geometry.3,
            bad_geometry.3,
            good_texture,
            good_confidence,
            good_texture,
            clean_map.sharpness(
                clean_source.width,
                clean_source.height,
                good_geometry.0,
                good_geometry.1,
            ),
            clean_map.sharpness(
                clean_source.width,
                clean_source.height,
                good_geometry.0,
                good_geometry.1,
            ),
            2160,
        );
        let max_adjusted = bad_adjusted.max(good_adjusted);
        let bad_weight = deghost_weight(bad_adjusted, max_adjusted, 2160);
        let good_weight = deghost_weight(good_adjusted, max_adjusted, 2160);
        let bad_rgb = sample(obstruction_source, &obstruction, world).unwrap().0;
        let good_rgb = sample(clean_source, &clean, world).unwrap().0;
        let mut blend = [0.0; 4];
        accumulate_weighted(&mut blend, bad_rgb, bad_weight);
        accumulate_weighted(&mut blend, good_rgb, good_weight);
        let rendered = [
            blend[0] / blend[3],
            blend[1] / blend[3],
            blend[2] / blend[3],
        ];
        let error = rendered
            .iter()
            .zip(good_rgb)
            .map(|(rendered, good)| (f64::from(*rendered) - good).abs())
            .fold(0.0, f64::max);
        assert!(
            error < 0.001,
            "real overlap still picks obstruction: {error}"
        );

        for (sample_x, sample_y, expected_index) in [(419u32, 220u32, 176usize), (805, 194, 160)] {
            let level0_x = f64::from(sample_x) * 64.0 + 31.5;
            let level0_y = f64::from(sample_y) * 64.0 + 31.5;
            let yaw = bounds[0]
                + (level0_x + 0.5) / f64::from(layout["width"].as_u64().unwrap() as u32)
                    * (bounds[1] - bounds[0]);
            let pitch = bounds[3]
                - (level0_y + 0.5) / f64::from(layout["height"].as_u64().unwrap() as u32)
                    * (bounds[3] - bounds[2]);
            let world = [
                yaw.sin() * pitch.cos(),
                pitch.sin(),
                yaw.cos() * pitch.cos(),
            ];
            let covering = sources
                .iter()
                .filter(|source| sample_geometry(source, world).is_some())
                .count();
            assert_eq!(
                covering, 1,
                "expected one source at no-peer block {sample_x},{sample_y}"
            );
            let only_source = sources
                .iter()
                .find(|source| sample_geometry(source, world).is_some())
                .unwrap();
            let expected_name = format!("{expected_index:04}.jpg");
            assert_eq!(
                only_source.path.file_name().unwrap().to_string_lossy(),
                expected_name
            );
            let only_source_weight = deghost_weight(0.25, f64::NEG_INFINITY, 2160);
            assert_eq!(only_source_weight, 1.0);
        }
    }

    #[test]
    fn non_square_odd_pyramid_uses_row_column_order_and_keeps_partial_edges() {
        let root = std::env::temp_dir().join(format!(
            "gigascan-pyramid-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(root.join("level-0")).unwrap();
        let width = 513u32;
        let height = 1025u32;
        for row in 0..height.div_ceil(TILE) {
            for col in 0..width.div_ceil(TILE) {
                let tw = (width - col * TILE).min(TILE);
                let th = (height - row * TILE).min(TILE);
                let alpha = if row == 2 && col == 1 { 128 } else { 255 };
                let color = Rgba([(row * 50) as u8, (col * 60) as u8, 20, alpha]);
                let tile = RgbaImage::from_pixel(tw, th, color);
                tile.save(root.join(format!("level-0/{row}-{col}.png")))
                    .unwrap();
            }
        }
        let levels = build_pyramid_levels(&root, width, height, |_, _| true).unwrap();
        assert_eq!(
            (
                levels[1]["width"].as_u64().unwrap(),
                levels[1]["height"].as_u64().unwrap()
            ),
            (257, 513)
        );
        assert_eq!(levels.last().unwrap()["width"].as_u64().unwrap(), 1);
        let last = image::open(root.join("level-1/1-0.png"))
            .unwrap()
            .to_rgba8();
        assert_eq!(last.dimensions(), (257, 1));
        assert_eq!(last.get_pixel(256, 0).0, [100, 60, 20, 128]);
        let resume = build_pyramid_levels(&root, width, height, |_, _| true).unwrap();
        assert_eq!(resume, levels);
        fs::write(root.join("level-2/0-0.png"), b"truncated IDAT").unwrap();
        let damaged = build_pyramid_levels(&root, width, height, |_, _| true).unwrap_err();
        assert!(damaged.to_string().contains("cannot be decoded"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn parallel_pyramid_matches_serial_for_odd_multilevel_input_and_resumes_cancelled_work() {
        let root = std::env::temp_dir().join(format!(
            "lumia-pyramid-parallel-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let serial_root = root.join("serial");
        let parallel_root = root.join("parallel");
        let cancelled_root = root.join("cancelled");
        let width = 1025u32;
        let height = 1027u32;
        for base in [&serial_root, &parallel_root, &cancelled_root] {
            fs::create_dir_all(base.join("level-0")).unwrap();
            for row in 0..height.div_ceil(TILE) {
                for col in 0..width.div_ceil(TILE) {
                    let tw = (width - col * TILE).min(TILE);
                    let th = (height - row * TILE).min(TILE);
                    let color = Rgba([
                        (row * 31 + col * 17) as u8,
                        (col * 47) as u8,
                        (row * 13) as u8,
                        if (row + col) % 2 == 0 { 255 } else { 127 },
                    ]);
                    RgbaImage::from_pixel(tw, th, color)
                        .save(base.join(format!("level-0/{row}-{col}.png")))
                        .unwrap();
                }
            }
        }
        let serial_levels = build_pyramid_levels(&serial_root, width, height, |_, _| true).unwrap();
        let (parallel_levels, stats) =
            build_pyramid_levels_with_options(&parallel_root, width, height, 128, 4, |_, _| true)
                .unwrap();
        assert_eq!(serial_levels, parallel_levels);
        assert!(stats["workersEffective"].as_u64().unwrap() > 1);
        for level in serial_levels.iter().skip(1) {
            for tile in level["occupied"].as_array().unwrap() {
                let relative = PathBuf::from(tile["path"].as_str().unwrap());
                assert_eq!(
                    fs::read(serial_root.join(&relative)).unwrap(),
                    fs::read(parallel_root.join(&relative)).unwrap()
                );
            }
        }
        let cancelled =
            build_pyramid_levels_with_options(&cancelled_root, width, height, 128, 4, |done, _| {
                done < 1
            });
        assert!(matches!(cancelled, Err(crate::Error::Cancelled)));
        assert!(!cancelled_root.join("manifest.json").exists());
        let resumed =
            build_pyramid_levels_with_options(&cancelled_root, width, height, 128, 4, |_, _| true)
                .unwrap()
                .0;
        assert_eq!(resumed, serial_levels);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn resumed_tile_must_decode_completely() {
        let root = std::env::temp_dir().join(format!(
            "lumia-corrupt-tile-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("0-0.png");
        fs::write(&path, b"PNG header with incomplete image data").unwrap();
        let err = validate_cached_tile(&path, (1, 1)).unwrap_err();
        assert!(err.to_string().contains("cannot be decoded"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn renderer_identity_prevents_mixed_algorithm_cache_without_deleting_tiles() {
        let root = std::env::temp_dir().join(format!(
            "lumia-render-identity-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let level = root.join("level-0");
        fs::create_dir_all(&level).unwrap();
        let cached = level.join("0-0.png");
        fs::write(&cached, b"preserve cached tile").unwrap();
        let error = validate_or_write_renderer_identity(&root, BlendMode::Deghost).unwrap_err();
        assert!(error
            .to_string()
            .contains("create a task copy and restitch"));
        assert_eq!(fs::read(&cached).unwrap(), b"preserve cached tile");
        assert!(!root.join("renderer-identity.json").exists());

        // Feather is byte-compatible with legacy caches and may adopt a marker;
        // switching that output to deghost is then rejected by identity.
        validate_or_write_renderer_identity(&root, BlendMode::Feather).unwrap();
        assert!(validate_or_write_renderer_identity(&root, BlendMode::Feather).is_ok());
        assert!(validate_or_write_renderer_identity(&root, BlendMode::Deghost).is_err());
        assert_eq!(fs::read(&cached).unwrap(), b"preserve cached tile");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn parallel_tiles_match_serial_and_memory_budget_clamps_workers() {
        let root = std::env::temp_dir().join(format!(
            "lumia-render-parallel-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let sources_dir = root.join("sources");
        fs::create_dir_all(&sources_dir).unwrap();
        let source_path = sources_dir.join("source.png");
        RgbaImage::from_pixel(3300, 3300, Rgba([30, 100, 220, 255]))
            .save(&source_path)
            .unwrap();
        let layout = serde_json::json!({
            "schemaVersion":1,"projection":"spherical","width":1025,"height":8,
            "yawMinRad":-0.01,"yawMaxRad":0.01,"pitchMinRad":-0.01,"pitchMaxRad":0.01,
            "tiles":[{"path":source_path.to_string_lossy(),"width":3300,"height":3300,"fx":100.0,"fy":100.0,"cx":1649.5,"cy":1649.5,"cameraToWorld":[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]}]
        });
        let serial_dir = root.join("serial");
        let low_memory_dir = root.join("low-memory");
        let normal_dir = root.join("normal");
        let serial =
            render_layout_tiles_with_options(&layout, &serial_dir, 128, 1, true, |_, _| true)
                .unwrap();
        let low =
            render_layout_tiles_with_options(&layout, &low_memory_dir, 128, 8, true, |_, _| true)
                .unwrap();
        let parallel =
            render_layout_tiles_with_options(&layout, &normal_dir, 512, 8, true, |_, _| true)
                .unwrap();
        assert_eq!(low["workersEffective"].as_u64(), Some(1));
        assert!(parallel["workersEffective"].as_u64().unwrap() > 1);
        assert_eq!(parallel["sourceDecodes"].as_u64(), Some(1));
        assert_eq!(parallel["sourceDecodeErrors"].as_u64(), Some(0));
        assert!(
            parallel["sourceDecodePeakInFlight"].as_u64().unwrap()
                <= parallel["reservedDecodeSlots"].as_u64().unwrap()
        );
        assert!(parallel["decodeSlotReserveBytes"].as_u64().unwrap() > 0);
        assert!(
            parallel["peakSourceCacheBytes"].as_u64().unwrap()
                <= parallel["sourceCacheLimitBytes"].as_u64().unwrap()
        );
        for row in 0..1 {
            for col in 0..3 {
                let name = format!("level-0/{row}-{col}.png");
                assert_eq!(
                    fs::read(serial_dir.join(&name)).unwrap(),
                    fs::read(low_memory_dir.join(&name)).unwrap()
                );
                assert_eq!(
                    fs::read(serial_dir.join(&name)).unwrap(),
                    fs::read(normal_dir.join(&name)).unwrap()
                );
            }
        }
        assert_eq!(serial["completedTiles"], parallel["completedTiles"]);

        let mut zero_warp_layout = layout.clone();
        zero_warp_layout["tiles"][0]["sourcePlaneWarp"] = serde_json::json!({
            "columns":3,"rows":3,"offsets":[
                [0.0,0.0],[0.0,0.0],[0.0,0.0],
                [0.0,0.0],[0.0,0.0],[0.0,0.0],
                [0.0,0.0],[0.0,0.0],[0.0,0.0]
            ]
        });
        let zero_warp_dir = root.join("zero-warp");
        render_layout_tiles_with_options(
            &zero_warp_layout,
            &zero_warp_dir,
            128,
            1,
            true,
            |_, _| true,
        )
        .unwrap();
        for col in 0..3 {
            let name = format!("level-0/0-{col}.png");
            assert_eq!(
                fs::read(serial_dir.join(&name)).unwrap(),
                fs::read(zero_warp_dir.join(&name)).unwrap(),
                "zero sourcePlaneWarp must preserve legacy render bytes"
            );
        }

        let mut shifted_layout = layout.clone();
        shifted_layout["tiles"][0]["sourcePlaneWarp"] = serde_json::json!({
            "columns":3,"rows":3,"offsets":[
                [-2.0,1.0],[0.0,1.0],[2.0,1.0],
                [-2.0,0.0],[0.0,0.0],[2.0,0.0],
                [-2.0,-1.0],[0.0,-1.0],[2.0,-1.0]
            ]
        });
        let shifted_serial_dir = root.join("shifted-serial");
        let shifted_parallel_dir = root.join("shifted-parallel");
        render_layout_tiles_with_options(
            &shifted_layout,
            &shifted_serial_dir,
            128,
            1,
            true,
            |_, _| true,
        )
        .unwrap();
        render_layout_tiles_with_options(
            &shifted_layout,
            &shifted_parallel_dir,
            512,
            8,
            true,
            |_, _| true,
        )
        .unwrap();
        for col in 0..3 {
            let name = format!("level-0/0-{col}.png");
            assert_eq!(
                fs::read(shifted_serial_dir.join(&name)).unwrap(),
                fs::read(shifted_parallel_dir.join(&name)).unwrap(),
                "warped render must be deterministic across worker counts"
            );
        }

        let mut shifted_deghost_layout = shifted_layout.clone();
        shifted_deghost_layout["renderBlendMode"] = serde_json::json!("deghost");
        let shifted_deghost_cached_dir = root.join("shifted-deghost-cached");
        let shifted_deghost_fallback_dir = root.join("shifted-deghost-fallback");
        let shifted_deghost_cached = render_layout_tiles_with_options(
            &shifted_deghost_layout,
            &shifted_deghost_cached_dir,
            128,
            1,
            true,
            |_, _| true,
        )
        .unwrap();
        let shifted_deghost_fallback = render_layout_tiles_with_options(
            &shifted_deghost_layout,
            &shifted_deghost_fallback_dir,
            102,
            1,
            true,
            |_, _| true,
        )
        .unwrap();
        assert_eq!(shifted_deghost_cached["geometryCacheEnabled"], true);
        assert_eq!(shifted_deghost_fallback["geometryCacheEnabled"], false);
        assert!(
            shifted_deghost_cached["adjustedOwnershipScoresReused"]
                .as_u64()
                .unwrap()
                > 0
        );
        assert_eq!(
            shifted_deghost_fallback["adjustedOwnershipScoresReused"].as_u64(),
            Some(0)
        );
        assert!(
            shifted_deghost_cached["ownerGeometryValidityProjectionsReused"]
                .as_u64()
                .unwrap()
                > 0
        );
        assert_eq!(shifted_deghost_cached["workersEffective"].as_u64(), Some(1));
        assert_eq!(
            shifted_deghost_fallback["workersEffective"].as_u64(),
            Some(1)
        );
        assert!(
            shifted_deghost_cached["geometryProjectionEvaluationsAvoided"]
                .as_u64()
                .unwrap()
                > 0
        );
        assert_eq!(
            shifted_deghost_fallback["geometryProjectionEvaluationsAvoided"].as_u64(),
            Some(0)
        );
        assert!(
            shifted_deghost_cached["geometryCacheBytesPerWorkerReserved"]
                .as_u64()
                .unwrap()
                <= GEOMETRY_CACHE_MAX_BYTES_PER_WORKER
        );
        for col in 0..3 {
            let name = format!("level-0/0-{col}.png");
            assert_eq!(
                fs::read(shifted_deghost_cached_dir.join(&name)).unwrap(),
                fs::read(shifted_deghost_fallback_dir.join(&name)).unwrap(),
                "warped deghost output changed when bounded geometry reuse was disabled"
            );
        }

        let mut deghost_layout = layout.clone();
        deghost_layout["renderBlendMode"] = serde_json::json!("deghost");
        let deghost_serial_dir = root.join("deghost-serial");
        let deghost_parallel_dir = root.join("deghost-parallel");
        let deghost_fallback_dir = root.join("deghost-fallback");
        let deghost_serial = render_layout_tiles_with_options(
            &deghost_layout,
            &deghost_serial_dir,
            128,
            1,
            true,
            |_, _| true,
        )
        .unwrap();
        let deghost_parallel = render_layout_tiles_with_options(
            &deghost_layout,
            &deghost_parallel_dir,
            512,
            8,
            true,
            |_, _| true,
        )
        .unwrap();
        let deghost_fallback = render_layout_tiles_with_options(
            &deghost_layout,
            &deghost_fallback_dir,
            102,
            1,
            true,
            |_, _| true,
        )
        .unwrap();
        assert_eq!(deghost_serial["geometryCacheEnabled"], true);
        assert_eq!(deghost_fallback["geometryCacheEnabled"], false);
        assert_eq!(deghost_serial["workersEffective"].as_u64(), Some(1));
        assert_eq!(deghost_fallback["workersEffective"].as_u64(), Some(1));
        assert_eq!(serial["blendModel"], "source-edge-smoothstep-feather");
        let feather_identity: Value =
            serde_json::from_slice(&fs::read(serial_dir.join("renderer-identity.json")).unwrap())
                .unwrap();
        let deghost_identity: Value = serde_json::from_slice(
            &fs::read(deghost_serial_dir.join("renderer-identity.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(feather_identity["algorithmVersion"], 1);
        assert_eq!(deghost_identity["algorithmVersion"], 3);
        assert_eq!(
            deghost_serial["blendModel"],
            "sharpness-aware-peer-coupled-coarse-ownership-v2"
        );
        assert_eq!(
            deghost_serial["completedTiles"],
            deghost_parallel["completedTiles"]
        );
        for col in 0..3 {
            let name = format!("level-0/0-{col}.png");
            let feather_bytes = fs::read(serial_dir.join(&name)).unwrap();
            let deghost_bytes = fs::read(deghost_serial_dir.join(&name)).unwrap();
            assert_eq!(
                feather_bytes, deghost_bytes,
                "single-source pixels must be unchanged"
            );
            assert_eq!(
                deghost_bytes,
                fs::read(deghost_parallel_dir.join(&name)).unwrap(),
                "deghost output must be deterministic across worker counts"
            );
            assert_eq!(
                deghost_bytes,
                fs::read(deghost_fallback_dir.join(&name)).unwrap(),
                "unwarped deghost output changed when bounded geometry reuse was disabled"
            );
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn deghost_multi_source_cache_fallback_is_stable_across_order_workers_and_tile_boundary() {
        let root = std::env::temp_dir().join(format!(
            "lumia-deghost-order-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let colors = [32u8, 80, 160, 224];
        let mut tiles = Vec::new();
        for (index, base) in colors.iter().enumerate() {
            let path = root.join(format!("source-{index}.png"));
            let mut image = patterned_source(1200, 1200);
            for pixel in image.pixels_mut() {
                let pattern = pixel[0].saturating_sub(112);
                let value = base.saturating_add(pattern / 3);
                *pixel = Rgba([
                    value,
                    value.saturating_add(8),
                    value.saturating_add(16),
                    255,
                ]);
            }
            for y in 580..=620 {
                for x in 580..=620 {
                    image.put_pixel(
                        x,
                        y,
                        Rgba([*base, base.saturating_add(8), base.saturating_add(16), 255]),
                    );
                }
            }
            image.save(&path).unwrap();
            let mut source = serde_json::json!({
                "path":path.to_string_lossy(),"width":1200,"height":1200,
                "fx":400.0,"fy":400.0,"cx":599.5,"cy":599.5,
                "cameraToWorld":[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]
            });
            if index == 0 {
                source["sourcePlaneWarp"] = serde_json::json!({
                    "columns":3,"rows":3,"offsets":[
                        [-1.0,1.0],[0.0,1.0],[1.0,1.0],
                        [-1.0,0.0],[0.0,0.0],[1.0,0.0],
                        [-1.0,-1.0],[0.0,-1.0],[1.0,-1.0]
                    ]
                });
            }
            tiles.push(source);
        }
        let mut layout = serde_json::json!({
            "schemaVersion":1,"projection":"spherical","width":1025,"height":8,
            "yawMinRad":-0.01,"yawMaxRad":0.01,"pitchMinRad":-0.01,"pitchMaxRad":0.01,
            "renderBlendMode":"deghost","tiles":tiles
        });
        let original_layout = layout.clone();
        layout["tiles"].as_array_mut().unwrap().reverse();
        let original_dir = root.join("original");
        let reversed_dir = root.join("reversed");
        let parallel_dir = root.join("parallel");
        let fallback_dir = root.join("fallback");
        let original = render_layout_tiles_with_options(
            &original_layout,
            &original_dir,
            128,
            1,
            true,
            |_, _| true,
        )
        .unwrap();
        let reversed =
            render_layout_tiles_with_options(&layout, &reversed_dir, 128, 1, true, |_, _| true)
                .unwrap();
        let parallel =
            render_layout_tiles_with_options(&layout, &parallel_dir, 512, 8, true, |_, _| true)
                .unwrap();
        let fallback =
            render_layout_tiles_with_options(&layout, &fallback_dir, 32, 1, true, |_, _| true)
                .unwrap();
        assert_eq!(
            original["blendModel"],
            "sharpness-aware-peer-coupled-coarse-ownership-v2"
        );
        assert_eq!(original["geometryCacheEnabled"], true);
        assert!(original["geometryCachedSourceTileCount"].as_u64().unwrap() > 0);
        assert!(
            original["geometryProjectionEvaluationsAvoided"]
                .as_u64()
                .unwrap()
                > 0
        );
        assert!(
            original["geometryCacheSourceSlotsPerTile"]
                .as_u64()
                .unwrap()
                > 0
        );
        assert!(original["adjustedOwnershipScoresReused"].as_u64().unwrap() > 0);
        assert_eq!(fallback["geometryCacheEnabled"], false);
        assert_eq!(fallback["geometryCacheSourceSlotsPerTile"], 0);
        assert_eq!(fallback["adjustedOwnershipScoresReused"].as_u64(), Some(0));
        assert!(parallel["workersEffective"].as_u64().unwrap() > 1);
        assert_eq!(fallback["workersEffective"].as_u64(), Some(1));
        assert_eq!(original["completedTiles"], reversed["completedTiles"]);
        assert_eq!(original["completedTiles"], parallel["completedTiles"]);
        assert_eq!(original["completedTiles"], fallback["completedTiles"]);
        for col in 0..3 {
            let name = format!("level-0/0-{col}.png");
            let original_image = image::open(original_dir.join(&name)).unwrap().to_rgba8();
            assert_eq!(
                original_image,
                image::open(reversed_dir.join(&name)).unwrap().to_rgba8()
            );
            assert_eq!(
                original_image,
                image::open(parallel_dir.join(&name)).unwrap().to_rgba8()
            );
            assert_eq!(
                original_image,
                image::open(fallback_dir.join(&name)).unwrap().to_rgba8(),
                "multi-source cached and zero-slot fallback RGBA differ"
            );
        }
        let left = image::open(original_dir.join("level-0/0-0.png"))
            .unwrap()
            .to_rgba8();
        let right = image::open(original_dir.join("level-0/0-1.png"))
            .unwrap()
            .to_rgba8();
        assert_eq!(left.get_pixel(511, 4), right.get_pixel(0, 4));
        fs::remove_dir_all(root).unwrap();
    }
}
