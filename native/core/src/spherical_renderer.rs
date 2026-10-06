//! Portable, tiled spherical renderer for persisted camera layouts.
//!
//! The renderer deliberately has no OpenCV/GPU dependency. It consumes the
//! spherical JSON layout emitted by `spherical::align_json_detailed`.
use crate::texture_warp::{
    corrected_to_source, validate_source_plane_warp, SourcePlaneWarp,
    SOURCE_WARP_MAX_DISPLACEMENT_PX,
};
use image::{GenericImageView, ImageBuffer, Rgba, RgbaImage};
use serde_json::Value;
use std::{
    collections::{HashMap, VecDeque},
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
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
static RENDERER_IDENTITY_TEMP_ID: AtomicU64 = AtomicU64::new(0);

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
            Self::Deghost => "sharpness-aware-max-score-softmax-ownership",
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
        "algorithmVersion": 1
    })
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

fn validate_or_write_renderer_identity(output: &Path, blend_mode: BlendMode) -> crate::Result<()> {
    let marker_path = output.join("renderer-identity.json");
    let expected = renderer_identity(blend_mode);
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
    if blend_mode == BlendMode::Deghost && has_existing_render_tiles(output)? {
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

fn sample(
    source: &Source,
    image: &RgbaImage,
    world: [f64; 3],
) -> Option<([f64; 3], f64, f64, f64, f64)> {
    let (x, y, weight, ownership) = sample_geometry(source, world)?;
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
    Some((
        [linear(rgb[0]), linear(rgb[1]), linear(rgb[2])],
        weight,
        ownership,
        x,
        y,
    ))
}

fn deghost_weight(ownership: f64, max_ownership: f64, source_min_dimension: u32) -> f64 {
    let temperature = DEGHOST_OWNERSHIP_TEMPERATURE_SOURCE_PIXELS / f64::from(source_min_dimension);
    ((ownership - max_ownership) / temperature).exp()
}

fn deghost_source_weight_with_sharpness(
    ownership: f64,
    max_ownership: f64,
    max_uncapped_ownership: f64,
    max_cap_eligible_ownership: f64,
    max_structured_peer_texture: f64,
    obstruction_confidence: f64,
    texture_energy: f64,
    normalized_sharpness: f64,
    max_peer_sharpness: f64,
    source_min_dimension: u32,
) -> f64 {
    let local_blur = max_structured_peer_texture >= SOURCE_QUALITY_BLUR_PEER_TEXTURE
        && max_peer_sharpness >= SOURCE_QUALITY_BLUR_PEER_SHARPNESS
        && normalized_sharpness <= max_peer_sharpness * SOURCE_QUALITY_BLUR_RELATIVE_MAX;
    let current_is_cap_eligible = local_blur
        || (obstruction_confidence >= SOURCE_QUALITY_SUSPECT_CONFIDENCE
            && texture_energy <= SOURCE_QUALITY_LOW_TEXTURE_MAX);
    let structured_overlap = max_structured_peer_texture >= SOURCE_QUALITY_STRUCTURED_PEER_TEXTURE
        && max_uncapped_ownership.is_finite()
        && max_cap_eligible_ownership > max_uncapped_ownership;
    if structured_overlap {
        // Every source that cannot be capped participates in the same
        // reference. A cap candidate must be either a high-confidence,
        // low-texture obstruction or locally softer than a textured peer;
        // interpolation across a quality boundary cannot switch the reference
        // unless the source also satisfies the corresponding eligibility test.
        let margin = SOURCE_QUALITY_OVERRIDE_MARGIN_SOURCE_PX / f64::from(source_min_dimension);
        let effective_ownership = if current_is_cap_eligible {
            ownership.min(max_uncapped_ownership - margin)
        } else {
            ownership
        };
        deghost_weight(
            effective_ownership,
            max_uncapped_ownership,
            source_min_dimension,
        )
    } else {
        // Without a clean structured peer, preserve the exact old score so
        // single-source or all-smooth regions never become holes.
        deghost_weight(ownership, max_ownership, source_min_dimension)
    }
}

#[cfg(test)]
fn deghost_source_weight(
    ownership: f64,
    max_ownership: f64,
    max_uncapped_ownership: f64,
    max_cap_eligible_ownership: f64,
    max_structured_peer_texture: f64,
    obstruction_confidence: f64,
    texture_energy: f64,
    source_min_dimension: u32,
) -> f64 {
    deghost_source_weight_with_sharpness(
        ownership,
        max_ownership,
        max_uncapped_ownership,
        max_cap_eligible_ownership,
        max_structured_peer_texture,
        obstruction_confidence,
        texture_energy,
        0.0,
        0.0,
        source_min_dimension,
    )
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
    mut checkpoint: impl FnMut(u64, u64) -> bool,
    sharpness_aware: bool,
) -> crate::Result<Value> {
    if !(32..=4096).contains(&memory_budget_mib) {
        return Err(crate::Error::Invalid(
            "memoryBudgetMiB must be 32..=4096".into(),
        ));
    }
    if !(1..=32).contains(&workers_requested) {
        return Err(crate::Error::Invalid("workers must be 1..=32".into()));
    }
    let (width, height, bounds, sources, blend_mode) = dimensions(layout)?;
    validate_or_write_renderer_identity(output, blend_mode)?;
    let dir = output.join("level-0");
    fs::create_dir_all(&dir)?;
    let cols = width.div_ceil(TILE);
    let rows = height.div_ceil(TILE);
    let total = u64::from(cols) * u64::from(rows);
    let mut completed = 0u64;
    let started = Instant::now();
    let budget_bytes = (memory_budget_mib as u64) * 1024 * 1024;
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
        let bytes = u64::from(iw) * u64::from(ih) * 4;
        source_bytes.push(bytes);
        max_decode = max_decode.max(bytes.saturating_mul(2));
    }
    let tile_bytes_per_pixel = if blend_mode == BlendMode::Deghost {
        // accum[4] (16 bytes) + global, uncapped, and cap-eligible ownership
        // (12 bytes) + local peer texture and sharpness (2 bytes), plus Vec overhead.
        34
    } else {
        24
    };
    let tile_reserve = u64::from(TILE) * u64::from(TILE) * tile_bytes_per_pixel;
    let source_quality_map_reserve = if blend_mode == BlendMode::Deghost {
        sources.len() as u64
            * (SourceQualityMap::byte_len()
                + std::mem::size_of::<SourceQualityMap>() as u64
                + std::mem::size_of::<Arc<SourceQualityMap>>() as u64)
    } else {
        0
    };
    let source_quality_refs_per_worker = if blend_mode == BlendMode::Deghost {
        sources.len() as u64 * std::mem::size_of::<Option<Arc<SourceQualityMap>>>() as u64
    } else {
        0
    };
    let one_worker = tile_reserve + max_decode / 2 + source_quality_refs_per_worker;
    if one_worker + max_decode / 2 + source_quality_map_reserve > budget_bytes {
        return Err(crate::Error::Invalid(format!(
            "one tile worker and source decode exceed memoryBudgetMiB={memory_budget_mib}"
        )));
    }
    let affordable =
        ((budget_bytes - max_decode / 2 - source_quality_map_reserve) / one_worker).max(1) as usize;
    let effective_workers = workers_requested.min(affordable).min(total as usize).max(1);
    let active_reserve =
        one_worker * effective_workers as u64 + max_decode / 2 + source_quality_map_reserve;
    let cache_limit = if use_source_cache {
        budget_bytes.saturating_sub(active_reserve)
    } else {
        0
    };
    let cache = Arc::new(Mutex::new(DecodeCache::new(cache_limit)));
    let hits = AtomicU64::new(0);
    let misses = AtomicU64::new(0);
    let visits = AtomicU64::new(0);
    let active_workers = AtomicU64::new(0);
    let peak_workers = AtomicU64::new(0);
    let decode_micros = AtomicU64::new(0);
    let encode_micros = AtomicU64::new(0);
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
    for batch in tasks.chunks(effective_workers) {
        if !checkpoint(completed, total) {
            return Err(crate::Error::Cancelled);
        }
        let results = std::thread::scope(|scope| {
            let mut joins = Vec::new();
            for &(row, col) in batch {
                let cache = cache.clone();
                let hits = &hits;
                let misses = &misses;
                let visits = &visits;
                let active_workers = &active_workers;
                let peak_workers = &peak_workers;
                let decode_micros = &decode_micros;
                let encode_micros = &encode_micros;
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
                        &visits,
                        &active_workers,
                        &peak_workers,
                        &decode_micros,
                        &encode_micros,
                        use_source_cache,
                        blend_mode,
                        sharpness_aware,
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
    let cache_guard = cache.lock().expect("decode cache lock");
    let render_ms = started.elapsed().as_secs_f64() * 1000.0;
    Ok(
        serde_json::json!({"width":width,"height":height,"tileSize":TILE,"tileBytesPerPixelReserved":tile_bytes_per_pixel,"rows":rows,"columns":cols,"completedTiles":completed,"backend":"cpu-rust-tiled","blendModel":blend_mode.model_name(),"workersRequested":workers_requested,"workersEffective":effective_workers,"peakConcurrentWorkers":peak_workers.load(Ordering::Relaxed),"workers":effective_workers,"sourceCacheEnabled":use_source_cache,"sourceCacheLimitBytes":cache_limit,"peakSourceCacheBytes":cache_guard.peak_bytes,"sourceQualityMapBytesReserved":source_quality_map_reserve,"sourceQualityMapRefsPerWorkerBytesReserved":source_quality_refs_per_worker,"estimatedActiveMemoryBytes":active_reserve+cache_guard.peak_bytes,"memoryAccounting":"conservativeEstimate","sourceCacheHits":hits.load(Ordering::Relaxed),"sourceCacheMisses":misses.load(Ordering::Relaxed),"sourceDecodes":misses.load(Ordering::Relaxed),"sourceDecodeMs":decode_micros.load(Ordering::Relaxed) as f64/1000.0,"tileEncodeMs":encode_micros.load(Ordering::Relaxed) as f64/1000.0,"sourceCandidateVisits":visits.load(Ordering::Relaxed),"renderMs":render_ms}),
    )
}

struct DecodeCache {
    map: HashMap<usize, Arc<RgbaImage>>,
    lru: VecDeque<usize>,
    bytes: u64,
    limit: u64,
    peak_bytes: u64,
}
impl DecodeCache {
    fn new(limit: u64) -> Self {
        Self {
            map: HashMap::new(),
            lru: VecDeque::new(),
            bytes: 0,
            limit,
            peak_bytes: 0,
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn source_image(
    source_index: usize,
    source: &Source,
    source_bytes: &[u64],
    cache: &Mutex<DecodeCache>,
    hits: &AtomicU64,
    misses: &AtomicU64,
    decode_micros: &AtomicU64,
    use_cache: bool,
) -> crate::Result<Arc<RgbaImage>> {
    let mut state = cache.lock().expect("decode cache lock");
    if let Some(image) = state.map.get(&source_index).cloned() {
        hits.fetch_add(1, Ordering::Relaxed);
        if let Some(pos) = state.lru.iter().position(|index| *index == source_index) {
            state.lru.remove(pos);
        }
        state.lru.push_back(source_index);
        return Ok(image);
    }
    misses.fetch_add(1, Ordering::Relaxed);
    let decode_started = Instant::now();
    let image = Arc::new(image::open(&source.path)?.into_rgba8());
    decode_micros.fetch_add(
        decode_started.elapsed().as_micros() as u64,
        Ordering::Relaxed,
    );
    if image.width() != source.width || image.height() != source.height {
        return Err(crate::Error::Invalid(format!(
            "source dimensions changed for {}",
            source.path.display()
        )));
    }
    if use_cache && state.limit > 0 && source_bytes[source_index] <= state.limit {
        while state.bytes + source_bytes[source_index] > state.limit {
            if let Some(old) = state.lru.pop_front() {
                if let Some(old_image) = state.map.remove(&old) {
                    state.bytes -= u64::from(old_image.width()) * u64::from(old_image.height()) * 4;
                }
            } else {
                break;
            }
        }
        state.bytes += u64::from(image.width()) * u64::from(image.height()) * 4;
        state.peak_bytes = state.peak_bytes.max(state.bytes);
        state.map.insert(source_index, image.clone());
        state.lru.push_back(source_index);
    }
    Ok(image)
}

#[allow(clippy::too_many_arguments)]
fn source_quality_map(
    source_index: usize,
    source: &Source,
    source_bytes: &[u64],
    cache: &Mutex<DecodeCache>,
    hits: &AtomicU64,
    misses: &AtomicU64,
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
    cache: &Mutex<DecodeCache>,
    hits: &AtomicU64,
    misses: &AtomicU64,
    visits: &AtomicU64,
    active_workers: &AtomicU64,
    peak_workers: &AtomicU64,
    decode_micros: &AtomicU64,
    encode_micros: &AtomicU64,
    use_cache: bool,
    blend_mode: BlendMode,
    sharpness_aware: bool,
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
    let mut max_ownership =
        (blend_mode == BlendMode::Deghost).then(|| vec![f32::NEG_INFINITY; count]);
    let mut max_unflagged_ownership =
        (blend_mode == BlendMode::Deghost).then(|| vec![f32::NEG_INFINITY; count]);
    let mut max_cap_eligible_ownership =
        (blend_mode == BlendMode::Deghost).then(|| vec![f32::NEG_INFINITY; count]);
    let mut max_structured_peer_texture =
        (blend_mode == BlendMode::Deghost).then(|| vec![0u8; count]);
    let mut max_peer_sharpness = (blend_mode == BlendMode::Deghost).then(|| vec![0u8; count]);
    let mut source_quality_maps = vec![None; sources.len()];
    if let Some(scores) = max_ownership.as_mut() {
        for (source_index, source) in sources.iter().enumerate() {
            if !candidate(source, bounds, left, top, tw, th, width, height) {
                continue;
            }
            let quality = source_quality_map(
                source_index,
                source,
                source_bytes,
                cache,
                hits,
                misses,
                decode_micros,
                use_cache,
            )?;
            source_quality_maps[source_index] = Some(quality.clone());
            for py in 0..th {
                for px in 0..tw {
                    let (sy, cy) = x_rays[px as usize];
                    let (sp, cp) = y_rays[py as usize];
                    let world = [sy * cp, sp, cy * cp];
                    if let Some((source_x, source_y, _, ownership)) = sample_geometry(source, world)
                    {
                        let index = (py * tw + px) as usize;
                        scores[index] = scores[index].max(ownership as f32);
                        let (texture_energy, _) =
                            quality.sample(source.width, source.height, source_x, source_y);
                        let sharpness =
                            quality.sharpness(source.width, source.height, source_x, source_y);
                        if texture_energy >= SOURCE_QUALITY_STRUCTURED_PEER_TEXTURE {
                            let peer_texture =
                                &mut max_structured_peer_texture.as_mut().unwrap()[index];
                            *peer_texture =
                                (*peer_texture).max(texture_energy.round().clamp(0.0, 255.0) as u8);
                            let peer_sharpness = &mut max_peer_sharpness.as_mut().unwrap()[index];
                            *peer_sharpness =
                                (*peer_sharpness).max(sharpness.round().clamp(0.0, 255.0) as u8);
                        }
                    }
                }
            }
        }
        // Classify sources only after the per-pixel peer sharpness is known.
        // This makes the decision independent of source order and compares
        // local texture at the same projected scene point, rather than a
        // whole-image sharpness score.
        for (source_index, source) in sources.iter().enumerate() {
            if !candidate(source, bounds, left, top, tw, th, width, height) {
                continue;
            }
            let quality = source_quality_maps[source_index]
                .as_ref()
                .expect("quality map prepared in geometry pass");
            for py in 0..th {
                for px in 0..tw {
                    let (sy, cy) = x_rays[px as usize];
                    let (sp, cp) = y_rays[py as usize];
                    let world = [sy * cp, sp, cy * cp];
                    if let Some((source_x, source_y, _, ownership)) = sample_geometry(source, world)
                    {
                        let index = (py * tw + px) as usize;
                        let (texture_energy, obstruction_confidence) =
                            quality.sample(source.width, source.height, source_x, source_y);
                        let sharpness =
                            quality.sharpness(source.width, source.height, source_x, source_y);
                        let peer_texture =
                            f64::from(max_structured_peer_texture.as_ref().unwrap()[index]);
                        let peer_sharp = f64::from(max_peer_sharpness.as_ref().unwrap()[index]);
                        let blurred_against_peer = sharpness_aware
                            && peer_texture >= SOURCE_QUALITY_BLUR_PEER_TEXTURE
                            && peer_sharp >= SOURCE_QUALITY_BLUR_PEER_SHARPNESS
                            && sharpness <= peer_sharp * SOURCE_QUALITY_BLUR_RELATIVE_MAX;
                        let obstructed = obstruction_confidence
                            >= SOURCE_QUALITY_SUSPECT_CONFIDENCE
                            && texture_energy <= SOURCE_QUALITY_LOW_TEXTURE_MAX;
                        if blurred_against_peer || obstructed {
                            let eligible_scores = max_cap_eligible_ownership.as_mut().unwrap();
                            eligible_scores[index] = eligible_scores[index].max(ownership as f32);
                        } else {
                            let clean_scores = max_unflagged_ownership.as_mut().unwrap();
                            clean_scores[index] = clean_scores[index].max(ownership as f32);
                        }
                    }
                }
            }
        }
    }
    for (source_index, source) in sources.iter().enumerate() {
        if !candidate(source, bounds, left, top, tw, th, width, height) {
            continue;
        }
        visits.fetch_add(1, Ordering::Relaxed);
        let image = source_image(
            source_index,
            source,
            source_bytes,
            cache,
            hits,
            misses,
            decode_micros,
            use_cache,
        )?;
        for py in 0..th {
            for px in 0..tw {
                let (sy, cy) = x_rays[px as usize];
                let (sp, cp) = y_rays[py as usize];
                let world = [sy * cp, sp, cy * cp];
                if let Some((rgb, weight, ownership, x, y)) = sample(source, &image, world) {
                    let cell = &mut accum[(py * tw + px) as usize];
                    let blend_weight = match blend_mode {
                        BlendMode::Feather => weight,
                        BlendMode::Deghost => {
                            let index = (py * tw + px) as usize;
                            let quality = source_quality_maps[source_index]
                                .as_ref()
                                .expect("deghost quality map prepared in geometry pass");
                            let (texture_energy, obstruction_confidence) =
                                quality.sample(source.width, source.height, x, y);
                            let sharpness = quality.sharpness(source.width, source.height, x, y);
                            deghost_source_weight_with_sharpness(
                                ownership,
                                f64::from(max_ownership.as_ref().unwrap()[index]),
                                f64::from(max_unflagged_ownership.as_ref().unwrap()[index]),
                                f64::from(max_cap_eligible_ownership.as_ref().unwrap()[index]),
                                f64::from(max_structured_peer_texture.as_ref().unwrap()[index]),
                                obstruction_confidence,
                                texture_energy,
                                sharpness,
                                if sharpness_aware {
                                    f64::from(max_peer_sharpness.as_ref().unwrap()[index])
                                } else {
                                    0.0
                                },
                                source.width.min(source.height),
                            )
                        }
                    };
                    accumulate_weighted(cell, rgb, blend_weight);
                }
            }
        }
    }
    let mut tile: RgbaImage = ImageBuffer::from_pixel(tw, th, Rgba([0, 0, 0, 0]));
    for py in 0..th {
        for px in 0..tw {
            let cell = accum[(py * tw + px) as usize];
            if cell[3] > 0. {
                tile.put_pixel(
                    px,
                    py,
                    Rgba([
                        srgb(f64::from(cell[0] / cell[3])),
                        srgb(f64::from(cell[1] / cell[3])),
                        srgb(f64::from(cell[2] / cell[3])),
                        255,
                    ]),
                );
            }
        }
    }
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
    if !(32..=4096).contains(&memory_budget_mib) {
        return Err(crate::Error::Invalid(
            "memoryBudgetMiB must be 32..=4096".into(),
        ));
    }
    if !(1..=32).contains(&workers_requested) {
        return Err(crate::Error::Invalid("workers must be 1..=32".into()));
    }
    const WORKER_RESERVE_BYTES: u64 = 16 * 1024 * 1024;
    let memory_workers =
        ((memory_budget_mib as u64 * 1024 * 1024) / WORKER_RESERVE_BYTES).max(1) as usize;
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
    use std::time::{SystemTime, UNIX_EPOCH};

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
        let legacy_weight = deghost_weight(550. / 2160., 550. / 2160., 2160);
        let weak_evidence_weight = deghost_source_weight(
            550. / 2160.,
            550. / 2160.,
            550. / 2160.,
            f64::NEG_INFINITY,
            10.,
            moderate_confidence,
            moderate_texture,
            2160,
        );
        assert_eq!(weak_evidence_weight, legacy_weight);

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
        let single_blur_is_cap_eligible =
            single_blur_sharpness <= single_crisp_sharpness * SOURCE_QUALITY_BLUR_RELATIVE_MAX;
        let single_blur_weight = deghost_source_weight_with_sharpness(
            0.35,
            0.35,
            if single_blur_is_cap_eligible {
                0.25
            } else {
                0.35
            },
            if single_blur_is_cap_eligible {
                0.35
            } else {
                f64::NEG_INFINITY
            },
            single_crisp_texture,
            0.0,
            single_blur_texture,
            single_blur_sharpness,
            single_crisp_sharpness,
            2160,
        );
        if !single_blur_is_cap_eligible {
            assert_eq!(single_blur_weight, 1.0);
        } else {
            assert!(single_blur_weight < 1.0);
        }

        let flat = RgbaImage::from_pixel(WIDTH, HEIGHT, Rgba([128, 128, 128, 255]));
        let flat_map = SourceQualityMap::from_image(&flat);
        let (flat_texture, _) = flat_map.sample(WIDTH, HEIGHT, 1024.0, 576.0);
        let flat_sharpness = flat_map.sharpness(WIDTH, HEIGHT, 1024.0, 576.0);
        assert!(flat_texture < SOURCE_QUALITY_BLUR_PEER_TEXTURE);
        let flat_weight = deghost_source_weight_with_sharpness(
            0.3,
            0.35,
            0.25,
            0.3,
            flat_texture,
            0.0,
            flat_texture,
            flat_sharpness,
            crisp_sharpness,
            2160,
        );
        assert_eq!(flat_weight, deghost_weight(0.3, 0.35, 2160));

        let blurred_weight = deghost_source_weight_with_sharpness(
            0.35,
            0.35,
            0.25,
            0.35,
            crisp_texture,
            0.0,
            blurred_texture,
            blurred_sharpness,
            crisp_sharpness,
            2160,
        );
        let crisp_weight = deghost_source_weight_with_sharpness(
            0.25,
            0.35,
            0.25,
            0.35,
            crisp_texture,
            0.0,
            crisp_texture,
            crisp_sharpness,
            crisp_sharpness,
            2160,
        );
        assert!(blurred_weight < 0.001);
        assert_eq!(crisp_weight, 1.0);
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
            32,
            1,
            true,
            checkpoint,
            false,
        )
        .unwrap();
        render_layout_tiles_with_options_internal(
            &layout, &sharp_dir, 32, 1, true, checkpoint, true,
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

        let corrected_obstruction_weight = deghost_source_weight(
            obstructed_ownership,
            obstructed_ownership,
            clean_ownership,
            obstructed_ownership,
            10.,
            0.9,
            0.0,
            2160,
        );
        let clean_peer_weight = deghost_source_weight(
            clean_ownership,
            obstructed_ownership,
            clean_ownership,
            obstructed_ownership,
            10.,
            0.0,
            10.0,
            2160,
        );
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

        let no_peer_weight = deghost_source_weight(
            obstructed_ownership,
            obstructed_ownership,
            f64::NEG_INFINITY,
            obstructed_ownership,
            0.,
            0.9,
            0.0,
            2160,
        );
        assert_eq!(no_peer_weight, old_obstruction_weight);
        let smooth_sky_peer_weight = deghost_source_weight(
            obstructed_ownership,
            obstructed_ownership,
            clean_ownership,
            obstructed_ownership,
            SOURCE_QUALITY_STRUCTURED_PEER_TEXTURE - 1.,
            0.9,
            0.0,
            2160,
        );
        assert_eq!(smooth_sky_peer_weight, old_obstruction_weight);

        // A high-confidence sample interpolated across a textured boundary
        // is not eligible for capping and must be included in the common
        // reference. This guards against an invalid negative denominator
        // exponent becoming an overflow or NaN.
        let uncapped_boundary_weight = deghost_source_weight(
            0.30,
            0.35,
            0.30,
            0.35,
            10.,
            0.9,
            SOURCE_QUALITY_LOW_TEXTURE_MAX + 0.1,
            2160,
        );
        assert!(uncapped_boundary_weight.is_finite());
        assert_eq!(uncapped_boundary_weight, 1.0);
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
        let bad_weight = deghost_source_weight(
            bad_geometry.3,
            max_ownership,
            good_geometry.3,
            bad_geometry.3,
            good_texture,
            confidence,
            bad_texture,
            2160,
        );
        let good_weight = deghost_source_weight(
            good_geometry.3,
            max_ownership,
            good_geometry.3,
            bad_geometry.3,
            good_texture,
            good_confidence,
            good_texture,
            2160,
        );
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
            let only_source_weight =
                deghost_source_weight(0.25, 0.25, f64::NEG_INFINITY, 0.25, 0.0, 0.95, 0.0, 2160);
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

        let mut deghost_layout = layout.clone();
        deghost_layout["renderBlendMode"] = serde_json::json!("deghost");
        let deghost_serial_dir = root.join("deghost-serial");
        let deghost_parallel_dir = root.join("deghost-parallel");
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
        assert_eq!(serial["blendModel"], "source-edge-smoothstep-feather");
        assert_eq!(
            deghost_serial["blendModel"],
            "sharpness-aware-max-score-softmax-ownership"
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
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn deghost_multi_source_is_stable_across_order_workers_and_tile_boundary() {
        let root = std::env::temp_dir().join(format!(
            "lumia-deghost-order-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let colors = [
            [0, 0, 0, 255],
            [64, 64, 64, 255],
            [192, 192, 192, 255],
            [255, 255, 255, 255],
        ];
        let mut tiles = Vec::new();
        for (index, color) in colors.iter().enumerate() {
            let path = root.join(format!("source-{index}.png"));
            RgbaImage::from_pixel(320, 320, Rgba(*color))
                .save(&path)
                .unwrap();
            tiles.push(serde_json::json!({
                "path":path.to_string_lossy(),"width":320,"height":320,
                "fx":100.0,"fy":100.0,"cx":159.5,"cy":159.5,
                "cameraToWorld":[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]
            }));
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
        assert_eq!(
            original["blendModel"],
            "sharpness-aware-max-score-softmax-ownership"
        );
        assert!(parallel["workersEffective"].as_u64().unwrap() > 1);
        assert_eq!(original["completedTiles"], reversed["completedTiles"]);
        assert_eq!(original["completedTiles"], parallel["completedTiles"]);
        for col in 0..3 {
            let name = format!("level-0/0-{col}.png");
            let original_bytes = fs::read(original_dir.join(&name)).unwrap();
            assert_eq!(original_bytes, fs::read(reversed_dir.join(&name)).unwrap());
            assert_eq!(original_bytes, fs::read(parallel_dir.join(&name)).unwrap());
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
