use super::{CancellationToken, Progress, ProjectiveTransform, Registration};
use crate::{
    image,
    metadata::{CaptureTile, StitchReport},
    Result,
};
use ::image::RgbaImage;
use std::time::Instant;
use std::{
    io::{BufWriter, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// An optional caller-owned RGBA overlay rendered at the output's bottom-right.
/// Core does not embed application branding or watermarks.
#[derive(Clone, Debug)]
pub struct OutputOverlay {
    pub image: RgbaImage,
    pub margin_x: u32,
    pub margin_y: u32,
}

impl OutputOverlay {
    pub fn new(image: RgbaImage) -> Self {
        Self {
            image,
            margin_x: 0,
            margin_y: 0,
        }
    }
}

pub(crate) struct RenderConfig<'a> {
    pub band_height: u32,
    pub blend_power: u32,
    pub overlay: Option<&'a OutputOverlay>,
}

/// Full-resolution renderer using disk-spooled RGB tiles and streamed PNG rows.
pub fn render_banded<F: FnMut(Progress)>(
    tiles: &[CaptureTile],
    reg: &Registration,
    band: u32,
    out: &Path,
    cancel: &CancellationToken,
    cb: &mut F,
) -> Result<(StitchReport, u32, u32)> {
    render_banded_with_overlay(tiles, reg, band, out, cancel, None, cb)
}

/// Render with an optional caller-owned overlay. Source alpha is a geometric
/// validity mask: only samples with alpha >= 254 participate in feathering.
pub fn render_banded_with_overlay<F: FnMut(Progress)>(
    tiles: &[CaptureTile],
    reg: &Registration,
    band: u32,
    out: &Path,
    cancel: &CancellationToken,
    overlay: Option<&OutputOverlay>,
    cb: &mut F,
) -> Result<(StitchReport, u32, u32)> {
    render_banded_configured(
        tiles,
        reg,
        RenderConfig {
            band_height: band,
            blend_power: 12,
            overlay,
        },
        out,
        cancel,
        cb,
    )
}

pub(crate) fn render_banded_configured<F: FnMut(Progress)>(
    tiles: &[CaptureTile],
    reg: &Registration,
    config: RenderConfig<'_>,
    out: &Path,
    cancel: &CancellationToken,
    cb: &mut F,
) -> Result<(StitchReport, u32, u32)> {
    let started = Instant::now();
    if tiles.is_empty() {
        return Err(crate::Error::Invalid("no tiles".into()));
    }
    if !out
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("png"))
    {
        return Err(crate::Error::Invalid(
            "banded renderer requires a PNG destination".into(),
        ));
    }
    if out.exists() {
        return Err(crate::Error::Invalid(
            "refusing to overwrite an existing panorama".into(),
        ));
    }
    let root = out.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(root)?;
    let scratch_path = root.join(format!(
        ".lumia-render-{}-{}",
        std::process::id(),
        unique_suffix()
    ));
    std::fs::create_dir(&scratch_path)?;
    let _scratch = TempDir(scratch_path.clone());
    let mut dims = Vec::with_capacity(tiles.len());
    let mut raw_paths = Vec::with_capacity(tiles.len());
    let mut mask_paths = Vec::with_capacity(tiles.len());
    for (i, tile) in tiles.iter().enumerate() {
        if cancel.is_cancelled() {
            return Err(crate::Error::Cancelled);
        }
        let source = image::load(&tile.path)?;
        let (tw, th) = (source.width(), source.height());
        let raw_path = scratch_path.join(format!("tile-{i}.rgb"));
        let mask_path = scratch_path.join(format!("tile-{i}.mask"));
        let file = std::fs::File::create(&raw_path)?;
        let mask_file = std::fs::File::create(&mask_path)?;
        let mut raw = BufWriter::new(file);
        let mut mask = BufWriter::new(mask_file);
        for y in 0..th {
            for x in 0..tw {
                let p = source.get_pixel(x, y);
                raw.write_all(&p.0[..3])?;
                mask.write_all(&[p.0[3]])?;
            }
        }
        raw.flush()?;
        mask.flush()?;
        dims.push((tw, th));
        raw_paths.push(raw_path);
        mask_paths.push(mask_path);
        cb(Progress {
            stage: "source_spool".into(),
            fraction: 0.35 * (i + 1) as f32 / tiles.len() as f32,
        });
    }
    let mut min_x = 0.0f64;
    let mut min_y = 0.0f64;
    let mut max_x = 0.0f64;
    let mut max_y = 0.0f64;
    let mut tile_bounds = Vec::with_capacity(dims.len());
    for (i, &(tw, th)) in dims.iter().enumerate() {
        let transform = tile_transform(reg, i);
        let corners = [
            (0.0, 0.0),
            (tw as f64, 0.0),
            (tw as f64, th as f64),
            (0.0, th as f64),
        ]
        .map(|(x, y)| transform.transform_point(x, y))
        .into_iter()
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| crate::Error::Invalid(format!("tile {i} has an invalid transform")))?;
        let left = corners
            .iter()
            .map(|point| point.0)
            .fold(f64::INFINITY, f64::min);
        let top = corners
            .iter()
            .map(|point| point.1)
            .fold(f64::INFINITY, f64::min);
        let right = corners
            .iter()
            .map(|point| point.0)
            .fold(f64::NEG_INFINITY, f64::max);
        let bottom = corners
            .iter()
            .map(|point| point.1)
            .fold(f64::NEG_INFINITY, f64::max);
        min_x = min_x.min(left.floor());
        min_y = min_y.min(top.floor());
        max_x = max_x.max(right.ceil());
        max_y = max_y.max(bottom.ceil());
        tile_bounds.push((left, top, right, bottom));
    }
    let width_span = max_x - min_x;
    let height_span = max_y - min_y;
    let width = width_span
        .is_finite()
        .then_some(width_span)
        .filter(|v| *v > 0.0 && *v <= 250_000.0)
        .ok_or_else(|| crate::Error::Invalid("implausible panorama width".into()))?
        .ceil() as u32;
    let height = height_span
        .is_finite()
        .then_some(height_span)
        .filter(|v| *v > 0.0 && *v <= 250_000.0)
        .ok_or_else(|| crate::Error::Invalid("implausible panorama height".into()))?
        .ceil() as u32;
    let temporary = scratch_path.join("panorama.png");
    let mut enc = png::Encoder::new(std::fs::File::create(&temporary)?, width, height);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc
        .write_header()
        .map_err(|e| crate::Error::Invalid(format!("PNG header failed: {e}")))?;
    let mut stream = writer
        .stream_writer()
        .map_err(|e| crate::Error::Invalid(format!("PNG stream failed: {e}")))?;
    let bh = config
        .band_height
        .max(1)
        .min((2_000_000u32 / width.max(1)).clamp(1, 32)) as usize;
    let mut covered_pixels = 0u64;
    for y0 in (0..height as usize).step_by(bh) {
        if cancel.is_cancelled() {
            return Err(crate::Error::Cancelled);
        }
        let rows = bh.min(height as usize - y0);
        let count = width as usize * rows;
        let mut sum = vec![[0f32; 3]; count];
        let mut weights = vec![0f32; count];
        for (i, raw_path) in raw_paths.iter().enumerate() {
            let (tw, th) = dims[i];
            let (left, top, right, bottom) = tile_bounds[i];
            let first_y = y0.max((top - min_y).floor().max(0.0) as usize);
            let last_y = (y0 + rows).min((bottom - min_y).ceil().max(0.0) as usize);
            if first_y >= last_y {
                continue;
            }
            let first_x = (left - min_x).floor().max(0.0) as usize;
            let last_x = (right - min_x).ceil().max(0.0).min(width as f64) as usize;
            let inverse = tile_transform(reg, i)
                .inverse()
                .ok_or_else(|| crate::Error::Invalid(format!("tile {i} transform is singular")))?;
            let source_band_corners = [
                (first_x as f64 + min_x, first_y as f64 + min_y),
                (last_x as f64 + min_x, first_y as f64 + min_y),
                (last_x as f64 + min_x, last_y as f64 + min_y),
                (first_x as f64 + min_x, last_y as f64 + min_y),
            ]
            .map(|(x, y)| inverse.transform_point(x, y))
            .into_iter()
            .collect::<Option<Vec<_>>>();
            let Some(source_band_corners) = source_band_corners else {
                continue;
            };
            let source_min_y = source_band_corners
                .iter()
                .map(|point| point.1)
                .fold(f64::INFINITY, f64::min);
            let source_max_y = source_band_corners
                .iter()
                .map(|point| point.1)
                .fold(f64::NEG_INFINITY, f64::max);
            let source_first_y = (source_min_y.floor() - 1.0).clamp(0.0, th as f64) as u32;
            let source_last_y = (source_max_y.ceil() + 1.0).clamp(0.0, th as f64) as u32;
            if source_first_y >= source_last_y {
                continue;
            }
            let source_rows = source_last_y - source_first_y;
            let mut raw = std::fs::File::open(raw_path)?;
            raw.seek(SeekFrom::Start(
                u64::from(source_first_y) * u64::from(tw) * 3,
            ))?;
            let mut bytes = vec![0; source_rows as usize * tw as usize * 3];
            raw.read_exact(&mut bytes)?;
            let mut mask = std::fs::File::open(&mask_paths[i])?;
            mask.seek(SeekFrom::Start(u64::from(source_first_y) * u64::from(tw)))?;
            let mut valid = vec![0; source_rows as usize * tw as usize];
            mask.read_exact(&mut valid)?;
            let feather = 8.0f32.max(tw.min(th) as f32 * 0.45);
            for y in first_y..last_y {
                for x in first_x..last_x {
                    let Some((sx, sy)) =
                        inverse.transform_point(x as f64 + min_x, y as f64 + min_y)
                    else {
                        continue;
                    };
                    let Some((color, alpha)) = bilinear_sample(
                        &bytes,
                        &valid,
                        (tw, th),
                        (source_first_y, source_rows),
                        sx,
                        sy,
                    ) else {
                        continue;
                    };
                    let distance = (sx + 1.0)
                        .min(tw as f64 - sx)
                        .min((sy + 1.0).min(th as f64 - sy))
                        .max(0.0) as f32;
                    let weight = 0.002f32.max(1.0f32.min(distance / feather)) * alpha;
                    // A high-order feather keeps the ownership field spatially
                    // smooth while narrowing the transition between sources.
                    // Linear weights average parallax over hundreds of pixels;
                    // hard winner selection removes ghosts but exposes polygon
                    // boundaries. Raising both weights preserves a continuous
                    // seam and strongly favors the source farther from an edge.
                    let blend_weight = weight.powi(config.blend_power.clamp(1, 32) as i32);
                    let d = (y - y0) * width as usize + x;
                    for c in 0..3 {
                        sum[d][c] += color[c] * blend_weight;
                    }
                    weights[d] += blend_weight;
                }
            }
        }
        for row in 0..rows {
            let y = y0 + row;
            let mut encoded = vec![0u8; width as usize * 3];
            for x in 0..width as usize {
                let d = row * width as usize + x;
                if weights[d] > 0.0 {
                    covered_pixels += 1;
                    for c in 0..3 {
                        encoded[x * 3 + c] =
                            (sum[d][c] / weights[d]).round().clamp(0.0, 255.0) as u8;
                    }
                }
            }
            apply_overlay_row(&mut encoded, width as usize, y as u32, config.overlay);
            stream.write_all(&encoded)?;
        }
        cb(Progress {
            stage: "render".into(),
            fraction: 0.35 + 0.65 * ((y0 + rows) as f32 / height as f32),
        });
    }
    stream
        .finish()
        .map_err(|e| crate::Error::Invalid(format!("PNG finish failed: {e}")))?;
    drop(writer);
    publish_output(&temporary, out)?;
    let total_pixels = u64::from(width) * u64::from(height);
    let coverage = if total_pixels == 0 {
        0.0
    } else {
        covered_pixels as f64 / total_pixels as f64
    };
    let mut report = reg.report.clone();
    report.coverage = coverage;
    report.transparent_gap_ratio = 1.0 - coverage;
    report.render_duration_ms = started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64;
    report.output_width = width;
    report.output_height = height;
    Ok((report, width, height))
}

fn tile_transform(registration: &Registration, index: usize) -> ProjectiveTransform {
    registration
        .transforms
        .get(index)
        .copied()
        .unwrap_or_else(|| {
            registration
                .offsets
                .get(index)
                .map(|offset| ProjectiveTransform::translation(offset.x as f64, offset.y as f64))
                .unwrap_or(ProjectiveTransform::IDENTITY)
        })
}

fn publish_output(temporary: &Path, output: &Path) -> std::io::Result<()> {
    let mut last_error = None;
    for attempt in 0..5 {
        match std::fs::rename(temporary, output) {
            Ok(()) => return Ok(()),
            Err(error)
                if cfg!(windows)
                    && error.kind() == std::io::ErrorKind::PermissionDenied
                    && attempt < 4 =>
            {
                last_error = Some(error);
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(error) => return Err(error),
        }
    }
    Err(last_error.unwrap_or_else(|| std::io::Error::other("failed to publish panorama")))
}

fn bilinear_sample(
    rgb: &[u8],
    mask: &[u8],
    dimensions: (u32, u32),
    row_window: (u32, u32),
    x: f64,
    y: f64,
) -> Option<([f32; 3], f32)> {
    let (width, height) = dimensions;
    let (first_row, row_count) = row_window;
    if !x.is_finite()
        || !y.is_finite()
        || x < 0.0
        || y < 0.0
        || x > f64::from(width.saturating_sub(1))
        || y > f64::from(height.saturating_sub(1))
        || y < f64::from(first_row)
        || y > f64::from(first_row + row_count - 1)
    {
        return None;
    }
    let x0 = x.floor() as u32;
    let y0 = y.floor() as u32;
    let x1 = (x0 + 1).min(width - 1);
    let y1 = (y0 + 1).min(height - 1);
    let fx = (x - f64::from(x0)) as f32;
    let fy = (y - f64::from(y0)) as f32;
    let samples = [
        (x0, y0, (1.0 - fx) * (1.0 - fy)),
        (x1, y0, fx * (1.0 - fy)),
        (x0, y1, (1.0 - fx) * fy),
        (x1, y1, fx * fy),
    ];
    let mut color = [0.0f32; 3];
    let mut alpha = 0.0f32;
    for (sx, sy, spatial_weight) in samples {
        let pixel = (sy - first_row) as usize * width as usize + sx as usize;
        let validity = if mask.get(pixel).copied().unwrap_or(0) >= 254 {
            1.0
        } else {
            0.0
        };
        let weight = spatial_weight * validity;
        alpha += weight;
        for (channel, value) in color.iter_mut().enumerate() {
            *value += rgb.get(pixel * 3 + channel).copied().unwrap_or(0) as f32 * weight;
        }
    }
    if alpha <= 1e-6 {
        None
    } else {
        for channel in &mut color {
            *channel /= alpha;
        }
        Some((color, alpha))
    }
}

fn apply_overlay_row(row: &mut [u8], output_width: usize, y: u32, overlay: Option<&OutputOverlay>) {
    let Some(overlay) = overlay else {
        return;
    };
    let image = &overlay.image;
    if image.width() == 0 || image.height() == 0 || y + overlay.margin_y < image.height() {
        return;
    }
    let top = y
        .saturating_add(1)
        .saturating_sub(image.height())
        .saturating_sub(overlay.margin_y);
    if y < top || y - top >= image.height() {
        return;
    }
    let left = (output_width as u32)
        .saturating_sub(image.width())
        .saturating_sub(overlay.margin_x);
    let overlay_y = y - top;
    for overlay_x in 0..image.width() {
        let x = left + overlay_x;
        if x >= output_width as u32 {
            continue;
        }
        let source = image.get_pixel(overlay_x, overlay_y).0;
        if source[3] == 0 {
            continue;
        }
        let alpha = source[3] as u32;
        let index = x as usize * 3;
        for channel in 0..3 {
            row[index + channel] = ((source[channel] as u32 * alpha
                + row[index + channel] as u32 * (255 - alpha)
                + 127)
                / 255) as u8;
        }
    }
}

fn unique_suffix() -> u128 {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    time.wrapping_mul(1_000_000).wrapping_add(u128::from(
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metadata::{CaptureTile, StitchOptions};
    use ::image::{GenericImageView, Rgba, RgbaImage};

    fn fixture(name: &str, color: [u8; 4]) -> (std::path::PathBuf, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "lumia-render-test-{}-{}",
            std::process::id(),
            unique_suffix()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        let mut image = RgbaImage::new(4, 3);
        for pixel in image.pixels_mut() {
            *pixel = Rgba(color);
        }
        image.save(&path).unwrap();
        (dir, path)
    }

    fn registration(offsets: Vec<super::super::register::Offset>) -> Registration {
        let mut registration = Registration::new(StitchOptions::default());
        registration.offsets = offsets;
        registration
    }

    fn projective_registration(matrix: [f64; 9]) -> Registration {
        let mut registration = Registration::new(StitchOptions::default());
        registration.transforms = vec![ProjectiveTransform { matrix }];
        registration
    }

    #[test]
    fn high_order_feather_strongly_favors_the_geometric_owner() {
        let dominant = 0.8f32.powi(12);
        let secondary = 0.6f32.powi(12);
        let result = (40.0 * dominant + 200.0 * secondary) / (dominant + secondary);
        assert!(result < 46.0, "parallax blend remained too wide: {result}");
        assert!(result > 40.0, "feather must remain continuous: {result}");
    }

    #[test]
    fn negative_offsets_are_normalized_and_rendered() {
        let (dir, first) = fixture("first.png", [255, 0, 0, 255]);
        let second = dir.join("second.png");
        RgbaImage::from_pixel(4, 3, Rgba([0, 255, 0, 255]))
            .save(&second)
            .unwrap();
        let out = dir.join("panorama.png");
        let tiles = vec![
            CaptureTile {
                row: 0,
                column: 0,
                path: first,
                geometry: None,
            },
            CaptureTile {
                row: 0,
                column: 1,
                path: second,
                geometry: None,
            },
        ];
        let cancel = CancellationToken::default();
        let mut cb = |_| {};
        let (_, width, height) = render_banded(
            &tiles,
            &registration(vec![
                super::super::register::Offset { x: -2, y: -1 },
                super::super::register::Offset { x: 2, y: 0 },
            ]),
            2,
            &out,
            &cancel,
            &mut cb,
        )
        .unwrap();
        assert_eq!((width, height), (8, 4));
        let decoded = ::image::open(&out).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (8, 4));
        assert_eq!(decoded.get_pixel(0, 1)[0], 255);
        assert_eq!(decoded.get_pixel(7, 1)[1], 255);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn cancellation_does_not_publish_output() {
        let (dir, path) = fixture("tile.png", [1, 2, 3, 255]);
        let out = dir.join("panorama.png");
        let cancel = CancellationToken::default();
        let callback_cancel = cancel.clone();
        let tiles = vec![CaptureTile {
            row: 0,
            column: 0,
            path,
            geometry: None,
        }];
        let mut cb = move |p: Progress| {
            if p.stage == "source_spool" {
                callback_cancel.cancel();
            }
        };
        assert!(matches!(
            render_banded(
                &tiles,
                &registration(vec![super::super::register::Offset { x: 0, y: 0 }]),
                1,
                &out,
                &cancel,
                &mut cb
            ),
            Err(crate::Error::Cancelled)
        ));
        assert!(!out.exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn existing_destination_is_preserved_and_large_band_is_bounded() {
        let (dir, path) = fixture("tile.png", [9, 8, 7, 255]);
        let out = dir.join("panorama.png");
        std::fs::write(&out, b"keep").unwrap();
        let tiles = vec![CaptureTile {
            row: 0,
            column: 0,
            path,
            geometry: None,
        }];
        let cancel = CancellationToken::default();
        let mut cb = |_| {};
        assert!(render_banded(
            &tiles,
            &registration(vec![super::super::register::Offset { x: 0, y: 0 }]),
            u32::MAX,
            &out,
            &cancel,
            &mut cb
        )
        .is_err());
        assert_eq!(std::fs::read(&out).unwrap(), b"keep");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn maximum_band_renders_successfully() {
        let (dir, path) = fixture("tile.png", [9, 8, 7, 255]);
        let out = dir.join("fresh.png");
        let tiles = vec![CaptureTile {
            row: 0,
            column: 0,
            path,
            geometry: None,
        }];
        let cancel = CancellationToken::default();
        let mut cb = |_| {};
        assert!(render_banded(
            &tiles,
            &registration(vec![super::super::register::Offset { x: 0, y: 0 }]),
            u32::MAX,
            &out,
            &cancel,
            &mut cb
        )
        .is_ok());
        assert_eq!(::image::open(&out).unwrap().dimensions(), (4, 3));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn affine_renderer_uses_transformed_corner_bounds_and_inverse_mapping() {
        let (dir, path) = fixture("tile.png", [30, 60, 90, 255]);
        let out = dir.join("affine.png");
        let tiles = vec![CaptureTile {
            row: 0,
            column: 0,
            path,
            geometry: None,
        }];
        let registration = projective_registration([1.0, 0.5, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]);
        let mut cb = |_| {};
        let (_, width, height) = render_banded(
            &tiles,
            &registration,
            2,
            &out,
            &CancellationToken::default(),
            &mut cb,
        )
        .unwrap();
        assert_eq!((width, height), (6, 3));
        assert_eq!(
            ::image::open(&out).unwrap().get_pixel(2, 1).0[..3],
            [30, 60, 90]
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn projective_renderer_expands_bbox_without_resident_source_set() {
        let (dir, path) = fixture("tile.png", [12, 34, 56, 255]);
        let out = dir.join("projective.png");
        let tiles = vec![CaptureTile {
            row: 0,
            column: 0,
            path,
            geometry: None,
        }];
        let registration = projective_registration([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, -0.05, 0.0, 1.0]);
        let mut cb = |_| {};
        let (_, width, height) = render_banded(
            &tiles,
            &registration,
            1,
            &out,
            &CancellationToken::default(),
            &mut cb,
        )
        .unwrap();
        assert_eq!((width, height), (5, 4));
        assert_eq!(
            ::image::open(&out).unwrap().get_pixel(1, 1).0[..3],
            [12, 34, 56]
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}
