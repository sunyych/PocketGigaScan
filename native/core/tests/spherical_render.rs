use image::{GrayImage, ImageBuffer, Luma, Rgba, RgbaImage};
use lumia_gigascan_core::{spherical, spherical_renderer};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

const W: u32 = 320;
const H: u32 = 240;
const FX: f64 = 190.0;
const FY: f64 = 188.0;
const CX: f64 = (W as f64 - 1.0) * 0.5;
const CY: f64 = (H as f64 - 1.0) * 0.5;

struct FixtureDir(PathBuf);
static NEXT_FIXTURE_ID: AtomicU64 = AtomicU64::new(0);

impl FixtureDir {
    fn new(label: &str) -> Self {
        loop {
            let sequence = NEXT_FIXTURE_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "lumia-spherical-render-{label}-{}-{sequence}",
                std::process::id()
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Self(path),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("failed to create render fixture directory: {error}"),
            }
        }
    }
}

impl Drop for FixtureDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

type Mat = [f64; 9];

fn mul(a: Mat, b: Mat) -> Mat {
    let mut out = [0.0; 9];
    for row in 0..3 {
        for column in 0..3 {
            out[row * 3 + column] = (0..3).map(|k| a[row * 3 + k] * b[k * 3 + column]).sum();
        }
    }
    out
}

fn ry(angle: f64) -> Mat {
    let (s, c) = angle.sin_cos();
    [c, 0.0, s, 0.0, 1.0, 0.0, -s, 0.0, c]
}

fn rx(angle: f64) -> Mat {
    let (s, c) = angle.sin_cos();
    [1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c]
}

fn mul_vec(a: Mat, v: [f64; 3]) -> [f64; 3] {
    [
        a[0] * v[0] + a[1] * v[1] + a[2] * v[2],
        a[3] * v[0] + a[4] * v[1] + a[5] * v[2],
        a[6] * v[0] + a[7] * v[1] + a[8] * v[2],
    ]
}

fn pose(row: usize, column: usize) -> Mat {
    mul(
        ry((column as f64 - 1.0) * 0.32),
        rx((1.0 - row as f64) * -0.23),
    )
}

fn mix(mut x: u32) -> u32 {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846ca68b);
    x ^ (x >> 16)
}

fn texture(yaw: f64, pitch: f64) -> u8 {
    let x = (((yaw + std::f64::consts::PI) / (2.0 * std::f64::consts::PI) * 2048.0) as i32)
        .div_euclid(8) as u32;
    let y = (((std::f64::consts::FRAC_PI_2 - pitch) / std::f64::consts::PI * 1024.0) as i32)
        .div_euclid(8) as u32;
    (40 + mix(x.wrapping_mul(0x9e3779b9) ^ y.wrapping_mul(0x85ebca6b)) % 200) as u8
}

fn textured_source(path: &Path, camera: Mat) {
    let mut image = GrayImage::new(W, H);
    for y in 0..H {
        for x in 0..W {
            let ray = [(f64::from(x) - CX) / FX, -(f64::from(y) - CY) / FY, 1.0];
            let world = mul_vec(camera, ray);
            image.put_pixel(
                x,
                y,
                Luma([texture(
                    world[0].atan2(world[2]),
                    world[1].atan2((world[0] * world[0] + world[2] * world[2]).sqrt()),
                )]),
            );
        }
    }
    image.save(path).unwrap();
}

fn textured_layout(dir: &FixtureDir) -> Value {
    let mut tiles = Vec::new();
    for row in 0..3 {
        for column in 0..3 {
            let path = dir.0.join(format!("texture-{row}-{column}.png"));
            textured_source(&path, pose(row, column));
            tiles.push(json!({"row":row,"column":column,"path":path}));
        }
    }
    let request = json!({
        "rows":3,"columns":3,"tiles":tiles,
        "fx":FX,"fy":FY,"cx":CX,"cy":CY,
        "sourceWidth":W,"sourceHeight":H,
        "seamBlendMode":"feather","localTextureWarp":false,
        "workers":1,"registrationMegapixels":0.2
    });
    let layout = spherical::align_json_detailed(&request.to_string())
        .unwrap_or_else(|failure| panic!("synthetic spherical registration failed: {failure:?}"));
    assert_eq!(layout["tiles"].as_array().unwrap().len(), 9);
    assert_eq!(layout["renderBlendMode"], "feather");
    layout
}

fn render(layout: &Value, output: &Path) -> RgbaImage {
    spherical_renderer::render_layout_tiles(layout, output, 32, || false).unwrap();
    let width = layout["width"].as_u64().unwrap() as u32;
    let height = layout["height"].as_u64().unwrap() as u32;
    let columns = width.div_ceil(512);
    let mut image = RgbaImage::new(width, height);
    for row in 0..height.div_ceil(512) {
        for column in 0..columns {
            let path = output.join("level-0").join(format!("{row}-{column}.png"));
            let tile = image::open(path).unwrap().into_rgba8();
            for y in 0..tile.height() {
                for x in 0..tile.width() {
                    image.put_pixel(column * 512 + x, row * 512 + y, *tile.get_pixel(x, y));
                }
            }
        }
    }
    image
}

fn ground_truth_error(
    layout: &Value,
    rendered: &RgbaImage,
    region: Option<(f64, f64, f64)>,
) -> f64 {
    let yaw_min = layout["yawMinRad"].as_f64().unwrap();
    let yaw_max = layout["yawMaxRad"].as_f64().unwrap();
    let pitch_min = layout["pitchMinRad"].as_f64().unwrap();
    let pitch_max = layout["pitchMaxRad"].as_f64().unwrap();
    let mut total = 0.0;
    let mut samples = 0usize;
    for y in (0..rendered.height()).step_by(2) {
        let pitch = pitch_max
            - (f64::from(y) + 0.5) / f64::from(rendered.height()) * (pitch_max - pitch_min);
        for x in (0..rendered.width()).step_by(2) {
            let yaw =
                yaw_min + (f64::from(x) + 0.5) / f64::from(rendered.width()) * (yaw_max - yaw_min);
            if let Some((target_yaw, target_pitch, radius)) = region {
                if (yaw - target_yaw).abs() > radius || (pitch - target_pitch).abs() > radius {
                    continue;
                }
            }
            let pixel = rendered.get_pixel(x, y).0;
            if pixel[3] == 0 {
                continue;
            }
            let gx = (yaw + std::f64::consts::PI) / (2.0 * std::f64::consts::PI) * 2048.0;
            let gy = (std::f64::consts::FRAC_PI_2 - pitch) / std::f64::consts::PI * 1024.0;
            let dist_x = (gx / 8.0).fract().min(1.0 - (gx / 8.0).fract());
            let dist_y = (gy / 8.0).fract().min(1.0 - (gy / 8.0).fract());
            // Skip discontinuities: this checks alignment and resampling, not the expected
            // bilinear color at a synthetic hard texture boundary.
            if dist_x < 0.22 || dist_y < 0.22 {
                continue;
            }
            let expected = f64::from(texture(yaw, pitch));
            let actual = (0.299 * f64::from(pixel[0])
                + 0.587 * f64::from(pixel[1])
                + 0.114 * f64::from(pixel[2])) as f64;
            total += (actual - expected).abs();
            samples += 1;
        }
    }
    assert!(
        samples > 50,
        "too few stable ground-truth pixels: {samples}"
    );
    total / samples as f64
}

fn assert_region_covered(layout: &Value, rendered: &RgbaImage, yaw: f64, pitch: f64) {
    let yaw_min = layout["yawMinRad"].as_f64().unwrap();
    let yaw_max = layout["yawMaxRad"].as_f64().unwrap();
    let pitch_min = layout["pitchMinRad"].as_f64().unwrap();
    let pitch_max = layout["pitchMaxRad"].as_f64().unwrap();
    let x0 = (((yaw - 0.025 - yaw_min) / (yaw_max - yaw_min) * f64::from(rendered.width())).floor()
        as u32)
        .min(rendered.width() - 1);
    let x1 = (((yaw + 0.025 - yaw_min) / (yaw_max - yaw_min) * f64::from(rendered.width())).ceil()
        as u32)
        .min(rendered.width() - 1);
    let y0 = (((pitch_max - (pitch + 0.025)) / (pitch_max - pitch_min)
        * f64::from(rendered.height()))
    .floor() as u32)
        .min(rendered.height() - 1);
    let y1 = (((pitch_max - (pitch - 0.025)) / (pitch_max - pitch_min)
        * f64::from(rendered.height()))
    .ceil() as u32)
        .min(rendered.height() - 1);
    let mut covered = 0usize;
    let mut total = 0usize;
    for py in y0..=y1 {
        for px in x0..=x1 {
            total += 1;
            covered += usize::from(rendered.get_pixel(px, py)[3] == 255);
        }
    }
    assert!(
        total > 0 && covered == total,
        "expected seam ROI fully covered at yaw={yaw:.3}, pitch={pitch:.3}: {covered}/{total}"
    );
}

#[test]
fn textured_spherical_grid_renders_aligned_pixels_and_rejects_a_shifted_mesh() {
    let dir = FixtureDir::new("texture");
    let layout = textured_layout(&dir);
    let baseline = render(&layout, &dir.0.join("render-correct"));
    let baseline_error = ground_truth_error(&layout, &baseline, None);
    assert!(
        baseline_error < 12.0,
        "registered spherical texture should match analytic scene, MAE={baseline_error:.2}"
    );
    // These points lie on separate horizontal and vertical neighbor seams.
    let horizontal_seam_yaw = -0.16;
    let vertical_seam_pitch = -0.115;
    assert_region_covered(&layout, &baseline, horizontal_seam_yaw, 0.0);
    assert_region_covered(&layout, &baseline, 0.0, vertical_seam_pitch);
    let horizontal_seam_error =
        ground_truth_error(&layout, &baseline, Some((horizontal_seam_yaw, 0.0, 0.09)));
    let vertical_seam_error =
        ground_truth_error(&layout, &baseline, Some((0.0, vertical_seam_pitch, 0.09)));
    assert!(
        horizontal_seam_error < 15.0,
        "horizontal seam texture MAE={horizontal_seam_error:.2}"
    );
    assert!(
        vertical_seam_error < 15.0,
        "vertical seam texture MAE={vertical_seam_error:.2}"
    );

    let mut shifted = layout.clone();
    let original: Mat =
        serde_json::from_value(shifted["tiles"][5]["cameraToWorld"].clone()).unwrap();
    shifted["tiles"][5]["cameraToWorld"] = json!(mul(ry(0.075), original));
    let shifted_render = render(&shifted, &dir.0.join("render-shifted"));
    let target_pose: Mat =
        serde_json::from_value(layout["tiles"][5]["cameraToWorld"].clone()).unwrap();
    let target_yaw = target_pose[2].atan2(target_pose[8]);
    let target_pitch = target_pose[5].asin();
    let shifted_error = ground_truth_error(
        &layout,
        &shifted_render,
        Some((target_yaw, target_pitch, 0.2)),
    );
    let baseline_region_error =
        ground_truth_error(&layout, &baseline, Some((target_yaw, target_pitch, 0.2)));
    assert!(
        shifted_error > baseline_region_error + 8.0,
        "pixel metric must catch the deliberately shifted tile: baseline={baseline_region_error:.2}, shifted={shifted_error:.2}"
    );

    let mut vertically_shifted = layout.clone();
    let original: Mat =
        serde_json::from_value(vertically_shifted["tiles"][7]["cameraToWorld"].clone()).unwrap();
    vertically_shifted["tiles"][7]["cameraToWorld"] = json!(mul(rx(0.075), original));
    let vertical_render = render(&vertically_shifted, &dir.0.join("render-vertical-shift"));
    let vertical_shift_error = ground_truth_error(
        &layout,
        &vertical_render,
        Some((0.0, vertical_seam_pitch, 0.09)),
    );
    assert!(vertical_shift_error > vertical_seam_error + 8.0,
        "pixel metric must catch vertical tile shift: baseline={vertical_seam_error:.2}, shifted={vertical_shift_error:.2}");

    let mut deghost = layout.clone();
    deghost["renderBlendMode"] = json!("deghost");
    let deghost_render = render(&deghost, &dir.0.join("render-deghost"));
    let deghost_error = ground_truth_error(&deghost, &deghost_render, None);
    assert!(
        deghost_error < 15.0,
        "deghost texture output MAE={deghost_error:.2}"
    );
}

fn nominal_grid_layout(dir: &FixtureDir) -> Value {
    let colors: [[u8; 4]; 4] = [
        [220, 30, 30, 255],
        [30, 210, 30, 255],
        [30, 30, 220, 255],
        [220, 210, 30, 255],
    ];
    let mut tiles = Vec::new();
    for row in 0..2 {
        for column in 0..2 {
            let path = dir.0.join(format!("weak-grid-{row}-{column}.png"));
            ImageBuffer::from_pixel(W, H, Rgba(colors[row * 2 + column]))
                .save(&path)
                .unwrap();
            tiles.push(json!({"row":row,"column":column,"path":path}));
        }
    }
    tiles.reverse();
    let request = json!({
        "rows":2,"columns":2,"tiles":tiles,
        "fx":FX,"fy":FY,"cx":CX,"cy":CY,
        "sourceWidth":W,"sourceHeight":H,
        "placementMode":"grid-assisted","allowNominalGridFallback":true,
        "gridHorizontalOverlap":0.15,"gridVerticalOverlap":0.15,
        "seamBlendMode":"deghost","localTextureWarp":false
    });
    let layout = spherical::align_json_detailed(&request.to_string())
        .unwrap_or_else(|failure| panic!("nominal grid placement failed: {failure:?}"));
    assert_eq!(layout["report"]["visualTileCount"], 0);
    assert_eq!(layout["report"]["gridEstimatedTileCount"], 4);
    assert_eq!(layout["report"]["globalRayReprojectionRmsPx"], Value::Null);
    assert_eq!(layout["report"]["nominalGridOnlyNeedsVisualReview"], true);
    let fov_x = 2.0 * (f64::from(W) / (2.0 * FX)).atan();
    let fov_y = 2.0 * (f64::from(H) / (2.0 * FY)).atan();
    assert!(
        (layout["report"]["gridHorizontalStepRadians"]
            .as_f64()
            .unwrap()
            - fov_x * 0.85)
            .abs()
            < 1e-9
    );
    assert!(
        (layout["report"]["gridVerticalStepRadians"]
            .as_f64()
            .unwrap()
            - fov_y * 0.85)
            .abs()
            < 1e-9
    );
    let poses = layout["tiles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tile| {
            (
                tile["row"].as_u64().unwrap() as usize,
                tile["column"].as_u64().unwrap() as usize,
                serde_json::from_value::<Mat>(tile["cameraToWorld"].clone()).unwrap(),
            )
        })
        .collect::<Vec<_>>();
    let yaw = |pose: Mat| pose[2].atan2(pose[8]);
    let pitch = |pose: Mat| pose[5].asin();
    let pose_at = |row, column| {
        poses
            .iter()
            .find(|(r, c, _)| *r == row && *c == column)
            .unwrap()
            .2
    };
    assert!(yaw(pose_at(0, 1)) > yaw(pose_at(0, 0)));
    assert!(pitch(pose_at(1, 0)) < pitch(pose_at(0, 0)));
    layout
}

#[test]
fn weak_texture_grid_fallback_renders_all_horizontal_and_vertical_cells() {
    let dir = FixtureDir::new("grid");
    let layout = nominal_grid_layout(&dir);
    let rendered = render(&layout, &dir.0.join("grid-render"));
    let tiles = layout["tiles"].as_array().unwrap();
    assert_eq!(tiles.len(), 4);
    let coordinates = tiles
        .iter()
        .map(|tile| {
            let row = tile["row"].as_u64().unwrap() as usize;
            let column = tile["column"].as_u64().unwrap() as usize;
            let expected_name = format!("weak-grid-{row}-{column}.png");
            assert_eq!(
                Path::new(tile["path"].as_str().unwrap())
                    .file_name()
                    .unwrap()
                    .to_string_lossy(),
                expected_name,
                "input order must not detach a source path from its grid coordinate"
            );
            row * 2 + column
        })
        .collect::<std::collections::HashSet<_>>();
    assert_eq!(
        coordinates.len(),
        4,
        "all four grid coordinates must be unique"
    );
    let expected: [[u8; 4]; 4] = [
        [220, 30, 30, 255],
        [30, 210, 30, 255],
        [30, 30, 220, 255],
        [220, 210, 30, 255],
    ];
    for tile in tiles {
        let camera: Mat = serde_json::from_value(tile["cameraToWorld"].clone()).unwrap();
        let yaw = camera[2].atan2(camera[8]);
        let pitch = camera[5].asin();
        let x = ((yaw - layout["yawMinRad"].as_f64().unwrap())
            / (layout["yawMaxRad"].as_f64().unwrap() - layout["yawMinRad"].as_f64().unwrap())
            * f64::from(rendered.width())) as u32;
        let y = ((layout["pitchMaxRad"].as_f64().unwrap() - pitch)
            / (layout["pitchMaxRad"].as_f64().unwrap() - layout["pitchMinRad"].as_f64().unwrap())
            * f64::from(rendered.height())) as u32;
        let actual = rendered.get_pixel(x.min(rendered.width() - 1), y.min(rendered.height() - 1));
        assert!(
            actual[3] == 255,
            "grid cell ({},{}) center is missing from rendered output",
            tile["row"],
            tile["column"]
        );
        let index =
            tile["row"].as_u64().unwrap() as usize * 2 + tile["column"].as_u64().unwrap() as usize;
        let expected_color = expected[index];
        let mut matching_near_center = 0usize;
        for dy in -3i64..=3 {
            for dx in -3i64..=3 {
                let sx = (x as i64 + dx).clamp(0, i64::from(rendered.width() - 1)) as u32;
                let sy = (y as i64 + dy).clamp(0, i64::from(rendered.height() - 1)) as u32;
                let pixel = rendered.get_pixel(sx, sy);
                let distance = (0..3)
                    .map(|channel| {
                        (i16::from(pixel[channel]) - i16::from(expected_color[channel])).abs()
                    })
                    .sum::<i16>();
                matching_near_center += usize::from(distance <= 90);
            }
        }
        assert!(
            matching_near_center > 4,
            "grid cell ({},{}) did not retain its source-center color near its independently projected center: expected {:?}, matching {matching_near_center}/49",
            tile["row"], tile["column"], expected_color
        );
    }
    for (index, color) in expected.iter().enumerate() {
        let matching_pixels = rendered
            .pixels()
            .filter(|actual| {
                (0..3)
                    .map(|channel| (i16::from(actual[channel]) - i16::from(color[channel])).abs())
                    .sum::<i16>()
                    < 45
            })
            .count();
        assert!(
            matching_pixels > 20,
            "grid source {index} disappeared from output (matching pixels={matching_pixels})"
        );
    }
}
