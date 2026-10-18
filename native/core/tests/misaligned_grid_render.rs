//! End-to-end registration truth tests with images captured from perturbed
//! camera poses. Unlike a shifted-layout renderer test, these fixtures make
//! the photographed pixels themselves agree with an independent sphere.

use image::{Rgb, RgbImage};
use lumia_gigascan_core::{spherical, spherical_renderer};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

const W: u32 = 240;
const H: u32 = 180;
const FX: f64 = 145.0;
const FY: f64 = 143.0;
const CX: f64 = (W as f64 - 1.0) * 0.5;
const CY: f64 = (H as f64 - 1.0) * 0.5;
type Mat = [f64; 9];

struct FixtureDir(PathBuf);
static NEXT_ID: AtomicU64 = AtomicU64::new(0);

impl FixtureDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "lumia-misaligned-grid-render-{}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for FixtureDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn mul(a: Mat, b: Mat) -> Mat {
    let mut out = [0.0; 9];
    for row in 0..3 {
        for column in 0..3 {
            out[row * 3 + column] = (0..3).map(|k| a[row * 3 + k] * b[k * 3 + column]).sum();
        }
    }
    out
}

fn transpose(a: Mat) -> Mat {
    [a[0], a[3], a[6], a[1], a[4], a[7], a[2], a[5], a[8]]
}

fn ry(angle: f64) -> Mat {
    let (s, c) = angle.sin_cos();
    [c, 0.0, s, 0.0, 1.0, 0.0, -s, 0.0, c]
}

fn rx(angle: f64) -> Mat {
    let (s, c) = angle.sin_cos();
    [1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c]
}

fn rz(angle: f64) -> Mat {
    let (s, c) = angle.sin_cos();
    [c, -s, 0.0, s, c, 0.0, 0.0, 0.0, 1.0]
}

fn mul_vec(a: Mat, v: [f64; 3]) -> [f64; 3] {
    [
        a[0] * v[0] + a[1] * v[1] + a[2] * v[2],
        a[3] * v[0] + a[4] * v[1] + a[5] * v[2],
        a[6] * v[0] + a[7] * v[1] + a[8] * v[2],
    ]
}

fn nominal_pose(row: usize, column: usize, rows: usize, columns: usize) -> Mat {
    let yaw = (column as f64 - (columns - 1) as f64 * 0.5) * 0.34;
    let pitch = ((rows - 1) as f64 * 0.5 - row as f64) * 0.24;
    mul(ry(yaw), rx(-pitch))
}

fn perturbation(row: usize, column: usize, rows: usize, columns: usize) -> Mat {
    // 2x2/4x4 cases perturb physical corners; 3x3 perturbs a contiguous
    // three-capture patch including the center. Distinct signs prevent a
    // common rigid rotation from being absorbed as the global coordinate frame.
    let affected = if rows == 3 && columns == 3 {
        [(1, 1), (1, 2), (2, 1)].contains(&(row, column))
    } else {
        (row == 0 || row + 1 == rows) && (column == 0 || column + 1 == columns)
    };
    if !affected {
        return [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
    }
    let sx = if (row + column) % 2 == 0 { 1.0 } else { -1.0 };
    let sy = if row % 2 == 0 { -1.0 } else { 1.0 };
    // Rotation sizes are specified in approximate source-pixel effects:
    // 6px yaw, 4px pitch, and 4px roll at the half-image radius.
    let yaw = 6.0 / FX;
    let pitch = 4.0 / FY;
    let roll = 4.0 / (f64::from(W.min(H)) * 0.5);
    mul(ry(sx * yaw), mul(rx(sy * pitch), rz(sx * sy * roll)))
}

fn actual_pose(row: usize, column: usize, rows: usize, columns: usize) -> Mat {
    mul(
        perturbation(row, column, rows, columns),
        nominal_pose(row, column, rows, columns),
    )
}

fn mix(mut x: u32) -> u32 {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846ca68b);
    x ^ (x >> 16)
}

fn channel(yaw: f64, pitch: f64, offset: u32) -> u8 {
    let x = (((yaw + std::f64::consts::PI) / (2.0 * std::f64::consts::PI) * 2048.0) as i32)
        .div_euclid(8) as u32;
    let y = (((std::f64::consts::FRAC_PI_2 - pitch) / std::f64::consts::PI * 1024.0) as i32)
        .div_euclid(8) as u32;
    (32 + mix(x.wrapping_mul(0x9e3779b9) ^ y.wrapping_mul(0x85ebca6b) ^ offset) % 216) as u8
}

fn scene(yaw: f64, pitch: f64) -> [u8; 3] {
    [
        channel(yaw, pitch, 0),
        channel(yaw + 0.041, pitch - 0.017, 0x45d9f3b),
        channel(yaw - 0.023, pitch + 0.037, 0x119de1f3),
    ]
}

fn write_capture(path: &Path, camera: Mat) {
    write_capture_with_focal(path, camera, FX, FY);
}

fn write_capture_with_focal(path: &Path, camera: Mat, fx: f64, fy: f64) {
    let mut image = RgbImage::new(W, H);
    for y in 0..H {
        for x in 0..W {
            let ray = [(f64::from(x) - CX) / fx, -(f64::from(y) - CY) / fy, 1.0];
            let world = mul_vec(camera, ray);
            let yaw = world[0].atan2(world[2]);
            let pitch = world[1].atan2((world[0] * world[0] + world[2] * world[2]).sqrt());
            image.put_pixel(x, y, Rgb(scene(yaw, pitch)));
        }
    }
    image.save(path).unwrap();
}

fn align_case(dir: &FixtureDir, rows: usize, columns: usize, deghost: bool, warp: bool) -> Value {
    let mut tiles = Vec::new();
    for row in 0..rows {
        for column in 0..columns {
            let path = dir.0.join(format!("capture-{rows}-{row}-{column}.png"));
            write_capture(&path, actual_pose(row, column, rows, columns));
            tiles.push(json!({"row":row,"column":column,"path":path}));
        }
    }
    let request = json!({
        "rows":rows,"columns":columns,"tiles":tiles,
        "fx":FX,"fy":FY,"cx":CX,"cy":CY,
        "sourceWidth":W,"sourceHeight":H,
        "seamBlendMode":if deghost {"deghost"} else {"feather"},
        "localTextureWarp":warp,"workers":1,"registrationMegapixels":0.12
    });
    spherical::align_json_detailed(&request.to_string()).unwrap_or_else(|failure| {
        panic!("{rows}x{columns} actual-pose registration failed: {failure:?}")
    })
}

fn render(layout: &Value, output: &Path) -> RgbImage {
    spherical_renderer::render_layout_tiles(layout, output, 32, || false).unwrap();
    let width = layout["width"].as_u64().unwrap() as u32;
    let height = layout["height"].as_u64().unwrap() as u32;
    let mut image = RgbImage::new(width, height);
    for row in 0..height.div_ceil(512) {
        for column in 0..width.div_ceil(512) {
            let tile = image::open(output.join("level-0").join(format!("{row}-{column}.png")))
                .unwrap()
                .into_rgba8();
            for y in 0..tile.height() {
                for x in 0..tile.width() {
                    let pixel = tile.get_pixel(x, y);
                    if pixel[3] != 0 {
                        image.put_pixel(
                            column * 512 + x,
                            row * 512 + y,
                            Rgb([pixel[0], pixel[1], pixel[2]]),
                        );
                    }
                }
            }
        }
    }
    image
}

fn truth_mae(layout: &Value, rendered: &RgbImage, roi: Option<(f64, f64, f64)>) -> (f64, usize) {
    let tiles = layout["tiles"].as_array().unwrap();
    let rows = tiles
        .iter()
        .map(|tile| tile["row"].as_u64().unwrap() as usize)
        .max()
        .unwrap()
        + 1;
    let columns = tiles
        .iter()
        .map(|tile| tile["column"].as_u64().unwrap() as usize)
        .max()
        .unwrap()
        + 1;
    // Spherical output may choose any global orientation gauge. Convert each
    // output ray into the analytic capture frame before looking up its truth.
    let truth_anchor = actual_pose(0, 0, rows, columns);
    let estimated_anchor = estimated_pose(layout, 0, 0);
    let layout_to_truth = transpose(mul(estimated_anchor, transpose(truth_anchor)));
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
            let output_ray = [
                yaw.sin() * pitch.cos(),
                pitch.sin(),
                yaw.cos() * pitch.cos(),
            ];
            let truth_ray = mul_vec(layout_to_truth, output_ray);
            let truth_yaw = truth_ray[0].atan2(truth_ray[2]);
            let truth_pitch = truth_ray[1]
                .atan2((truth_ray[0] * truth_ray[0] + truth_ray[2] * truth_ray[2]).sqrt());
            if let Some((center_yaw, center_pitch, radius)) = roi {
                if (truth_yaw - center_yaw).abs() > radius
                    || (truth_pitch - center_pitch).abs() > radius
                {
                    continue;
                }
            }
            let actual = rendered.get_pixel(x, y).0;
            // Ignore uncovered pixels and hard texture boundaries. The expected
            // colors come from the analytic sphere, never from another render.
            if actual == [0, 0, 0] {
                continue;
            }
            let gx = (truth_yaw + std::f64::consts::PI) / (2.0 * std::f64::consts::PI) * 2048.0;
            let gy = (std::f64::consts::FRAC_PI_2 - truth_pitch) / std::f64::consts::PI * 1024.0;
            let dx = (gx / 8.0).fract().min(1.0 - (gx / 8.0).fract());
            let dy = (gy / 8.0).fract().min(1.0 - (gy / 8.0).fract());
            if dx < 0.22 || dy < 0.22 {
                continue;
            }
            let expected = scene(truth_yaw, truth_pitch);
            for channel in 0..3 {
                total += (f64::from(actual[channel]) - f64::from(expected[channel])).abs();
            }
            samples += 1;
        }
    }
    (total / (samples.max(1) * 3) as f64, samples)
}

fn center(pose: Mat) -> (f64, f64) {
    (pose[2].atan2(pose[8]), pose[5].asin())
}

fn estimated_pose(layout: &Value, row: usize, column: usize) -> Mat {
    let tile = layout["tiles"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tile| {
            tile["row"].as_u64() == Some(row as u64)
                && tile["column"].as_u64() == Some(column as u64)
        })
        .unwrap_or_else(|| panic!("missing registered tile {row},{column}"));
    serde_json::from_value(tile["cameraToWorld"].clone()).unwrap()
}

fn boundary_reprojection_errors(
    layout: &Value,
    rows: usize,
    columns: usize,
    row: usize,
    column: usize,
) -> Vec<f64> {
    let truth_anchor = actual_pose(0, 0, rows, columns);
    let estimated_anchor = estimated_pose(layout, 0, 0);
    let estimated_to_truth = transpose(mul(estimated_anchor, transpose(truth_anchor)));
    let estimated = mul(estimated_to_truth, estimated_pose(layout, row, column));
    let actual = actual_pose(row, column, rows, columns);
    let mut points = Vec::new();
    for step in 0..=8 {
        let fraction = f64::from(step) / 8.0;
        let x = 8.0 + fraction * (f64::from(W) - 17.0);
        let y = 8.0 + fraction * (f64::from(H) - 17.0);
        points.extend([
            (8.0, y),
            (f64::from(W) - 9.0, y),
            (x, 8.0),
            (x, f64::from(H) - 9.0),
        ]);
    }
    let estimated_from_world = transpose(estimated);
    points
        .into_iter()
        .filter_map(|(x, y)| {
            let source_ray = [(x - CX) / FX, -(y - CY) / FY, 1.0];
            let world_ray = mul_vec(actual, source_ray);
            let registered_ray = mul_vec(estimated_from_world, world_ray);
            if registered_ray[2] <= 1e-8 {
                return None;
            }
            let projected_x = CX + FX * registered_ray[0] / registered_ray[2];
            let projected_y = CY - FY * registered_ray[1] / registered_ray[2];
            Some((projected_x - x).hypot(projected_y - y))
        })
        .collect()
}

fn p95(values: &[f64]) -> f64 {
    assert!(
        !values.is_empty(),
        "reprojection must have valid boundary support"
    );
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[((sorted.len() - 1) * 95).div_ceil(100)]
}

fn assert_reprojection_gate(errors: &[f64], context: &str) {
    let p95 = p95(errors);
    let worst = errors.iter().copied().fold(0.0, f64::max);
    assert!(
        errors.len() >= 20,
        "{context}: too few valid reprojections: {}",
        errors.len()
    );
    assert!(p95 <= 2.0 && worst <= 4.0,
        "{context}: source-plane error must stay within p95 2px / worst 4px; p95={p95:.2}, worst={worst:.2}");
}

fn assert_local_eight_neighbor_graph(layout: &Value, rows: usize, columns: usize) {
    let tiles = layout["tiles"].as_array().unwrap();
    assert_eq!(
        tiles.len(),
        rows * columns,
        "registration must preserve each input photo"
    );
    let cells: std::collections::HashSet<_> = tiles
        .iter()
        .map(|tile| {
            (
                tile["row"].as_u64().unwrap(),
                tile["column"].as_u64().unwrap(),
            )
        })
        .collect();
    let paths: std::collections::HashSet<_> = tiles
        .iter()
        .map(|tile| tile["path"].as_str().unwrap())
        .collect();
    assert_eq!(cells.len(), rows * columns, "grid cells must remain unique");
    assert_eq!(
        paths.len(),
        rows * columns,
        "source photo IDs must remain unique"
    );
    let edges = layout["report"]["edgeDiagnostics"].as_array().unwrap();
    let expected = rows * (columns - 1) + (rows - 1) * columns + 2 * (rows - 1) * (columns - 1);
    assert_eq!(
        edges.len(),
        expected,
        "each immediate neighbor pair is represented once"
    );
    let mut pairs = std::collections::HashSet::new();
    for edge in edges {
        let from = edge["from"].as_u64().unwrap() as usize;
        let to = edge["to"].as_u64().unwrap() as usize;
        assert!(from < tiles.len() && to < tiles.len() && from != to);
        assert!(
            pairs.insert((from.min(to), from.max(to))),
            "duplicate pair {from}-{to}"
        );
        let (r0, c0) = (
            tiles[from]["row"].as_u64().unwrap(),
            tiles[from]["column"].as_u64().unwrap(),
        );
        let (r1, c1) = (
            tiles[to]["row"].as_u64().unwrap(),
            tiles[to]["column"].as_u64().unwrap(),
        );
        assert!(
            r0.abs_diff(r1) <= 1 && c0.abs_diff(c1) <= 1,
            "nonlocal pair {from}-{to}"
        );
    }
}

#[test]
fn actual_camera_pose_errors_register_and_render_against_independent_rgb_truth() {
    // Exercise three grid scales and both blend modes. The 4x4 case enables the
    // bounded source-plane warp; this is a synthetic robustness check, not a
    // claim that parallax can be corrected by a single spherical camera model.
    for (rows, columns, deghost, warp) in [
        (2, 2, false, false),
        (3, 3, true, false),
        (4, 4, true, true),
    ] {
        let dir = FixtureDir::new();
        let layout = align_case(&dir, rows, columns, deghost, warp);
        assert_eq!(layout["tiles"].as_array().unwrap().len(), rows * columns);
        assert_eq!(
            layout["renderBlendMode"],
            if deghost { "deghost" } else { "feather" }
        );
        assert_local_eight_neighbor_graph(&layout, rows, columns);

        // The metric is in source pixels, uses known capture poses and sampled
        // image-boundary rays, and does not use renderer output. Strict camera
        // geometry checks apply to the unwarped cases, where source-plane warp
        // cannot mask pose error.
        if !warp {
            let mut affected_tiles = Vec::new();
            for row in 0..rows {
                for column in 0..columns {
                    let is_affected = if rows == 3 && columns == 3 {
                        [(1, 1), (1, 2), (2, 1)].contains(&(row, column))
                    } else {
                        (row == 0 || row + 1 == rows) && (column == 0 || column + 1 == columns)
                    };
                    if is_affected {
                        affected_tiles.push((row, column));
                        if (row, column) == (0, 0) {
                            // The first camera establishes the arbitrary global
                            // orientation gauge; it cannot independently score itself.
                            continue;
                        }
                        let errors =
                            boundary_reprojection_errors(&layout, rows, columns, row, column);
                        assert_reprojection_gate(
                            &errors,
                            &format!("perturbed tile {row},{column}"),
                        );
                    }
                }
            }
            if rows == 3 {
                for (row, column) in [(0, 1), (1, 0), (2, 2)] {
                    let errors = boundary_reprojection_errors(&layout, rows, columns, row, column);
                    assert_reprojection_gate(&errors, &format!("unperturbed tile {row},{column}"));
                }
            }

            // Inject an additional, uncorrected yaw error into one affected
            // camera. The exact same p95/worst source-pixel gate must reject it.
            let (row, column) = *affected_tiles
                .iter()
                .find(|&&tile| tile != (0, 0))
                .expect("negative control requires a nongauge affected tile");
            let mut uncorrected = layout.clone();
            let tile_index = uncorrected["tiles"]
                .as_array()
                .unwrap()
                .iter()
                .position(|tile| {
                    tile["row"].as_u64() == Some(row as u64)
                        && tile["column"].as_u64() == Some(column as u64)
                })
                .unwrap();
            let estimated: Mat =
                serde_json::from_value(uncorrected["tiles"][tile_index]["cameraToWorld"].clone())
                    .unwrap();
            uncorrected["tiles"][tile_index]["cameraToWorld"] = json!(mul(ry(8.0 / FX), estimated));
            let bad_errors = boundary_reprojection_errors(&uncorrected, rows, columns, row, column);
            assert!(
                p95(&bad_errors) > 2.0 || bad_errors.iter().copied().fold(0.0, f64::max) > 4.0,
                "uncorrected pose must fail the same source-pixel gate"
            );
        }

        let rendered = render(&layout, &dir.0.join("render-registered"));
        let (overall, samples) = truth_mae(&layout, &rendered, None);
        assert!(
            samples > 150,
            "insufficient independent RGB truth coverage: {samples}"
        );
        assert!(
            overall < 22.0,
            "{rows}x{columns} registered MAE {overall:.2}"
        );

        // Verify independent truth around the four outer corners and the middle
        // of each boundary. These ROIs include the perturbed physical captures.
        let mut regions = Vec::new();
        for (row, column) in [
            (0, 0),
            (0, columns - 1),
            (rows - 1, 0),
            (rows - 1, columns - 1),
            (0, columns / 2),
            (rows - 1, columns / 2),
            (rows / 2, 0),
            (rows / 2, columns - 1),
        ] {
            regions.push(center(actual_pose(row, column, rows, columns)));
        }
        for (yaw, pitch) in regions {
            let (error, count) = truth_mae(&layout, &rendered, Some((yaw, pitch, 0.075)));
            assert!(
                count > 12,
                "boundary truth ROI too sparse at {yaw:.3},{pitch:.3}: {count}"
            );
            assert!(
                error < 30.0,
                "boundary truth MAE {error:.2} at {yaw:.3},{pitch:.3}"
            );
        }

        // An uncorrected camera-pose error is a negative control: it must
        // measurably worsen the affected-corner metric versus actual registration.
        let mut uncorrected = layout.clone();
        let index = (rows - 1) * columns + columns - 1;
        let estimated: Mat =
            serde_json::from_value(uncorrected["tiles"][index]["cameraToWorld"].clone()).unwrap();
        uncorrected["tiles"][index]["cameraToWorld"] = json!(mul(ry(0.12), estimated));
        let bad = render(&uncorrected, &dir.0.join("render-uncorrected"));
        let target = center(actual_pose(rows - 1, columns - 1, rows, columns));
        let (good_error, _) = truth_mae(&layout, &rendered, Some((target.0, target.1, 0.11)));
        let (bad_error, _) = truth_mae(&layout, &bad, Some((target.0, target.1, 0.11)));
        assert!(
            bad_error > good_error + 1.5,
            "negative control failed: registered={good_error:.2}, uncorrected={bad_error:.2}"
        );
    }
}

#[test]
fn narrow_field_without_physical_overlap_fails_registration_boundedly() {
    let dir = FixtureDir::new();
    let fx = f64::from(W) * 19.5;
    let fy = f64::from(H) * 19.5;
    let step = 0.08; // Wider than either calibrated view's angular coverage.
    let mut tiles = Vec::new();
    for row in 0..2 {
        for column in 0..2 {
            let pose = mul(
                ry((column as f64 - 0.5) * step),
                rx((0.5 - row as f64) * step),
            );
            let path = dir.0.join(format!("narrow-{row}-{column}.png"));
            write_capture_with_focal(&path, pose, fx, fy);
            tiles.push(json!({"row":row,"column":column,"path":path}));
        }
    }
    let request = json!({
        "rows":2,"columns":2,"tiles":tiles,
        "fx":fx,"fy":fy,"cx":CX,"cy":CY,
        "sourceWidth":W,"sourceHeight":H,
        "neighborMode":"eight","seamBlendMode":"feather",
        "localTextureWarp":false,"workers":1,"registrationMegapixels":0.12
    });
    let failure = spherical::align_json_detailed(&request.to_string());
    assert!(
        failure.is_err(),
        "registration must stop rather than inventing overlap for a 19.5× focal ratio with disjoint views"
    );
}
