//! Camera-pose alignment for spherical rendering. This module returns camera
//! orientations and calibrated pixel rays; it never produces a planar mosaic.
use crate::{
    grid_overlap::{self, EstimateError},
    metadata::{CaptureTile, StitchOptions},
    pipeline::StitchJob,
    projection::Projection,
    Error, Result,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::VecDeque, path::PathBuf};

const SPHERICAL_FEATURE_THREAD_LIMIT: i32 = 2;
const SPHERICAL_RETRY_CONTRAST_THRESHOLD: f64 = 0.004;
const DENSE_NORMAL_MAX_DIMENSION: usize = 1200;
const MAX_PIXEL_REFINEMENT_ITERATIONS: usize = 30;
const MAX_GRID_COMPONENT_POSE_ITERATIONS: usize = 30;
const GRID_COMPONENT_HUBER_ANGLE_RAD: f64 = 0.01;
const GRID_COMPONENT_STEP_TOLERANCE_RAD: f64 = 1e-7;
const PIXEL_BUNDLE_ALGORITHM_VERSION: u32 = 8;
const APPROVED_V2_SNAPSHOT_PRODUCER_SHA256: &str =
    "3a1eb012a9f1756b8772f217088fbe904b6ec0803457a72d3d0a36c6f2b9911e";
fn current_pixel_solver_parameters() -> Value {
    json!({
        "maxIterations":MAX_PIXEL_REFINEMENT_ITERATIONS,
        "huberDeltaPx":3.0,
        "maxRotationStepRadians":0.05,
        "pcgTargetRelativeResidual":1e-8,
        "acceptedLinearResidualLimit":1e-3,
        "gridComponentPoseMaxIterations":MAX_GRID_COMPONENT_POSE_ITERATIONS,
        "gridComponentPoseHuberAngleRad":GRID_COMPONENT_HUBER_ANGLE_RAD,
        "gridComponentPoseStepToleranceRadians":GRID_COMPONENT_STEP_TOLERANCE_RAD,
        "gridComponentPoseLinearSolver":"robust_joint_gn_pcg"
    })
}

#[derive(Debug)]
pub struct SphericalFailure {
    pub code: &'static str,
    pub message: String,
    pub diagnostics: Option<Value>,
}

impl From<Error> for SphericalFailure {
    fn from(error: Error) -> Self {
        let (code, message) = match error {
            Error::Invalid(message) => ("INVALID_ARGUMENT", message),
            Error::Decode(error) => ("INVALID_ARGUMENT", error.to_string()),
            Error::Io(error) => ("IO_ERROR", error.to_string()),
            Error::Registration(message) => ("REGISTRATION_FAILED", message),
            Error::RegistrationReport { message, .. } => ("REGISTRATION_FAILED", message),
            Error::Cancelled => ("CANCELLED", "spherical alignment was cancelled".to_owned()),
        };
        Self {
            code,
            message,
            diagnostics: None,
        }
    }
}

type Mat = [f64; 9];
const ID: Mat = [1., 0., 0., 0., 1., 0., 0., 0., 1.];

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    rows: usize,
    columns: usize,
    tiles: Vec<InputTile>,
    fx: f64,
    fy: f64,
    cx: f64,
    cy: f64,
    source_width: u32,
    source_height: u32,
    #[serde(default)]
    output_dir: String,
    #[serde(default)]
    placement_mode: String,
    #[serde(default)]
    allow_nominal_grid_fallback: bool,
    #[serde(default)]
    auto_grid_overlap: bool,
    #[serde(default)]
    refine_grid_neighbors: bool,
    #[serde(default = "default_seam_blend_mode")]
    seam_blend_mode: String,
    #[serde(default)]
    grid_horizontal_overlap: Option<f64>,
    #[serde(default)]
    grid_vertical_overlap: Option<f64>,
    #[serde(default = "default_neighbor_mode")]
    neighbor_mode: String,
    #[serde(default = "default_workers")]
    workers: usize,
    #[serde(default = "default_parallel_matching")]
    parallel_matching: bool,
    #[serde(default = "default_registration_megapixels")]
    registration_megapixels: f64,
    #[serde(default = "default_feature_type")]
    feature_type: String,
    #[serde(default = "default_matcher_type")]
    matcher_type: String,
    #[serde(default)]
    include_diagnostic_correspondences: bool,
    #[serde(default = "default_local_texture_warp")]
    local_texture_warp: bool,
}
fn default_local_texture_warp() -> bool {
    true
}
fn default_neighbor_mode() -> String {
    "four".into()
}
fn default_seam_blend_mode() -> String {
    "feather".into()
}
fn default_workers() -> usize {
    1
}
fn default_parallel_matching() -> bool {
    true
}
fn default_registration_megapixels() -> f64 {
    2.0
}
fn default_feature_type() -> String {
    "sift".into()
}
fn default_matcher_type() -> String {
    "bf".into()
}
#[derive(Debug, Deserialize)]
struct InputTile {
    row: usize,
    column: usize,
    path: String,
    #[serde(default, rename = "forceGrid")]
    force_grid: bool,
}
#[derive(Clone)]
struct Constraint {
    from: usize,
    to: usize,
    rotation: Mat,
    weight: f64,
}

fn mul(a: Mat, b: Mat) -> Mat {
    let mut out = [0.; 9];
    for r in 0..3 {
        for c in 0..3 {
            out[r * 3 + c] = (0..3).map(|k| a[r * 3 + k] * b[k * 3 + c]).sum();
        }
    }
    out
}
fn mul_vec(a: Mat, v: [f64; 3]) -> [f64; 3] {
    [
        a[0] * v[0] + a[1] * v[1] + a[2] * v[2],
        a[3] * v[0] + a[4] * v[1] + a[5] * v[2],
        a[6] * v[0] + a[7] * v[1] + a[8] * v[2],
    ]
}
fn transpose(a: Mat) -> Mat {
    [a[0], a[3], a[6], a[1], a[4], a[7], a[2], a[5], a[8]]
}
fn inverse(a: Mat) -> Option<Mat> {
    let d = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6])
        + a[2] * (a[3] * a[7] - a[4] * a[6]);
    if !d.is_finite() || d.abs() < 1e-10 {
        return None;
    }
    Some([
        (a[4] * a[8] - a[5] * a[7]) / d,
        (a[2] * a[7] - a[1] * a[8]) / d,
        (a[1] * a[5] - a[2] * a[4]) / d,
        (a[5] * a[6] - a[3] * a[8]) / d,
        (a[0] * a[8] - a[2] * a[6]) / d,
        (a[2] * a[3] - a[0] * a[5]) / d,
        (a[3] * a[7] - a[4] * a[6]) / d,
        (a[1] * a[6] - a[0] * a[7]) / d,
        (a[0] * a[4] - a[1] * a[3]) / d,
    ])
}
fn determinant(a: Mat) -> f64 {
    a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6])
        + a[2] * (a[3] * a[7] - a[4] * a[6])
}
fn normalize_rotation(mut a: Mat) -> Option<Mat> {
    if !a.iter().all(|v| v.is_finite()) {
        return None;
    }
    // Polar projection onto SO(3); homography scale is removed before this call.
    for _ in 0..12 {
        let inv_t = transpose(inverse(a)?);
        let mut change: f64 = 0.;
        for i in 0..9 {
            let next = 0.5 * (a[i] + inv_t[i]);
            change = change.max((next - a[i]).abs());
            a[i] = next;
        }
        if change < 1e-10 {
            break;
        }
    }
    if determinant(a) < 0. {
        for r in 0..3 {
            a[r * 3 + 2] = -a[r * 3 + 2];
        }
    }
    (determinant(a) > 0.999 && determinant(a) < 1.001).then_some(a)
}
#[cfg(test)]
fn calibrated_rotation(h: Mat, fx: f64, fy: f64, cx: f64, cy: f64) -> Option<Mat> {
    let k = [fx, 0., cx, 0., fy, cy, 0., 0., 1.];
    let ki = [1. / fx, 0., -cx / fx, 0., 1. / fy, -cy / fy, 0., 0., 1.];
    // Pixel space is x-right/y-down while the camera frame is x-right/y-up.
    let flip_y = [1., 0., 0., 0., -1., 0., 0., 0., 1.];
    let mut r = mul(mul(flip_y, mul(mul(ki, h), k)), flip_y);
    let scale = (0..3).map(|i| r[i * 3 + i]).sum::<f64>() / 3.;
    if !scale.is_finite() || scale.abs() < 1e-10 {
        return None;
    }
    for x in &mut r {
        *x /= scale;
    }
    normalize_rotation(r)
}
fn log_rotation(r: Mat) -> [f64; 3] {
    let angle = ((r[0] + r[4] + r[8] - 1.) * 0.5).clamp(-1., 1.).acos();
    if angle < 1e-8 {
        return [
            (r[7] - r[5]) * 0.5,
            (r[2] - r[6]) * 0.5,
            (r[3] - r[1]) * 0.5,
        ];
    }
    let s = angle / (2. * angle.sin());
    [s * (r[7] - r[5]), s * (r[2] - r[6]), s * (r[3] - r[1])]
}

fn median_value(values: &mut [f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let middle = values.len() / 2;
    Some(if values.len() % 2 == 0 {
        (values[middle - 1] + values[middle]) * 0.5
    } else {
        values[middle]
    })
}

#[derive(Clone)]
struct GridStep {
    rotation: Mat,
    sample_count: usize,
    robust_rms_radians: f64,
    source: &'static str,
}

fn robust_grid_step(samples: &[Mat]) -> Option<GridStep> {
    if samples.is_empty() {
        return None;
    }
    let vectors = samples
        .iter()
        .copied()
        .map(log_rotation)
        .collect::<Vec<_>>();
    let mut center = [0.; 3];
    for axis in 0..3 {
        let mut values = vectors
            .iter()
            .map(|vector| vector[axis])
            .collect::<Vec<_>>();
        center[axis] = median_value(&mut values)?;
    }
    let residuals = vectors
        .iter()
        .map(|vector| {
            let delta = [
                vector[0] - center[0],
                vector[1] - center[1],
                vector[2] - center[2],
            ];
            delta.iter().map(|value| value * value).sum::<f64>().sqrt()
        })
        .collect::<Vec<_>>();
    let median_residual = median_value(&mut residuals.clone())?;
    let mut deviations = residuals
        .iter()
        .map(|residual| (residual - median_residual).abs())
        .collect::<Vec<_>>();
    let mad = median_value(&mut deviations).unwrap_or(0.);
    let cutoff = (median_residual + (3.0 * 1.4826 * mad)).max(0.005);
    let inliers = vectors
        .iter()
        .zip(residuals.iter())
        .filter(|(_, residual)| **residual <= cutoff)
        .map(|(vector, _)| *vector)
        .collect::<Vec<_>>();
    if inliers.is_empty() {
        return None;
    }
    let mut refined = [0.; 3];
    for axis in 0..3 {
        let mut values = inliers
            .iter()
            .map(|vector| vector[axis])
            .collect::<Vec<_>>();
        refined[axis] = median_value(&mut values)?;
    }
    let refined_rotation = exp_rotation(refined);
    let rms = inliers
        .iter()
        .map(|vector| {
            let residual = log_rotation(mul(transpose(refined_rotation), exp_rotation(*vector)));
            residual.iter().map(|value| value * value).sum::<f64>()
        })
        .sum::<f64>()
        / inliers.len() as f64;
    Some(GridStep {
        rotation: refined_rotation,
        sample_count: inliers.len(),
        robust_rms_radians: rms.sqrt(),
        source: "visualMedian",
    })
}

fn grid_step_diagnostic(step: Option<&GridStep>) -> Value {
    step.map(|step| {
        json!({
            "sampleCount": step.sample_count,
            "medianRotationRadians": log_rotation(step.rotation).iter().map(|value| value * value).sum::<f64>().sqrt(),
            "robustRmsRadians": if step.source == "nominalFovOverlap" { Value::Null } else { json!(step.robust_rms_radians) },
            "source": step.source
        })
    })
    .unwrap_or(Value::Null)
}

fn connected_tiles(count: usize, constraints: &[Constraint]) -> Vec<bool> {
    let mut adjacency = vec![Vec::<usize>::new(); count];
    for edge in constraints {
        adjacency[edge.from].push(edge.to);
        adjacency[edge.to].push(edge.from);
    }
    let mut seen = vec![false; count];
    let mut queue = VecDeque::from([0]);
    seen[0] = true;
    while let Some(index) = queue.pop_front() {
        for &neighbor in &adjacency[index] {
            if !seen[neighbor] {
                seen[neighbor] = true;
                queue.push_back(neighbor);
            }
        }
    }
    seen
}

fn root_anchored_visual_tiles(count: usize, constraints: &[Constraint]) -> Vec<bool> {
    let mut seen = connected_tiles(count, constraints);
    if !constraints
        .iter()
        .any(|edge| edge.from == 0 || edge.to == 0)
    {
        seen.fill(false);
    }
    seen
}

fn correspondence_coverage(points: &[[f64; 4]], req: &Request) -> (usize, usize, f64) {
    let mut source = 0u16;
    let mut target = 0u16;
    for point in points {
        let cell = |x: f64, y: f64| -> Option<usize> {
            if !x.is_finite()
                || !y.is_finite()
                || x < 0.0
                || y < 0.0
                || x >= req.source_width as f64
                || y >= req.source_height as f64
            {
                return None;
            }
            let column = ((x / req.source_width as f64) * 4.0).floor() as usize;
            let row = ((y / req.source_height as f64) * 4.0).floor() as usize;
            Some(row.min(3) * 4 + column.min(3))
        };
        if let Some(index) = cell(point[0], point[1]) {
            source |= 1 << index;
        }
        if let Some(index) = cell(point[2], point[3]) {
            target |= 1 << index;
        }
    }
    let source_count = source.count_ones() as usize;
    let target_count = target.count_ones() as usize;
    // A normal overlap often occupies only two columns of the 4x4 grid. Use
    // eight cells as full credit and keep a non-zero floor so a valid blurry
    // edge remains usable when its support is spatially narrow.
    let score = 0.25 + 0.75 * (source_count.min(target_count) as f64 / 8.0).clamp(0.0, 1.0);
    (source_count, target_count, score)
}

/// Check each elementary grid loop once (O(rows*columns)). When an alternate
/// three-edge route disagrees with the fourth edge, reduce only the weakest
/// correspondence constraint in that loop. Constraints remain present, so
/// every input tile stays connected and provenance is still visual evidence.
fn weight_neighbor_loop_conflicts(
    rows: usize,
    columns: usize,
    constraints: &mut [Constraint],
    req: &Request,
) -> (
    std::collections::HashMap<(usize, usize), f64>,
    std::collections::HashMap<(usize, usize), f64>,
    std::collections::HashSet<(usize, usize)>,
) {
    use std::collections::HashMap;
    let mut indices = HashMap::with_capacity(constraints.len());
    let qualities = constraints
        .iter()
        .map(|constraint| constraint.weight)
        .collect::<Vec<_>>();
    for (index, edge) in constraints.iter().enumerate() {
        indices.insert((edge.from, edge.to), index);
    }
    let mut worst_loop = HashMap::<(usize, usize), f64>::new();
    let mut downweighted = HashMap::<(usize, usize), f64>::new();
    let mut ambiguous = std::collections::HashSet::new();
    let mut candidate_scales = HashMap::<(usize, usize), f64>::new();
    for row in 0..rows.saturating_sub(1) {
        for column in 0..columns.saturating_sub(1) {
            let top_left = row * columns + column;
            let top_right = top_left + 1;
            let bottom_left = top_left + columns;
            let bottom_right = bottom_left + 1;
            let Some(&top) = indices.get(&(top_left, top_right)) else {
                continue;
            };
            let Some(&right) = indices.get(&(top_right, bottom_right)) else {
                continue;
            };
            let Some(&bottom) = indices.get(&(bottom_left, bottom_right)) else {
                continue;
            };
            let Some(&left) = indices.get(&(top_left, bottom_left)) else {
                continue;
            };
            // The bottom and left edges point opposite to the loop traversal.
            let cycle = mul(
                mul(
                    mul(constraints[top].rotation, constraints[right].rotation),
                    inverse(constraints[bottom].rotation).unwrap_or(ID),
                ),
                inverse(constraints[left].rotation).unwrap_or(ID),
            );
            let residual = log_rotation(cycle)
                .iter()
                .map(|value| value * value)
                .sum::<f64>()
                .sqrt();
            if !residual.is_finite() {
                continue;
            }
            let pixel_equivalent = residual * ((req.fx.abs() + req.fy.abs()) * 0.5);
            for index in [top, right, bottom, left] {
                let edge = &constraints[index];
                worst_loop
                    .entry((edge.from, edge.to))
                    .and_modify(|value| *value = value.max(pixel_equivalent))
                    .or_insert(pixel_equivalent);
            }
            if pixel_equivalent <= 12.0 {
                continue;
            }
            let mut ranked = [top, right, bottom, left];
            ranked.sort_by(|a, b| qualities[*a].total_cmp(&qualities[*b]));
            let weakest = ranked[0];
            // If support evidence is nearly tied, the loop alone cannot name
            // the wrong edge. Preserve all four weights and expose ambiguity.
            let ambiguous_choice = qualities[ranked[0]] >= qualities[ranked[1]] * 0.85;
            let edge = &constraints[weakest];
            let pair = (edge.from, edge.to);
            if ambiguous_choice {
                for index in [top, right, bottom, left] {
                    ambiguous.insert((constraints[index].from, constraints[index].to));
                }
            } else {
                candidate_scales
                    .entry(pair)
                    .and_modify(|value| *value = value.min(0.05))
                    .or_insert(0.05);
            }
        }
    }
    for edge in constraints {
        if let Some(scale) = candidate_scales.get(&(edge.from, edge.to)) {
            edge.weight *= scale;
            downweighted.insert((edge.from, edge.to), *scale);
        }
    }
    ambiguous.retain(|pair| !candidate_scales.contains_key(pair));
    (worst_loop, downweighted, ambiguous)
}

/// Convert final registration weights into relative pixel-optimizer confidence.
/// This is support/residual/coverage/loop evidence, never a sharpness score.
fn reliability_scales_from_constraints(
    constraints: &[Constraint],
) -> std::collections::HashMap<(usize, usize), f64> {
    let mut weights = constraints
        .iter()
        .map(|constraint| constraint.weight)
        .collect::<Vec<_>>();
    let typical = median_value(&mut weights).unwrap_or(1.0).max(1e-9);
    constraints
        .iter()
        .map(|constraint| {
            (
                (constraint.from, constraint.to),
                (constraint.weight / typical).clamp(0.001, 1.0),
            )
        })
        .collect()
}

fn visual_components(count: usize, constraints: &[Constraint]) -> Vec<Vec<usize>> {
    let mut adjacency = vec![Vec::<usize>::new(); count];
    for edge in constraints {
        adjacency[edge.from].push(edge.to);
        adjacency[edge.to].push(edge.from);
    }
    for neighbors in &mut adjacency {
        neighbors.sort_unstable();
        neighbors.dedup();
    }
    let mut seen = vec![false; count];
    let mut components = Vec::new();
    for start in 0..count {
        if seen[start] {
            continue;
        }
        seen[start] = true;
        let mut queue = VecDeque::from([start]);
        let mut component = Vec::new();
        while let Some(index) = queue.pop_front() {
            component.push(index);
            for &neighbor in &adjacency[index] {
                if !seen[neighbor] {
                    seen[neighbor] = true;
                    queue.push_back(neighbor);
                }
            }
        }
        component.sort_unstable();
        components.push(component);
    }
    components
}

fn touches_forced_grid_cell(from: usize, to: usize, forced: &[bool]) -> bool {
    forced.get(from).copied().unwrap_or(false) || forced.get(to).copied().unwrap_or(false)
}

fn synthesize_grid_constraints(
    rows: usize,
    columns: usize,
    visual: &[Constraint],
    root_visual_component: &[bool],
    nominal_horizontal: Option<Mat>,
    nominal_vertical: Option<Mat>,
    maximum_horizontal_step: f64,
    maximum_vertical_step: f64,
) -> std::result::Result<
    (
        Vec<Constraint>,
        Vec<Value>,
        Option<GridStep>,
        Option<GridStep>,
    ),
    String,
> {
    let mut horizontal_by_row = vec![Vec::<Mat>::new(); rows];
    let mut vertical_by_column = vec![Vec::<Mat>::new(); columns];
    let mut all_horizontal = Vec::<Mat>::new();
    let mut all_vertical = Vec::<Mat>::new();
    for edge in visual {
        let from_row = edge.from / columns;
        let from_column = edge.from % columns;
        let to_row = edge.to / columns;
        let to_column = edge.to % columns;
        if from_row == to_row && to_column == from_column + 1 {
            let row = edge.from / columns;
            horizontal_by_row[row].push(edge.rotation);
            all_horizontal.push(edge.rotation);
        } else if from_column == to_column && to_row == from_row + 1 {
            let column = edge.from % columns;
            vertical_by_column[column].push(edge.rotation);
            all_vertical.push(edge.rotation);
        }
    }
    let usable = |step: &GridStep, maximum: f64| {
        let angle = log_rotation(step.rotation)
            .iter()
            .map(|value| value * value)
            .sum::<f64>()
            .sqrt();
        angle.is_finite() && angle > 1e-6 && angle < maximum
    };
    let mut horizontal_fallback =
        robust_grid_step(&all_horizontal).filter(|step| usable(step, maximum_horizontal_step));
    let mut vertical_fallback =
        robust_grid_step(&all_vertical).filter(|step| usable(step, maximum_vertical_step));
    if horizontal_fallback.is_none() {
        horizontal_fallback = nominal_horizontal.map(|rotation| GridStep {
            rotation,
            sample_count: 0,
            robust_rms_radians: 0.0,
            source: "nominalFovOverlap",
        });
    }
    if vertical_fallback.is_none() {
        vertical_fallback = nominal_vertical.map(|rotation| GridStep {
            rotation,
            sample_count: 0,
            robust_rms_radians: 0.0,
            source: "nominalFovOverlap",
        });
    }
    let row_steps = horizontal_by_row
        .iter()
        .map(|samples| {
            robust_grid_step(samples)
                .filter(|step| usable(step, maximum_horizontal_step))
                .or_else(|| horizontal_fallback.clone())
        })
        .collect::<Vec<_>>();
    let column_steps = vertical_by_column
        .iter()
        .map(|samples| {
            robust_grid_step(samples)
                .filter(|step| usable(step, maximum_vertical_step))
                .or_else(|| vertical_fallback.clone())
        })
        .collect::<Vec<_>>();
    if columns > 1 && horizontal_fallback.is_none() {
        return Err("grid-assisted placement needs at least one reliable visual horizontal neighbor rotation".into());
    }
    if rows > 1 && vertical_fallback.is_none() {
        return Err(
            "grid-assisted placement needs at least one reliable visual vertical neighbor rotation"
                .into(),
        );
    }

    let has_edge =
        |from: usize, to: usize| visual.iter().any(|edge| edge.from == from && edge.to == to);
    let mut synthesized = Vec::new();
    let mut diagnostics = Vec::new();
    let mut visual_weights = visual
        .iter()
        .map(|edge| edge.weight)
        .filter(|weight| weight.is_finite())
        .collect::<Vec<_>>();
    let typical_visual_weight = median_value(&mut visual_weights).unwrap_or(1.0);
    let estimated_weight = (typical_visual_weight * 0.001).clamp(1e-5, 0.01);
    for row in 0..rows {
        for column in 0..columns {
            let from = row * columns + column;
            let mut neighbors = Vec::with_capacity(2);
            if column + 1 < columns {
                neighbors.push((from + 1, &row_steps[row], "horizontal"));
            }
            if row + 1 < rows {
                neighbors.push((from + columns, &column_steps[column], "vertical"));
            }
            for (to, step, direction) in neighbors {
                if has_edge(from, to) {
                    continue;
                }
                if root_visual_component[from] && root_visual_component[to] {
                    continue;
                }
                let Some(step) = step else {
                    return Err(format!(
                        "grid-assisted placement has no reliable {direction} rotation for neighbor edge {from}->{to}"
                    ));
                };
                synthesized.push(Constraint {
                    from,
                    to,
                    rotation: step.rotation,
                    weight: estimated_weight,
                });
                diagnostics.push(json!({
                    "from": from,
                    "to": to,
                    "direction": direction,
                    "rotationSource": step.source,
                    "sampleCount": step.sample_count,
                    "robustRmsRadians": if step.source == "nominalFovOverlap" { Value::Null } else { json!(step.robust_rms_radians) }
                }));
            }
        }
    }
    Ok((
        synthesized,
        diagnostics,
        horizontal_fallback,
        vertical_fallback,
    ))
}
fn exp_rotation(v: [f64; 3]) -> Mat {
    let a = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    if a < 1e-10 {
        return normalize_rotation([1., -v[2], v[1], v[2], 1., -v[0], -v[1], v[0], 1.])
            .unwrap_or(ID);
    }
    let (s, c) = (a.sin() / a, a.cos());
    let (x, y, z) = (v[0], v[1], v[2]);
    [
        c + x * x * (1. - c) / (a * a),
        x * y * (1. - c) / (a * a) - z * s,
        x * z * (1. - c) / (a * a) + y * s,
        y * x * (1. - c) / (a * a) + z * s,
        c + y * y * (1. - c) / (a * a),
        y * z * (1. - c) / (a * a) - x * s,
        z * x * (1. - c) / (a * a) - y * s,
        z * y * (1. - c) / (a * a) + x * s,
        c + z * z * (1. - c) / (a * a),
    ]
}
fn solve_orientations(count: usize, constraints: &[Constraint]) -> Option<Vec<Mat>> {
    if count == 0 {
        return None;
    }
    let mut adjacency = vec![Vec::<(usize, Mat)>::new(); count];
    for e in constraints {
        adjacency.get_mut(e.from)?.push((e.to, e.rotation));
        adjacency
            .get_mut(e.to)?
            .push((e.from, transpose(e.rotation)));
    }
    let mut poses = vec![ID; count];
    let mut seen = vec![false; count];
    let mut q = VecDeque::from([0]);
    seen[0] = true;
    while let Some(i) = q.pop_front() {
        for &(j, rot) in &adjacency[i] {
            if !seen[j] {
                poses[j] = mul(poses[i], rot);
                seen[j] = true;
                q.push_back(j);
            }
        }
    }
    if seen.iter().any(|v| !*v) {
        return None;
    }
    // Robust global rotation averaging with an anchored reference camera.
    const HUBER_ANGLE_RAD: f64 = 0.01;
    for _ in 0..40 {
        let mut max_step: f64 = 0.;
        for i in 1..count {
            let mut delta = [0.; 3];
            let mut total = 0.;
            for e in constraints {
                let candidate = if e.from == i {
                    Some(mul(poses[e.to], transpose(e.rotation)))
                } else if e.to == i {
                    Some(mul(poses[e.from], e.rotation))
                } else {
                    None
                };
                if let Some(candidate) = candidate {
                    let v = log_rotation(mul(transpose(poses[i]), candidate));
                    let angle = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
                    let robust_weight = e.weight
                        * if angle > HUBER_ANGLE_RAD {
                            HUBER_ANGLE_RAD / angle
                        } else {
                            1.0
                        };
                    for k in 0..3 {
                        delta[k] += v[k] * robust_weight;
                    }
                    total += robust_weight;
                }
            }
            if total > 0. {
                for d in &mut delta {
                    *d /= total;
                }
                let step = (delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]).sqrt();
                max_step = max_step.max(step);
                poses[i] = normalize_rotation(mul(poses[i], exp_rotation(delta)))?;
            }
        }
        if max_step < 1e-8 {
            break;
        }
    }
    Some(poses)
}

fn rotation_angle(rotation: Mat) -> f64 {
    let residual = log_rotation(rotation);
    residual
        .iter()
        .map(|value| value * value)
        .sum::<f64>()
        .sqrt()
}

fn component_constraint_rms(corrections: &[Mat], constraints: &[Constraint]) -> f64 {
    let (weighted_squared, total_weight) =
        constraints
            .iter()
            .fold((0.0, 0.0), |(weighted_squared, total_weight), edge| {
                let residual = mul(
                    transpose(corrections[edge.to]),
                    mul(corrections[edge.from], edge.rotation),
                );
                let angle = rotation_angle(residual);
                (
                    weighted_squared + edge.weight * angle * angle,
                    total_weight + edge.weight,
                )
            });
    if total_weight <= 0.0 {
        0.0
    } else {
        (weighted_squared / total_weight).sqrt()
    }
}

#[derive(Debug)]
struct ComponentPoseSolve {
    corrections: Vec<Mat>,
    iterations: usize,
    converged: bool,
    termination_reason: &'static str,
    final_max_step_radians: f64,
    final_objective: f64,
    final_gradient_norm: f64,
    pcg_iterations: usize,
    max_pcg_relative_residual: f64,
    pcg_failed_attempts: usize,
}

fn component_residual(corrections: &[Mat], edge: &Constraint) -> [f64; 3] {
    component_residual_with_override(corrections, edge, None)
}

fn component_residual_with_override(
    corrections: &[Mat],
    edge: &Constraint,
    override_pose: Option<(usize, Mat)>,
) -> [f64; 3] {
    let pose = |index: usize| match override_pose {
        Some((override_index, rotation)) if index == override_index => rotation,
        _ => corrections[index],
    };
    log_rotation(mul(
        transpose(pose(edge.to)),
        mul(pose(edge.from), edge.rotation),
    ))
}

fn component_huber_objective(corrections: &[Mat], constraints: &[Constraint]) -> f64 {
    constraints.iter().fold(0.0, |cost, edge| {
        let residual = component_residual(corrections, edge);
        let radius = residual
            .iter()
            .map(|value| value * value)
            .sum::<f64>()
            .sqrt();
        let robust_cost = if radius <= GRID_COMPONENT_HUBER_ANGLE_RAD {
            0.5 * radius * radius
        } else {
            GRID_COMPONENT_HUBER_ANGLE_RAD * (radius - 0.5 * GRID_COMPONENT_HUBER_ANGLE_RAD)
        };
        cost + edge.weight * robust_cost
    })
}

fn component_huber_objective_checked(
    corrections: &[Mat],
    constraints: &[Constraint],
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<f64, Error> {
    let mut cost = 0.0;
    for (edge_index, edge) in constraints.iter().enumerate() {
        if edge_index % 64 == 0 {
            checkpoint("grid-component-pose-cost").map_err(|_| Error::Cancelled)?;
        }
        let residual = component_residual(corrections, edge);
        let radius = residual
            .iter()
            .map(|value| value * value)
            .sum::<f64>()
            .sqrt();
        let robust_cost = if radius <= GRID_COMPONENT_HUBER_ANGLE_RAD {
            0.5 * radius * radius
        } else {
            GRID_COMPONENT_HUBER_ANGLE_RAD * (radius - 0.5 * GRID_COMPONENT_HUBER_ANGLE_RAD)
        };
        cost += edge.weight * robust_cost;
    }
    Ok(cost)
}

fn assemble_component_normal_equations(
    corrections: &[Mat],
    constraints: &[Constraint],
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<(NormalMatrix, Vec<f64>, f64), Error> {
    // Component zero is the fixed gauge anchor. The remaining components each
    // have three left-multiplicative rotation parameters.
    let variable_count = corrections.len().saturating_sub(1);
    let dimension = variable_count.checked_mul(3).ok_or_else(|| {
        Error::Registration("component normal equation dimensions overflow".into())
    })?;
    let mut normal = NormalMatrix::new(dimension)?;
    let mut rhs = Vec::new();
    rhs.try_reserve_exact(dimension).map_err(|_| {
        Error::Registration(format!(
            "could not allocate component normal right-hand side with {dimension} values"
        ))
    })?;
    rhs.resize(dimension, 0.0);
    let epsilon = 1e-6;
    for (edge_index, edge) in constraints.iter().enumerate() {
        if edge_index % 64 == 0 {
            checkpoint("grid-component-pose-assembly").map_err(|_| Error::Cancelled)?;
        }
        let residual = component_residual(corrections, edge);
        let radius = residual
            .iter()
            .map(|value| value * value)
            .sum::<f64>()
            .sqrt();
        let robust_weight = edge.weight
            * if radius > GRID_COMPONENT_HUBER_ANGLE_RAD {
                GRID_COMPONENT_HUBER_ANGLE_RAD / radius
            } else {
                1.0
            };
        let mut jacobians = [[[0.0; 3]; 3]; 2];
        for (side, tile) in [edge.from, edge.to].into_iter().enumerate() {
            if tile == 0 {
                continue;
            }
            let original = corrections[tile];
            for axis in 0..3 {
                let mut perturbation = [0.0; 3];
                perturbation[axis] = epsilon;
                let positive = normalize_rotation(mul(exp_rotation(perturbation), original))
                    .ok_or_else(|| {
                        Error::Registration(
                            "component pose Jacobian produced invalid rotation".into(),
                        )
                    })?;
                perturbation[axis] = -epsilon;
                let negative = normalize_rotation(mul(exp_rotation(perturbation), original))
                    .ok_or_else(|| {
                        Error::Registration(
                            "component pose Jacobian produced invalid rotation".into(),
                        )
                    })?;
                let positive_residual =
                    component_residual_with_override(corrections, edge, Some((tile, positive)));
                let negative_residual =
                    component_residual_with_override(corrections, edge, Some((tile, negative)));
                for component in 0..3 {
                    jacobians[side][component][axis] = (positive_residual[component]
                        - negative_residual[component])
                        / (2.0 * epsilon);
                }
            }
        }
        let tiles = [edge.from, edge.to];
        for lhs_side in 0..2 {
            let lhs_tile = tiles[lhs_side];
            if lhs_tile == 0 {
                continue;
            }
            let lhs_variable = (lhs_tile - 1) * 3;
            for lhs_axis in 0..3 {
                let lhs_scalar = lhs_variable + lhs_axis;
                let gradient = (0..3)
                    .map(|component| jacobians[lhs_side][component][lhs_axis] * residual[component])
                    .sum::<f64>()
                    * robust_weight;
                rhs[lhs_scalar] -= gradient;
                for rhs_side in 0..2 {
                    let rhs_tile = tiles[rhs_side];
                    if rhs_tile == 0 {
                        continue;
                    }
                    let rhs_variable = (rhs_tile - 1) * 3;
                    for rhs_axis in 0..3 {
                        let rhs_scalar = rhs_variable + rhs_axis;
                        let hessian = (0..3)
                            .map(|component| {
                                jacobians[lhs_side][component][lhs_axis]
                                    * jacobians[rhs_side][component][rhs_axis]
                            })
                            .sum::<f64>()
                            * robust_weight;
                        normal.add(lhs_scalar, rhs_scalar, hessian)?;
                    }
                }
            }
        }
    }
    // A vanishingly small LM diagonal stabilizes near-singular, weakly bridged
    // groups without materially changing their weighted least-squares target.
    for index in 0..dimension {
        normal.add(index, index, 1e-12)?;
    }
    // The gradient is the accumulated node gradient. Summing squared
    // per-edge contributions would miss the cancellation at a true optimum.
    let gradient_norm = rhs.iter().map(|value| value * value).sum::<f64>().sqrt();
    Ok((normal, rhs, gradient_norm))
}

fn solve_component_corrections(
    count: usize,
    constraints: &[Constraint],
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<Option<ComponentPoseSolve>, Error> {
    if count == 0 {
        return Ok(None);
    }
    let mut adjacency = vec![Vec::<(usize, Mat, f64)>::new(); count];
    for edge in constraints {
        if edge.from >= count || edge.to >= count || edge.weight <= 0.0 {
            return Ok(None);
        }
        adjacency[edge.from].push((edge.to, edge.rotation, edge.weight));
        adjacency[edge.to].push((edge.from, transpose(edge.rotation), edge.weight));
    }
    let mut corrections = vec![ID; count];
    let mut seen = vec![false; count];
    let mut queue = VecDeque::from([0]);
    seen[0] = true;
    while let Some(component) = queue.pop_front() {
        checkpoint("grid-component-pose-initialize").map_err(|_| Error::Cancelled)?;
        for &(neighbor, rotation, _) in &adjacency[component] {
            if !seen[neighbor] {
                corrections[neighbor] = normalize_rotation(mul(corrections[component], rotation))
                    .ok_or_else(|| {
                    Error::Registration(
                        "grid component initialization produced an invalid rotation".into(),
                    )
                })?;
                seen[neighbor] = true;
                queue.push_back(neighbor);
            }
        }
    }
    if seen.iter().any(|value| !*value) {
        return Ok(None);
    }

    let mut completed_iterations = 0;
    let mut converged = false;
    let mut termination_reason = "iteration_limit";
    let mut final_max_step_radians: f64 = 0.0;
    let mut pcg_iterations = 0;
    let mut max_pcg_relative_residual: f64 = 0.0;
    let mut pcg_failed_attempts = 0;
    for _ in 0..MAX_GRID_COMPONENT_POSE_ITERATIONS {
        checkpoint("grid-component-pose-sweep").map_err(|_| Error::Cancelled)?;
        let (normal, rhs, gradient_norm) =
            assemble_component_normal_equations(&corrections, constraints, checkpoint)?;
        if gradient_norm <= 1e-10 {
            converged = true;
            termination_reason = "gradient_tolerance";
            break;
        }
        let dimension = rhs.len();
        let pcg = solve_pcg(&normal, &rhs, dimension, checkpoint)?;
        pcg_iterations += pcg.iterations;
        max_pcg_relative_residual = max_pcg_relative_residual.max(pcg.relative_residual);
        if !pcg.converged || pcg.relative_residual > 1e-8 {
            pcg_failed_attempts += 1;
            termination_reason = "linear_solve_residual_unacceptable";
            break;
        }
        let Some(delta) = pcg.delta else {
            pcg_failed_attempts += 1;
            termination_reason = "linear_solve_failed";
            break;
        };
        let mut full_step: Vec<[f64; 3]> = vec![[0.0; 3]; count];
        for component in 1..count {
            full_step[component].copy_from_slice(&delta[(component - 1) * 3..component * 3]);
        }
        let proposed_max_step = full_step
            .iter()
            .skip(1)
            .map(|step| step.iter().map(|value| value * value).sum::<f64>().sqrt())
            .fold(0.0_f64, f64::max);
        final_max_step_radians = proposed_max_step;
        if proposed_max_step <= GRID_COMPONENT_STEP_TOLERANCE_RAD {
            converged = true;
            termination_reason = "step_tolerance";
            break;
        }
        let current_objective =
            component_huber_objective_checked(&corrections, constraints, checkpoint)?;
        let mut accepted = false;
        let mut alpha = 1.0;
        for _ in 0..12 {
            checkpoint("grid-component-pose-line-search").map_err(|_| Error::Cancelled)?;
            let mut candidate = corrections.clone();
            for component in 1..count {
                let scaled = full_step[component].map(|value| value * alpha);
                candidate[component] =
                    normalize_rotation(mul(exp_rotation(scaled), corrections[component]))
                        .ok_or_else(|| {
                            Error::Registration(
                                "grid component GN update produced an invalid rotation".into(),
                            )
                        })?;
            }
            let candidate_objective =
                component_huber_objective_checked(&candidate, constraints, checkpoint)?;
            if candidate_objective + 1e-14 < current_objective {
                corrections = candidate;
                final_max_step_radians = proposed_max_step * alpha;
                accepted = true;
                break;
            }
            alpha *= 0.5;
        }
        completed_iterations += 1;
        if !accepted {
            if proposed_max_step <= 10.0 * GRID_COMPONENT_STEP_TOLERANCE_RAD {
                converged = true;
                termination_reason = "objective_tolerance";
            } else {
                termination_reason = "no_decreasing_line_search_step";
            }
            break;
        }
    }
    let final_objective = component_huber_objective_checked(&corrections, constraints, checkpoint)?;
    let (_, _, final_gradient_norm) =
        assemble_component_normal_equations(&corrections, constraints, checkpoint)?;
    if final_gradient_norm <= 1e-10 {
        converged = true;
        termination_reason = "gradient_tolerance";
    }
    if !converged && completed_iterations == MAX_GRID_COMPONENT_POSE_ITERATIONS {
        termination_reason = "iteration_limit";
    }
    Ok(Some(ComponentPoseSolve {
        corrections,
        iterations: completed_iterations,
        converged,
        termination_reason,
        final_max_step_radians,
        final_objective,
        final_gradient_norm,
        pcg_iterations,
        max_pcg_relative_residual,
        pcg_failed_attempts,
    }))
}

fn refine_grid_component_poses(
    poses: &mut [Mat],
    visual_constraints: &[Constraint],
    grid_constraints: &[Constraint],
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<Value, Error> {
    let components = visual_components(poses.len(), visual_constraints);
    let mut component_by_tile = vec![0usize; poses.len()];
    let mut visual_edge_counts = vec![0usize; components.len()];
    for (component_id, members) in components.iter().enumerate() {
        for &tile in members {
            component_by_tile[tile] = component_id;
        }
    }
    for edge in visual_constraints {
        visual_edge_counts[component_by_tile[edge.from]] += 1;
    }
    let anchor_component = (0..components.len())
        .max_by_key(|component| {
            (
                visual_edge_counts[*component] > 0,
                visual_edge_counts[*component],
                components[*component].len(),
                std::cmp::Reverse(components[*component][0]),
            )
        })
        .unwrap_or(0);
    let mut component_order = Vec::with_capacity(components.len());
    component_order.push(anchor_component);
    component_order
        .extend((0..components.len()).filter(|component| *component != anchor_component));
    let mut ordered_component = vec![0usize; components.len()];
    for (ordered, &original) in component_order.iter().enumerate() {
        ordered_component[original] = ordered;
    }

    let mut corrections = Vec::new();
    for edge in grid_constraints {
        let from_component = component_by_tile[edge.from];
        let to_component = component_by_tile[edge.to];
        if from_component == to_component {
            continue;
        }
        // A left-multiplied rigid component correction D must satisfy
        // D_to = D_from * (P_from * gridStep * P_to^T).
        let relative_correction = mul(
            mul(poses[edge.from], edge.rotation),
            transpose(poses[edge.to]),
        );
        corrections.push(Constraint {
            from: ordered_component[from_component],
            to: ordered_component[to_component],
            rotation: relative_correction,
            weight: edge.weight.max(1e-8),
        });
    }

    if corrections.is_empty() || components.len() <= 1 {
        return Ok(json!({
            "applied": false,
            "reason": "no_cross_component_grid_bridges",
            "stage": "after_joint_leave_one_out_before_source_plane_warp",
            "converged": true,
            "componentCount": components.len(),
            "bridgeConstraintCount": corrections.len(),
            "anchorComponentId": anchor_component,
            "anchorTileIndex": components[anchor_component][0]
        }));
    }
    let before_rms = component_constraint_rms(&vec![ID; components.len()], &corrections);
    let before_objective = component_huber_objective(&vec![ID; components.len()], &corrections);
    let Some(solve) = solve_component_corrections(components.len(), &corrections, checkpoint)?
    else {
        return Ok(json!({
            "applied": false,
            "reason": "cross_component_bridge_graph_disconnected",
            "componentCount": components.len(),
            "bridgeConstraintCount": corrections.len(),
            "anchorComponentId": anchor_component,
            "anchorTileIndex": components[anchor_component][0],
            "converged": false,
            "beforeBridgeCorrectionRmsRadians": before_rms
        }));
    };
    let component_corrections = &solve.corrections;
    let converged = solve.converged;
    let after_rms = component_constraint_rms(&component_corrections, &corrections);
    let improved = converged && after_rms + 1e-10 < before_rms;
    let mut adjusted_components = 0usize;
    let mut maximum_correction_radians: f64 = 0.0;
    if improved {
        for (ordered_component_id, &component_id) in component_order.iter().enumerate() {
            let correction = component_corrections[ordered_component_id];
            let angle = rotation_angle(correction);
            maximum_correction_radians = maximum_correction_radians.max(angle);
            if angle > 1e-9 {
                adjusted_components += 1;
                for &tile in &components[component_id] {
                    poses[tile] =
                        normalize_rotation(mul(correction, poses[tile])).ok_or_else(|| {
                            Error::Registration(
                                "grid component pose correction produced an invalid rotation"
                                    .into(),
                            )
                        })?;
                }
            }
        }
    }
    let component_diagnostics = component_order
        .iter()
        .enumerate()
        .map(|(ordered_id, &component_id)| {
            let correction = component_corrections[ordered_id];
            json!({
                "componentId":component_id,
                "tileIndices":components[component_id],
                "anchor":component_id == anchor_component,
                "correctionRadians":if improved { rotation_angle(correction) } else { 0.0 }
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "applied": improved && adjusted_components > 0,
        "reason": if improved { "cross_component_bridge_residual_reduced" } else if !converged { "component_bridge_refinement_not_converged" } else { "no_bridge_objective_improvement" },
        "stage": "after_joint_leave_one_out_before_source_plane_warp",
        "componentCount": components.len(),
        "bridgeConstraintCount": corrections.len(),
        "anchorComponentId": anchor_component,
        "anchorTileIndex": components[anchor_component][0],
        "anchorVisualEdgeCount": visual_edge_counts[anchor_component],
        "adjustedComponentCount": if improved { adjusted_components } else { 0 },
        "maxCorrectionRadians": if improved { maximum_correction_radians } else { 0.0 },
        "iterations": solve.iterations,
        "converged": converged,
        "terminationReason": solve.termination_reason,
        "finalMaxStepRadians": solve.final_max_step_radians,
        "finalGradientNorm": solve.final_gradient_norm,
        "initialHuberObjective": before_objective,
        "finalHuberObjective": solve.final_objective,
        "pcgIterations": solve.pcg_iterations,
        "maxPcgRelativeResidual": solve.max_pcg_relative_residual,
        "pcgFailedAttempts": solve.pcg_failed_attempts,
        "normalMatrixStorage":"denseF64WithSparsePcgMatVec",
        "normalMatrixBytes":((components.len().saturating_sub(1)*3).pow(2)*std::mem::size_of::<f64>()),
        "beforeBridgeCorrectionRmsRadians": before_rms,
        "afterBridgeCorrectionRmsRadians": after_rms,
        "acceptedTextureEdgesWithinComponentsRemainRigid": true,
        "componentDiagnostics": component_diagnostics,
        "bridgeConstraintReplay": corrections.iter().map(|edge| json!({
            "fromComponent":edge.from,
            "toComponent":edge.to,
            "relativeCorrectionRotation":edge.rotation,
            "weight":edge.weight
        })).collect::<Vec<_>>()
    }))
}

fn camera_ray(x: f64, y: f64, req: &Request) -> [f64; 3] {
    let mut ray = [(x - req.cx) / req.fx, -(y - req.cy) / req.fy, 1.0];
    let norm = (ray[0] * ray[0] + ray[1] * ray[1] + 1.0).sqrt();
    for value in &mut ray {
        *value /= norm;
    }
    ray
}

fn project_ray(ray: [f64; 3], req: &Request) -> Option<(f64, f64)> {
    project_camera_ray(ray, req)
}

fn edge_pixel_residuals(
    poses: &[Mat],
    edge: &crate::pipeline::SphericalMatchEdge,
    req: &Request,
) -> Option<Vec<[f64; 4]>> {
    edge.points
        .iter()
        .map(|point| edge_point_pixel_residual(poses, edge, point, req))
        .collect()
}

fn edge_point_pixel_residual(
    poses: &[Mat],
    edge: &crate::pipeline::SphericalMatchEdge,
    point: &[f64; 4],
    req: &Request,
) -> Option<[f64; 4]> {
    let relative = mul(transpose(poses[edge.to]), poses[edge.from]);
    let source = camera_ray(point[0], point[1], req);
    let target = camera_ray(point[2], point[3], req);
    let forward = project_ray(mul_vec(relative, source), req)?;
    let backward = project_ray(mul_vec(transpose(relative), target), req)?;
    Some([
        forward.0 - point[2],
        forward.1 - point[3],
        backward.0 - point[0],
        backward.1 - point[1],
    ])
}

fn huber_cost(radius: f64, threshold: f64) -> f64 {
    if radius <= threshold {
        0.5 * radius * radius
    } else {
        threshold * (radius - 0.5 * threshold)
    }
}

#[cfg(test)]
fn incident_pixel_cost(
    poses: &[Mat],
    tile: usize,
    edges: &[&crate::pipeline::SphericalMatchEdge],
    req: &Request,
) -> f64 {
    let mut cost = 0.0;
    for edge in edges
        .iter()
        .filter(|edge| edge.from == tile || edge.to == tile)
    {
        let Some(residuals) = edge_pixel_residuals(poses, edge, req) else {
            return f64::INFINITY;
        };
        cost += residuals
            .into_iter()
            .map(|residual| {
                huber_cost(residual[0].hypot(residual[1]), 3.0)
                    + huber_cost(residual[2].hypot(residual[3]), 3.0)
            })
            .sum::<f64>();
    }
    cost
}

#[cfg(test)]
fn visual_pixel_huber_cost(
    poses: &[Mat],
    edges: &[&crate::pipeline::SphericalMatchEdge],
    req: &Request,
) -> f64 {
    visual_pixel_huber_cost_with_reliability(poses, edges, req, &std::collections::HashMap::new())
}

fn visual_pixel_huber_cost_with_reliability(
    poses: &[Mat],
    edges: &[&crate::pipeline::SphericalMatchEdge],
    req: &Request,
    reliability_scales: &std::collections::HashMap<(usize, usize), f64>,
) -> f64 {
    let mut cost = 0.0;
    for edge in edges {
        let Some(residuals) = edge_pixel_residuals(poses, edge, req) else {
            return f64::INFINITY;
        };
        let reliability = reliability_scales
            .get(&(edge.from, edge.to))
            .copied()
            .unwrap_or(1.0);
        cost += reliability
            * residuals
                .into_iter()
                .map(|residual| {
                    huber_cost(residual[0].hypot(residual[1]), 3.0)
                        + huber_cost(residual[2].hypot(residual[3]), 3.0)
                })
                .sum::<f64>();
    }
    cost
}

fn edge_pixel_rms(
    poses: &[Mat],
    edge: &crate::pipeline::SphericalMatchEdge,
    req: &Request,
) -> Option<f64> {
    let residuals = edge_pixel_residuals(poses, edge, req)?;
    let squared = residuals
        .iter()
        .map(|residual| {
            residual[0] * residual[0]
                + residual[1] * residual[1]
                + residual[2] * residual[2]
                + residual[3] * residual[3]
        })
        .sum::<f64>();
    Some((squared / (2 * residuals.len()).max(1) as f64).sqrt())
}

// The minimum of one is an intentional exception to the 5% cap for components
// with fewer than 20 visual edges; it permits at most one repair attempt.
fn cycle_prune_budget(component_visual_edge_count: usize) -> usize {
    (component_visual_edge_count / 20).max(1)
}

fn visual_edge_has_alternate_path(
    tile_count: usize,
    constraints: &[Constraint],
    excluded_index: usize,
) -> bool {
    let excluded = &constraints[excluded_index];
    let mut seen = vec![false; tile_count];
    let mut queue = VecDeque::from([excluded.from]);
    seen[excluded.from] = true;
    while let Some(tile) = queue.pop_front() {
        for (index, edge) in constraints.iter().enumerate() {
            if index == excluded_index {
                continue;
            }
            let neighbor = if edge.from == tile {
                Some(edge.to)
            } else if edge.to == tile {
                Some(edge.from)
            } else {
                None
            };
            if let Some(neighbor) = neighbor {
                if neighbor == excluded.to {
                    return true;
                }
                if !seen[neighbor] {
                    seen[neighbor] = true;
                    queue.push_back(neighbor);
                }
            }
        }
    }
    false
}

#[cfg(test)]
fn prune_cycle_inconsistent_visual_edges(
    poses: &mut [Mat],
    visual_constraints: &mut Vec<Constraint>,
    _grid_constraints: &[Constraint],
    matched_edges: &[crate::pipeline::SphericalMatchEdge],
    req: &Request,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<(Vec<Value>, bool, Option<Value>), Error> {
    let outcome = prune_visual_edges_with_joint_leave_one_out(
        poses,
        visual_constraints,
        matched_edges,
        req,
        checkpoint,
        None,
    )?;
    Ok((
        outcome.rejected_edges,
        outcome.budget_exceeded,
        outcome.final_refinement,
    ))
}
struct JointPruneOutcome {
    rejected_edges: Vec<Value>,
    evaluations: Vec<Value>,
    budget_exceeded: bool,
    final_refinement: Option<Value>,
}

#[cfg(test)]
fn prune_visual_edges_with_joint_leave_one_out(
    poses: &mut [Mat],
    visual_constraints: &mut Vec<Constraint>,
    matched_edges: &[crate::pipeline::SphericalMatchEdge],
    req: &Request,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
    candidate_filter: Option<&std::collections::HashSet<(usize, usize)>>,
) -> std::result::Result<JointPruneOutcome, Error> {
    prune_visual_edges_with_joint_leave_one_out_weighted(
        poses,
        visual_constraints,
        matched_edges,
        req,
        checkpoint,
        candidate_filter,
        &std::collections::HashMap::new(),
    )
}

fn prune_visual_edges_with_joint_leave_one_out_weighted(
    poses: &mut [Mat],
    visual_constraints: &mut Vec<Constraint>,
    matched_edges: &[crate::pipeline::SphericalMatchEdge],
    req: &Request,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
    candidate_filter: Option<&std::collections::HashSet<(usize, usize)>>,
    reliability_scales: &std::collections::HashMap<(usize, usize), f64>,
) -> std::result::Result<JointPruneOutcome, Error> {
    let mut outcome = JointPruneOutcome {
        rejected_edges: Vec::new(),
        evaluations: Vec::new(),
        budget_exceeded: false,
        final_refinement: None,
    };
    if visual_constraints.is_empty() {
        return Ok(outcome);
    }
    let original_constraints = visual_constraints.clone();
    let original_poses = poses.to_vec();
    let components = visual_components(poses.len(), visual_constraints);
    let mut component_by_tile = vec![0usize; poses.len()];
    let mut component_edge_counts = vec![0usize; components.len()];
    for (component_id, component) in components.iter().enumerate() {
        for &tile in component {
            component_by_tile[tile] = component_id;
        }
    }
    for edge in visual_constraints.iter() {
        component_edge_counts[component_by_tile[edge.from]] += 1;
    }
    let budgets = component_edge_counts
        .iter()
        .map(|count| cycle_prune_budget(*count))
        .collect::<Vec<_>>();
    let total_attempt_budget = budgets.iter().sum::<usize>().saturating_mul(3).max(3);
    let mut dropped_per_component = vec![0usize; components.len()];
    let mut candidate_attempts = 0usize;
    loop {
        checkpoint("joint-cycle-prune-round").map_err(|_| Error::Cancelled)?;
        let (before_rms, _, _, _, mut before_edges, before_complete) =
            global_reprojection_metrics(poses, visual_constraints, matched_edges, req);
        before_edges.sort_by(|a, b| b.2.total_cmp(&a.2));
        let before_worst = before_edges
            .first()
            .map(|edge| edge.2)
            .unwrap_or(f64::INFINITY);
        if candidate_filter.is_none()
            && before_complete
            && before_rms <= 12.0
            && before_worst <= 12.0
        {
            break;
        }
        let mut candidates = visual_constraints
            .iter()
            .filter_map(|constraint| {
                let edge = matched_edges
                    .iter()
                    .find(|edge| edge.from == constraint.from && edge.to == constraint.to)?;
                let current_rms = edge_pixel_rms(poses, edge, req)?;
                if candidate_filter
                    .is_some_and(|filter| !filter.contains(&(constraint.from, constraint.to)))
                {
                    return None;
                }
                if current_rms <= 12.0 {
                    return None;
                }
                let (_, _, ray_rms) =
                    fit_ray_rotation(&edge.points, req.fx, req.fy, req.cx, req.cy)?;
                let high_confidence =
                    edge.inliers >= 64 && edge.inlier_ratio >= 0.80 && ray_rms <= 3.0;
                let low_confidence = edge.inliers < 48
                    || edge.inlier_ratio < 0.80
                    || ray_rms > 6.0
                    || edge.homography_residual > 4.0;
                (low_confidence && !high_confidence).then_some((
                    constraint.from,
                    constraint.to,
                    current_rms,
                    ray_rms,
                ))
            })
            .collect::<Vec<_>>();
        candidates.sort_by(|a, b| {
            b.2.total_cmp(&a.2)
                .then_with(|| (a.0, a.1).cmp(&(b.0, b.1)))
        });
        if candidates.is_empty() {
            break;
        }
        let mut accepted_in_round = false;
        for (from, to, before_held_out_rms, ray_rms) in candidates {
            checkpoint("joint-cycle-prune-candidate").map_err(|_| Error::Cancelled)?;
            if candidate_attempts >= total_attempt_budget {
                outcome.budget_exceeded = true;
                break;
            }
            let Some(active_index) = visual_constraints
                .iter()
                .position(|edge| edge.from == from && edge.to == to)
            else {
                continue;
            };
            let component_id = component_by_tile[from];
            if dropped_per_component[component_id] >= budgets[component_id] {
                outcome.budget_exceeded = true;
                continue;
            }
            if !visual_edge_has_alternate_path(poses.len(), visual_constraints, active_index) {
                outcome.evaluations.push(json!({
                    "from":from,"to":to,"decision":"protected_bridge",
                    "currentHeldOutRmsPx":before_held_out_rms
                }));
                continue;
            }
            candidate_attempts += 1;
            let Some(held_out_edge) = matched_edges
                .iter()
                .find(|edge| edge.from == from && edge.to == to)
            else {
                continue;
            };
            let mut trial_constraints = visual_constraints.clone();
            trial_constraints.remove(active_index);
            if visual_components(poses.len(), &trial_constraints).len() != components.len() {
                outcome.evaluations.push(json!({
                    "from":from,"to":to,"decision":"rejected_component_split",
                    "currentHeldOutRmsPx":before_held_out_rms
                }));
                continue;
            }
            let trial_edges = matched_edges
                .iter()
                .filter(|edge| edge.from != from || edge.to != to)
                .cloned()
                .collect::<Vec<_>>();
            let (retained_before_rms, _, _, _, mut retained_before_edges, retained_before_complete) =
                global_reprojection_metrics(poses, &trial_constraints, &trial_edges, req);
            retained_before_edges.sort_by(|a, b| b.2.total_cmp(&a.2));
            let retained_before_worst = retained_before_edges
                .first()
                .map(|edge| edge.2)
                .unwrap_or(f64::INFINITY);
            let mut trial_poses = poses.to_vec();
            let stats = refine_visual_component_pixels_with_reliability(
                &mut trial_poses,
                &trial_constraints,
                &trial_edges,
                req,
                checkpoint,
                false,
                reliability_scales,
            )?;
            let (trial_rms, _, _, _, mut trial_edge_errors, trial_complete) =
                global_reprojection_metrics(&trial_poses, &trial_constraints, &trial_edges, req);
            trial_edge_errors.sort_by(|a, b| b.2.total_cmp(&a.2));
            let trial_worst = trial_edge_errors
                .first()
                .map(|edge| edge.2)
                .unwrap_or(f64::INFINITY);
            let held_out_rms =
                edge_pixel_rms(&trial_poses, held_out_edge, req).unwrap_or(f64::INFINITY);
            let converged =
                stats.5 && stats.8 && stats.9 == 0 && stats.11 <= 1e-3 && trial_complete;
            let held_out_conflict = held_out_rms > 12.0;
            let training_improved = retained_before_complete
                && trial_complete
                && trial_rms.is_finite()
                && retained_before_rms.is_finite()
                && trial_rms + 1e-4 < retained_before_rms
                && trial_worst <= retained_before_worst + 1e-3;
            let accepted = converged && held_out_conflict && training_improved;
            let decision = if accepted {
                "rejected_joint_loo_conflict"
            } else if !converged {
                "kept_loo_did_not_converge"
            } else if !held_out_conflict {
                "kept_heldout_not_conflicting"
            } else {
                "kept_retained_graph_not_improved"
            };
            let evaluation = json!({
                "from":from,"to":to,"decision":decision,
                "componentId":component_id,
                "currentHeldOutRmsPx":before_held_out_rms,
                "leaveOneOutHeldOutRmsPx":held_out_rms,
                "rayRmsPx":ray_rms,
                "matches":held_out_edge.matches,
                "inliers":held_out_edge.inliers,
                "inlierRatio":held_out_edge.inlier_ratio,
                "homographyResidualPx":held_out_edge.homography_residual,
                "retainedGlobalRmsBeforePx":retained_before_rms,
                "retainedGlobalRmsAfterPx":trial_rms,
                "retainedWorstEdgeRmsBeforePx":retained_before_worst,
                "retainedWorstEdgeRmsAfterPx":trial_worst,
                "retainedCorrespondenceCount":trial_edge_errors.iter().map(|edge|edge.3).sum::<usize>(),
                "jointRefinement":{"iterations":stats.4,"converged":stats.5,"pcgMaxIterations":stats.6,"pcgMaxRelativeResidual":stats.7,"pcgAllSolvesConverged":stats.8,"failedAttempts":stats.9,"denseFallbackCount":stats.10,"maxAcceptedLinearResidual":stats.11},
                "componentConnectivityPreserved":true
            });
            outcome.evaluations.push(evaluation.clone());
            if accepted {
                poses.copy_from_slice(&trial_poses);
                *visual_constraints = trial_constraints;
                dropped_per_component[component_id] += 1;
                outcome.rejected_edges.push(evaluation);
                outcome.final_refinement = Some(json!({
                    "cameraCount":stats.1,"beforeSymmetricL2NormPx":stats.2,
                    "afterSymmetricL2NormPx":stats.3,"iterations":stats.4,
                    "converged":stats.5,"pcgMaxIterations":stats.6,
                    "pcgMaxRelativeResidual":stats.7,"pcgAllSolvesConverged":stats.8,
                    "pcgFailedAttempts":stats.9,"denseCholeskyFallbackCount":stats.10,
                    "maxAcceptedLinearResidual":stats.11
                }));
                accepted_in_round = true;
                break;
            }
        }
        if outcome.budget_exceeded {
            break;
        }
        if !accepted_in_round {
            break;
        }
    }
    let (final_rms, _, _, _, final_edges, complete) =
        global_reprojection_metrics(poses, visual_constraints, matched_edges, req);
    let final_worst = final_edges
        .iter()
        .map(|edge| edge.2)
        .fold(0.0_f64, f64::max);
    if outcome.budget_exceeded && (final_rms > 12.0 || final_worst > 12.0 || !complete) {
        // The caller reports a failed registration with the surviving metrics.
    }
    if outcome.rejected_edges.is_empty() {
        poses.copy_from_slice(&original_poses);
        *visual_constraints = original_constraints;
    }
    Ok(outcome)
}

/// Refine each visual component with a joint symmetric-pixel bundle solve.
/// One camera in each component stays fixed; weak grid bridges continue to
/// place components relative to one another without distorting their interiors.
#[derive(Debug)]
struct PcgResult {
    delta: Option<Vec<f64>>,
    iterations: usize,
    relative_residual: f64,
    converged: bool,
}

type NormalBlock = [[f64; 3]; 3];

/// Neighbor graph normal equations stay dense for familiar small cases and
/// switch to sparse 3x3 blocks before quadratic storage becomes material.
enum NormalMatrix {
    Dense {
        dimension: usize,
        values: Vec<f64>,
    },
    SparseBlocks {
        dimension: usize,
        rows: Vec<Vec<(usize, NormalBlock)>>,
    },
}

impl NormalMatrix {
    fn new(dimension: usize) -> std::result::Result<Self, Error> {
        if dimension % 3 != 0 {
            return Err(Error::Registration(
                "normal matrix dimension is not a multiple of three".into(),
            ));
        }
        if dimension <= DENSE_NORMAL_MAX_DIMENSION {
            let cells = dimension.checked_mul(dimension).ok_or_else(|| {
                Error::Registration("normal matrix dimensions overflow addressable storage".into())
            })?;
            let mut values = Vec::new();
            values.try_reserve_exact(cells).map_err(|_| {
                Error::Registration(format!(
                    "could not allocate dense normal matrix with {cells} values"
                ))
            })?;
            values.resize(cells, 0.0);
            Ok(Self::Dense { dimension, values })
        } else {
            let block_rows = dimension / 3;
            let mut rows = Vec::new();
            rows.try_reserve_exact(block_rows).map_err(|_| {
                Error::Registration(format!(
                    "could not allocate {block_rows} sparse normal rows"
                ))
            })?;
            rows.resize_with(block_rows, Vec::new);
            Ok(Self::SparseBlocks { dimension, rows })
        }
    }

    fn dimension(&self) -> usize {
        match self {
            Self::Dense { dimension, .. } | Self::SparseBlocks { dimension, .. } => *dimension,
        }
    }

    fn dense(&self) -> Option<&[f64]> {
        match self {
            Self::Dense { values, .. } => Some(values),
            Self::SparseBlocks { .. } => None,
        }
    }

    fn add(&mut self, row: usize, column: usize, value: f64) -> std::result::Result<(), Error> {
        let dimension = self.dimension();
        if row >= dimension || column >= dimension || !value.is_finite() {
            return Err(Error::Registration("invalid normal matrix entry".into()));
        }
        if value == 0.0 {
            return Ok(());
        }
        match self {
            Self::Dense { values, .. } => values[row * dimension + column] += value,
            Self::SparseBlocks { rows, .. } => {
                let block_row = row / 3;
                let block_column = column / 3;
                let entries = &mut rows[block_row];
                if let Some((_, block)) =
                    entries.iter_mut().find(|(index, _)| *index == block_column)
                {
                    block[row % 3][column % 3] += value;
                } else {
                    entries.try_reserve(1).map_err(|_| Error::Registration(format!(
                        "could not allocate sparse normal block row {block_row} for edge graph storage"
                    )))?;
                    let mut block = [[0.0; 3]; 3];
                    block[row % 3][column % 3] = value;
                    entries.push((block_column, block));
                }
            }
        }
        Ok(())
    }

    fn get(&self, row: usize, column: usize) -> f64 {
        match self {
            Self::Dense { dimension, values } => values[row * dimension + column],
            Self::SparseBlocks { rows, .. } => rows[row / 3]
                .iter()
                .find(|(index, _)| *index == column / 3)
                .map_or(0.0, |(_, block)| block[row % 3][column % 3]),
        }
    }

    fn all_finite(&self) -> bool {
        match self {
            Self::Dense { values, .. } => values.iter().all(|value| value.is_finite()),
            Self::SparseBlocks { rows, .. } => rows
                .iter()
                .flat_map(|row| row.iter())
                .flat_map(|(_, block)| block.iter().flat_map(|line| line.iter()))
                .all(|value| value.is_finite()),
        }
    }

    fn apply(&self, input: &[f64]) -> std::result::Result<Vec<f64>, Error> {
        let dimension = self.dimension();
        let mut output = allocate_f64(dimension, "normal multiply result")?;
        match self {
            Self::Dense { values, .. } => {
                for row in 0..dimension {
                    let offset = row * dimension;
                    output[row] = values[offset..offset + dimension]
                        .iter()
                        .zip(input)
                        .map(|(a, b)| a * b)
                        .sum();
                }
            }
            Self::SparseBlocks { rows, .. } => {
                for (block_row, entries) in rows.iter().enumerate() {
                    for (block_column, block) in entries {
                        for row in 0..3 {
                            for column in 0..3 {
                                output[block_row * 3 + row] +=
                                    block[row][column] * input[*block_column * 3 + column];
                            }
                        }
                    }
                }
            }
        }
        Ok(output)
    }

    fn solve_diagonal_block(&self, block: usize, input: &[f64]) -> Option<[f64; 3]> {
        let mut diagonal = [[0.0; 3]; 3];
        for row in 0..3 {
            for column in 0..3 {
                diagonal[row][column] = self.get(block * 3 + row, block * 3 + column);
            }
        }
        solve_3x3(
            diagonal,
            [input[block * 3], input[block * 3 + 1], input[block * 3 + 2]],
        )
    }
}

fn allocate_f64(count: usize, what: &str) -> std::result::Result<Vec<f64>, Error> {
    let mut values = Vec::new();
    values.try_reserve_exact(count).map_err(|_| {
        Error::Registration(format!("could not allocate {what} with {count} values"))
    })?;
    values.resize(count, 0.0);
    Ok(values)
}

fn copy_f64(values: &[f64], what: &str) -> std::result::Result<Vec<f64>, Error> {
    let mut copy = Vec::new();
    copy.try_reserve_exact(values.len()).map_err(|_| {
        Error::Registration(format!(
            "could not allocate {what} with {} values",
            values.len()
        ))
    })?;
    copy.extend_from_slice(values);
    Ok(copy)
}

struct DenseSolveResult {
    delta: Option<Vec<f64>>,
    relative_residual: f64,
}

fn dense_cholesky_solve(
    matrix: &[f64],
    rhs: &[f64],
    dimension: usize,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<DenseSolveResult, Error> {
    if matrix.len() != dimension.saturating_mul(dimension) || rhs.len() != dimension {
        return Ok(DenseSolveResult {
            delta: None,
            relative_residual: f64::INFINITY,
        });
    }
    let mut lower = allocate_f64(matrix.len(), "dense Cholesky factor")?;
    for row in 0..dimension {
        if row % 16 == 0 {
            checkpoint("pixel-bundle-cholesky").map_err(|_| Error::Cancelled)?;
        }
        for column in 0..=row {
            let mut value = matrix[row * dimension + column];
            for k in 0..column {
                value -= lower[row * dimension + k] * lower[column * dimension + k];
            }
            if row == column {
                if !value.is_finite() || value <= 1e-14 {
                    return Ok(DenseSolveResult {
                        delta: None,
                        relative_residual: f64::INFINITY,
                    });
                }
                lower[row * dimension + column] = value.sqrt();
            } else {
                let diagonal = lower[column * dimension + column];
                if diagonal <= 1e-14 || !diagonal.is_finite() {
                    return Ok(DenseSolveResult {
                        delta: None,
                        relative_residual: f64::INFINITY,
                    });
                }
                lower[row * dimension + column] = value / diagonal;
            }
        }
    }
    let mut solution = vec![0.0; dimension];
    for row in 0..dimension {
        let mut value = rhs[row];
        for column in 0..row {
            value -= lower[row * dimension + column] * solution[column];
        }
        solution[row] = value / lower[row * dimension + row];
    }
    for row in (0..dimension).rev() {
        let mut value = solution[row];
        for column in row + 1..dimension {
            value -= lower[column * dimension + row] * solution[column];
        }
        solution[row] = value / lower[row * dimension + row];
    }
    if solution.iter().any(|value| !value.is_finite()) {
        return Ok(DenseSolveResult {
            delta: None,
            relative_residual: f64::INFINITY,
        });
    }
    let rhs_norm = rhs
        .iter()
        .map(|value| value * value)
        .sum::<f64>()
        .sqrt()
        .max(1e-12);
    let mut residual_squared = 0.0;
    for row in 0..dimension {
        let offset = row * dimension;
        let product = matrix[offset..offset + dimension]
            .iter()
            .zip(&solution)
            .map(|(a, b)| a * b)
            .sum::<f64>();
        residual_squared += (rhs[row] - product).powi(2);
    }
    Ok(DenseSolveResult {
        delta: Some(solution),
        relative_residual: residual_squared.sqrt() / rhs_norm,
    })
}

fn solve_pcg(
    matrix: &NormalMatrix,
    rhs: &[f64],
    dimension: usize,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<PcgResult, Error> {
    if matrix.dimension() != dimension || rhs.len() != dimension {
        return Ok(PcgResult {
            delta: None,
            iterations: 0,
            relative_residual: f64::INFINITY,
            converged: false,
        });
    }
    let apply_preconditioner = |input: &[f64]| -> std::result::Result<Option<Vec<f64>>, Error> {
        let mut output = allocate_f64(dimension, "PCG preconditioned vector")?;
        for block in (0..dimension).step_by(3) {
            let Some(solved) = matrix.solve_diagonal_block(block / 3, input) else {
                return Ok(None);
            };
            output[block..block + 3].copy_from_slice(&solved);
        }
        Ok(Some(output))
    };
    let mut x = allocate_f64(dimension, "PCG solution vector")?;
    let mut residual = copy_f64(rhs, "PCG residual vector")?;
    let Some(mut z) = apply_preconditioner(&residual)? else {
        return Ok(PcgResult {
            delta: None,
            iterations: 0,
            relative_residual: f64::INFINITY,
            converged: false,
        });
    };
    let mut direction = copy_f64(&z, "PCG direction vector")?;
    let mut rz = residual.iter().zip(&z).map(|(a, b)| a * b).sum::<f64>();
    let rhs_norm = rhs.iter().map(|value| value * value).sum::<f64>().sqrt();
    let rhs_scale = rhs_norm.max(1e-12);
    if rhs_norm <= 1e-12 {
        return Ok(PcgResult {
            delta: Some(x),
            iterations: 0,
            relative_residual: 0.0,
            converged: true,
        });
    }
    let mut converged = false;
    let mut iterations = 0;
    for iteration in 0..(dimension.saturating_mul(4)).clamp(64, 4096) {
        checkpoint("pixel-bundle-pcg").map_err(|_| Error::Cancelled)?;
        let product = matrix.apply(&direction)?;
        let denominator = direction
            .iter()
            .zip(&product)
            .map(|(a, b)| a * b)
            .sum::<f64>();
        if !denominator.is_finite() || denominator <= 0.0 {
            return Ok(PcgResult {
                delta: None,
                iterations,
                relative_residual: f64::INFINITY,
                converged: false,
            });
        }
        iterations = iteration + 1;
        let alpha = rz / denominator;
        for i in 0..dimension {
            x[i] += alpha * direction[i];
            residual[i] -= alpha * product[i];
        }
        let relative_residual = residual
            .iter()
            .map(|value| value * value)
            .sum::<f64>()
            .sqrt()
            / rhs_scale;
        if relative_residual <= 1e-8 {
            converged = true;
            break;
        }
        let Some(next_z) = apply_preconditioner(&residual)? else {
            return Ok(PcgResult {
                delta: None,
                iterations,
                relative_residual: f64::INFINITY,
                converged: false,
            });
        };
        z = next_z;
        let next_rz = residual.iter().zip(&z).map(|(a, b)| a * b).sum::<f64>();
        let beta = next_rz / rz;
        for i in 0..dimension {
            direction[i] = z[i] + beta * direction[i];
        }
        rz = next_rz;
    }
    let relative_residual = {
        let product = matrix.apply(&x)?;
        (0..dimension)
            .map(|i| (rhs[i] - product[i]).powi(2))
            .sum::<f64>()
            .sqrt()
            / rhs_scale
    };
    let delta = x.iter().all(|value| value.is_finite()).then_some(x);
    converged &= relative_residual <= 1e-8;
    Ok(PcgResult {
        delta,
        iterations,
        relative_residual,
        converged,
    })
}

fn assemble_pixel_normal_equations(
    poses: &mut [Mat],
    edges: &[&crate::pipeline::SphericalMatchEdge],
    req: &Request,
    variable_by_tile: &[Option<usize>],
    reliability_scales: &std::collections::HashMap<(usize, usize), f64>,
    damping: f64,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<(NormalMatrix, Vec<f64>), Error> {
    let variable_count = variable_by_tile.iter().flatten().count();
    let dimension = variable_count.checked_mul(3).ok_or_else(|| {
        Error::Registration("pixel bundle normal equation dimensions overflow".into())
    })?;
    let mut normal = NormalMatrix::new(dimension)?;
    let mut rhs = Vec::new();
    rhs.try_reserve_exact(dimension).map_err(|_| {
        Error::Registration(format!(
            "could not allocate pixel bundle normal right-hand side with {dimension} values"
        ))
    })?;
    rhs.resize(dimension, 0.0);
    let epsilon = 1e-7;
    for (edge_index, edge) in edges.iter().enumerate() {
        let reliability = reliability_scales
            .get(&(edge.from, edge.to))
            .copied()
            .unwrap_or(1.0);
        for (point_index, point) in edge.points.iter().enumerate() {
            if point_index % 256 == 0 {
                checkpoint("pixel-bundle-assembly").map_err(|_| Error::Cancelled)?;
            }
            let Some(base) = edge_point_pixel_residual(poses, edge, point, req) else {
                return Err(Error::Registration(format!(
                    "pixel bundle projection failed on edge {edge_index}, correspondence {point_index}"
                )));
            };
            let tiles = [edge.from, edge.to];
            let mut jacobians = [[[0.0; 4]; 3]; 2];
            for (side, &tile) in tiles.iter().enumerate() {
                if variable_by_tile[tile].is_none() {
                    continue;
                }
                let original = poses[tile];
                for axis in 0..3 {
                    let mut delta = [0.0; 3];
                    delta[axis] = epsilon;
                    poses[tile] =
                        normalize_rotation(mul(exp_rotation(delta), original)).unwrap_or(original);
                    let plus = edge_point_pixel_residual(poses, edge, point, req);
                    delta[axis] = -epsilon;
                    poses[tile] =
                        normalize_rotation(mul(exp_rotation(delta), original)).unwrap_or(original);
                    let minus = edge_point_pixel_residual(poses, edge, point, req);
                    poses[tile] = original;
                    let (Some(plus), Some(minus)) = (plus, minus) else {
                        continue;
                    };
                    for component in 0..4 {
                        jacobians[side][axis][component] =
                            (plus[component] - minus[component]) / (2.0 * epsilon);
                    }
                }
            }
            for pair_start in [0usize, 2usize] {
                let radius = base[pair_start].hypot(base[pair_start + 1]);
                let robust_weight = reliability * if radius > 3.0 { 3.0 / radius } else { 1.0 };
                for lhs_side in 0..2 {
                    let Some(lhs_variable) = variable_by_tile[tiles[lhs_side]] else {
                        continue;
                    };
                    for lhs_axis in 0..3 {
                        let lhs_scalar = lhs_variable * 3 + lhs_axis;
                        let ja0 = jacobians[lhs_side][lhs_axis][pair_start];
                        let ja1 = jacobians[lhs_side][lhs_axis][pair_start + 1];
                        rhs[lhs_scalar] -=
                            robust_weight * (ja0 * base[pair_start] + ja1 * base[pair_start + 1]);
                        for rhs_side in 0..2 {
                            let Some(rhs_variable) = variable_by_tile[tiles[rhs_side]] else {
                                continue;
                            };
                            for rhs_axis in 0..3 {
                                let rhs_scalar = rhs_variable * 3 + rhs_axis;
                                let jb0 = jacobians[rhs_side][rhs_axis][pair_start];
                                let jb1 = jacobians[rhs_side][rhs_axis][pair_start + 1];
                                normal.add(
                                    lhs_scalar,
                                    rhs_scalar,
                                    robust_weight * (ja0 * jb0 + ja1 * jb1),
                                )?;
                            }
                        }
                    }
                }
            }
        }
    }
    for index in 0..dimension {
        let diagonal = normal.get(index, index).max(1e-9);
        normal.add(index, index, damping * diagonal)?;
    }
    Ok((normal, rhs))
}

#[cfg(test)]
fn refine_visual_component_pixels(
    poses: &mut [Mat],
    visual_constraints: &[Constraint],
    edges: &[crate::pipeline::SphericalMatchEdge],
    req: &Request,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<
    (
        usize,
        usize,
        f64,
        f64,
        usize,
        bool,
        usize,
        f64,
        bool,
        usize,
        usize,
        f64,
    ),
    Error,
> {
    refine_visual_component_pixels_with_reliability(
        poses,
        visual_constraints,
        edges,
        req,
        checkpoint,
        true,
        &std::collections::HashMap::new(),
    )
}

#[cfg(test)]
fn refine_visual_component_pixels_mode(
    poses: &mut [Mat],
    visual_constraints: &[Constraint],
    edges: &[crate::pipeline::SphericalMatchEdge],
    req: &Request,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
    reinitialize_from_rotation_graph: bool,
) -> std::result::Result<
    (
        usize,
        usize,
        f64,
        f64,
        usize,
        bool,
        usize,
        f64,
        bool,
        usize,
        usize,
        f64,
    ),
    Error,
> {
    refine_visual_component_pixels_with_reliability(
        poses,
        visual_constraints,
        edges,
        req,
        checkpoint,
        reinitialize_from_rotation_graph,
        &std::collections::HashMap::new(),
    )
}

fn refine_visual_component_pixels_with_reliability(
    poses: &mut [Mat],
    visual_constraints: &[Constraint],
    edges: &[crate::pipeline::SphericalMatchEdge],
    req: &Request,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
    reinitialize_from_rotation_graph: bool,
    reliability_scales: &std::collections::HashMap<(usize, usize), f64>,
) -> std::result::Result<
    (
        usize,
        usize,
        f64,
        f64,
        usize,
        bool,
        usize,
        f64,
        bool,
        usize,
        usize,
        f64,
    ),
    Error,
> {
    if visual_constraints.is_empty() || edges.is_empty() {
        return Ok((0, 0, 0.0, 0.0, 0, true, 0, 0.0, true, 0, 0, 0.0));
    }
    // Only edges which passed the calibrated-ray and residual gates may
    // influence refinement. Failed/forced edges are never promoted here.
    let visual_edge_indices = visual_constraints
        .iter()
        .filter_map(|constraint| {
            edges
                .iter()
                .position(|edge| edge.from == constraint.from && edge.to == constraint.to)
        })
        .collect::<Vec<_>>();
    if visual_edge_indices.is_empty() {
        return Ok((0, 0, 0.0, 0.0, 0, true, 0, 0.0, true, 0, 0, 0.0));
    }
    let visual_edges = visual_edge_indices
        .iter()
        .map(|index| &edges[*index])
        .collect::<Vec<_>>();
    let components = visual_components(poses.len(), visual_constraints);
    let anchors = components
        .iter()
        .filter_map(|component| component.first().copied())
        .collect::<std::collections::HashSet<_>>();
    let before = visual_constraints
        .iter()
        .filter_map(|constraint| {
            edges
                .iter()
                .find(|edge| edge.from == constraint.from && edge.to == constraint.to)
                .and_then(|edge| edge_pixel_residuals(poses, edge, req))
        })
        .flatten()
        .map(|residual| {
            residual[0].hypot(residual[1]).powi(2) + residual[2].hypot(residual[3]).powi(2)
        })
        .sum::<f64>();

    // Re-solve each visual component using only its measured edges. The
    // component anchor keeps the placement supplied by the weak grid bridge.
    let mut reinitialized_camera_count = 0;
    for component in &components {
        if !reinitialize_from_rotation_graph {
            break;
        }
        if component.len() < 2 {
            continue;
        }
        let local_index = component
            .iter()
            .enumerate()
            .map(|(local, &global)| (global, local))
            .collect::<std::collections::HashMap<_, _>>();
        let local_constraints = visual_constraints
            .iter()
            .filter_map(|edge| {
                Some(Constraint {
                    from: *local_index.get(&edge.from)?,
                    to: *local_index.get(&edge.to)?,
                    rotation: edge.rotation,
                    weight: edge.weight,
                })
            })
            .collect::<Vec<_>>();
        let Some(local_poses) = solve_orientations(component.len(), &local_constraints) else {
            continue;
        };
        let anchor_pose = poses[component[0]];
        for (local, &global) in component.iter().enumerate().skip(1) {
            poses[global] =
                normalize_rotation(mul(anchor_pose, local_poses[local])).unwrap_or(poses[global]);
            reinitialized_camera_count += 1;
        }
    }

    let active_tiles = (0..poses.len())
        .filter(|tile| {
            !anchors.contains(tile)
                && visual_edge_indices
                    .iter()
                    .any(|index| edges[*index].from == *tile || edges[*index].to == *tile)
        })
        .collect::<Vec<_>>();
    let optimized = active_tiles.len();
    let mut variable_by_tile = vec![None; poses.len()];
    for (variable, &tile) in active_tiles.iter().enumerate() {
        variable_by_tile[tile] = Some(variable);
    }
    let dimension = active_tiles.len().checked_mul(3).ok_or_else(|| {
        Error::Registration("pixel bundle normal equation dimensions overflow".into())
    })?;
    let mut completed_sweeps = 0;
    let mut converged = false;
    let mut damping = 1e-4;
    let mut pcg_max_iterations = 0;
    let mut pcg_max_relative_residual: f64 = 0.0;
    let mut pcg_all_converged = true;
    let mut pcg_failed_attempts = 0;
    let mut dense_cholesky_fallback_count = 0;
    let mut max_accepted_linear_residual: f64 = 0.0;
    for sweep in 0..MAX_PIXEL_REFINEMENT_ITERATIONS {
        checkpoint("pixel-refinement-sweep").map_err(|_| Error::Cancelled)?;
        for _ in &active_tiles {
            checkpoint("pixel-refinement-camera").map_err(|_| Error::Cancelled)?;
        }
        for _ in &visual_edges {
            checkpoint("pixel-refinement-edge").map_err(|_| Error::Cancelled)?;
        }
        let old_global_cost =
            visual_pixel_huber_cost_with_reliability(poses, &visual_edges, req, reliability_scales);
        let (normal, rhs) = assemble_pixel_normal_equations(
            poses,
            &visual_edges,
            req,
            &variable_by_tile,
            reliability_scales,
            damping,
            checkpoint,
        )?;
        if normal.dimension() != dimension || !normal.all_finite() {
            return Err(Error::Registration(
                "pixel bundle produced invalid normal equations".into(),
            ));
        }
        let pcg = solve_pcg(&normal, &rhs, dimension, checkpoint)?;
        pcg_max_iterations = pcg_max_iterations.max(pcg.iterations);
        pcg_max_relative_residual = pcg_max_relative_residual.max(pcg.relative_residual);
        pcg_all_converged &= pcg.converged;
        let (mut delta, accepted_linear_residual) = if pcg.relative_residual <= 1e-3 {
            if let Some(delta) = pcg.delta {
                (delta, pcg.relative_residual)
            } else {
                pcg_failed_attempts += 1;
                damping = (damping * 10.0).min(1e8);
                continue;
            }
        } else {
            // Never line-search an inexact direction with a large true residual.
            // The damped normal matrix is SPD; use a deterministic direct fallback.
            let Some(dense) = normal.dense() else {
                pcg_failed_attempts += 1;
                damping = (damping * 10.0).min(1e8);
                continue;
            };
            dense_cholesky_fallback_count += 1;
            let direct = dense_cholesky_solve(dense, &rhs, dimension, checkpoint)?;
            if direct.relative_residual <= 1e-3 {
                if let Some(delta) = direct.delta {
                    (delta, direct.relative_residual)
                } else {
                    pcg_failed_attempts += 1;
                    damping = (damping * 10.0).min(1e8);
                    continue;
                }
            } else {
                pcg_failed_attempts += 1;
                damping = (damping * 10.0).min(1e8);
                continue;
            }
        };
        max_accepted_linear_residual = max_accepted_linear_residual.max(accepted_linear_residual);
        let delta_norm = delta.iter().map(|value| value * value).sum::<f64>().sqrt();
        if delta_norm < 1e-9 {
            converged = true;
            break;
        }
        for variable in 0..active_tiles.len() {
            let start = variable * 3;
            let magnitude = delta[start..start + 3]
                .iter()
                .map(|value| value * value)
                .sum::<f64>()
                .sqrt();
            if magnitude > 0.05 {
                for value in &mut delta[start..start + 3] {
                    *value *= 0.05 / magnitude;
                }
            }
        }
        let original_poses = poses.to_vec();
        let mut accepted = false;
        for scale in [1.0, 0.5, 0.25, 0.125, 0.0625, 0.03125] {
            poses.copy_from_slice(&original_poses);
            for (variable, &tile) in active_tiles.iter().enumerate() {
                let start = variable * 3;
                let step = [
                    delta[start] * scale,
                    delta[start + 1] * scale,
                    delta[start + 2] * scale,
                ];
                poses[tile] = normalize_rotation(mul(exp_rotation(step), original_poses[tile]))
                    .unwrap_or(original_poses[tile]);
            }
            if visual_pixel_huber_cost_with_reliability(
                poses,
                &visual_edges,
                req,
                reliability_scales,
            ) < old_global_cost
            {
                accepted = true;
                break;
            }
        }
        if !accepted {
            poses.copy_from_slice(&original_poses);
            damping = (damping * 10.0).min(1e8);
            if damping >= 1e8 {
                break;
            }
            continue;
        }
        damping = (damping * 0.3).max(1e-8);
        completed_sweeps = sweep + 1;
        let new_global_cost =
            visual_pixel_huber_cost_with_reliability(poses, &visual_edges, req, reliability_scales);
        if (old_global_cost - new_global_cost) <= old_global_cost.max(1.0) * 1e-8 {
            converged = true;
            break;
        }
    }
    let after = visual_edges
        .iter()
        .filter_map(|edge| edge_pixel_residuals(poses, edge, req))
        .flatten()
        .map(|residual| {
            residual[0].hypot(residual[1]).powi(2) + residual[2].hypot(residual[3]).powi(2)
        })
        .sum::<f64>();
    Ok((
        reinitialized_camera_count,
        optimized,
        before.sqrt(),
        after.sqrt(),
        completed_sweeps,
        converged,
        pcg_max_iterations,
        pcg_max_relative_residual,
        pcg_all_converged,
        pcg_failed_attempts,
        dense_cholesky_fallback_count,
        max_accepted_linear_residual,
    ))
}

/// Left-rotate every camera pose so the upper-left tile in the grid's central
/// cell(s) defines the world orientation. For even dimensions this selects the
/// upper-left of the four central cells.
fn reorient_poses_to_grid_center(
    poses: &mut [Mat],
    rows: usize,
    columns: usize,
) -> Option<(usize, Mat)> {
    if rows == 0 || columns == 0 || rows.checked_mul(columns)? != poses.len() {
        return None;
    }
    let row = (rows - 1) / 2;
    let column = (columns - 1) / 2;
    let index = row * columns + column;
    let applied = transpose(poses[index]);
    for pose in poses {
        *pose = normalize_rotation(mul(applied, *pose))?;
    }
    Some((index, applied))
}

fn spherical_bounds(poses: &[Mat], req: &Request) -> Option<[f64; 4]> {
    spherical_bounds_with_warps(poses, req, None)
}

fn spherical_bounds_with_warps(
    poses: &[Mat],
    req: &Request,
    warps: Option<&[Option<crate::texture_warp::SourcePlaneWarp>]>,
) -> Option<[f64; 4]> {
    let warps = warps.filter(|warps| warps.iter().flatten().any(|warp| !warp.is_zero()));
    let mut bounds = [
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
    ];
    let (width, height) = (req.source_width as f64, req.source_height as f64);
    let center_pose = poses.get(((req.rows - 1) / 2) * req.columns + (req.columns - 1) / 2)?;
    let yaw_origin = spherical_point(ray_to_world(*center_pose, req.cx, req.cy, req)).0;
    let mut warp_yaw_margin = 0.0_f64;
    let mut warp_pitch_margin = 0.0_f64;
    for (tile_index, &pose) in poses.iter().enumerate() {
        let warp = warps
            .and_then(|warps| warps.get(tile_index))
            .and_then(Option::as_ref);
        let mut pixels = vec![
            (0., 0.),
            (width - 1., 0.),
            (0., height - 1.),
            (width - 1., height - 1.),
            ((width - 1.) * 0.5, 0.),
            ((width - 1.) * 0.5, height - 1.),
            (0., (height - 1.) * 0.5),
            (width - 1., (height - 1.) * 0.5),
            ((width - 1.) * 0.5, (height - 1.) * 0.5),
        ];
        if let Some(warp) = warp {
            // Sample every outer control-grid segment; bilinear offsets are
            // piecewise linear along these source boundaries.
            let max_x = width - 1.0;
            let max_y = height - 1.0;
            for step in 0..=8 {
                let t = step as f64 / 8.0;
                pixels.extend([
                    (max_x * 0.5 * t, 0.0),
                    (max_x * 0.5 + max_x * 0.5 * t, 0.0),
                    (max_x * 0.5 * t, max_y),
                    (max_x * 0.5 + max_x * 0.5 * t, max_y),
                    (0.0, max_y * 0.5 * t),
                    (0.0, max_y * 0.5 + max_y * 0.5 * t),
                    (max_x, max_y * 0.5 * t),
                    (max_x, max_y * 0.5 + max_y * 0.5 * t),
                ]);
            }
            let max_offset = warp
                .offsets
                .iter()
                .map(|offset| offset[0].hypot(offset[1]))
                .fold(0.0_f64, f64::max);
            warp_yaw_margin = warp_yaw_margin.max(max_offset / req.fx.min(req.fy));
            warp_pitch_margin = warp_pitch_margin.max(max_offset / req.fx.min(req.fy));
        }
        for (x, y) in pixels {
            let (x, y) = if let Some(warp) = warp {
                crate::texture_warp::source_to_corrected(
                    warp,
                    req.source_width,
                    req.source_height,
                    x,
                    y,
                )?
            } else {
                (x, y)
            };
            let (yaw, pitch) = spherical_point(ray_to_world(pose, x, y, req));
            let yaw = yaw_origin
                + (yaw - yaw_origin + std::f64::consts::PI).rem_euclid(2. * std::f64::consts::PI)
                - std::f64::consts::PI;
            bounds[0] = bounds[0].min(yaw);
            bounds[1] = bounds[1].max(yaw);
            bounds[2] = bounds[2].min(pitch);
            bounds[3] = bounds[3].max(pitch);
        }
    }
    if warp_yaw_margin > 0.0 {
        bounds[0] -= warp_yaw_margin;
        bounds[1] += warp_yaw_margin;
        bounds[2] -= warp_pitch_margin;
        bounds[3] += warp_pitch_margin;
    }
    bounds
        .iter()
        .all(|value| value.is_finite())
        .then_some(bounds)
}

/// Reorient an existing spherical layout without decoding or matching source
/// images. This is also used by the alignment path so review previews can be
/// regenerated from a saved layout with identical pose and bounds behavior.
pub fn reorient_layout_to_grid_center(layout: &mut Value) -> std::result::Result<(), String> {
    if layout["schemaVersion"].as_u64() != Some(1)
        || layout["projection"].as_str() != Some("spherical")
    {
        return Err("layout must use schemaVersion 1 and spherical projection".into());
    }
    let mut tiles = layout["tiles"]
        .as_array()
        .cloned()
        .ok_or("layout has no tiles array")?;
    if tiles.len() < 2 {
        return Err("layout must contain at least two tiles".into());
    }
    let report_object = layout["report"]
        .as_object()
        .ok_or("layout report is invalid")?
        .clone();
    let row_values = tiles
        .iter()
        .map(|tile| {
            usize::try_from(tile["row"].as_u64().ok_or("tile row is invalid")?)
                .map_err(|_| "tile row is out of range")
        })
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let column_values = tiles
        .iter()
        .map(|tile| {
            usize::try_from(tile["column"].as_u64().ok_or("tile column is invalid")?)
                .map_err(|_| "tile column is out of range")
        })
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let rows = row_values
        .iter()
        .copied()
        .max()
        .unwrap()
        .checked_add(1)
        .ok_or("tile row is out of range")?;
    let columns = column_values
        .iter()
        .copied()
        .max()
        .unwrap()
        .checked_add(1)
        .ok_or("tile column is out of range")?;
    let Some(cell_count) = rows.checked_mul(columns) else {
        return Err("layout grid dimensions overflow addressable storage".into());
    };
    if cell_count != tiles.len() {
        return Err("layout grid must contain every cell exactly once".into());
    }
    let mut ordered = vec![None; tiles.len()];
    for (tile_index, _) in tiles.iter().enumerate() {
        let row = row_values[tile_index];
        let column = column_values[tile_index];
        if row >= rows || column >= columns {
            return Err("layout tile coordinate is outside the grid".into());
        }
        let index = row * columns + column;
        if ordered[index].replace(tile_index).is_some() {
            return Err("layout has duplicate tile coordinates".into());
        }
    }
    let mut poses = vec![ID; tiles.len()];
    for (grid_index, tile_index) in ordered.iter().enumerate() {
        let tile = &tiles[tile_index.ok_or("layout tile coordinates are incomplete")?];
        let values = tile["cameraToWorld"]
            .as_array()
            .ok_or("tile cameraToWorld is invalid")?;
        if values.len() != 9 {
            return Err("tile cameraToWorld must contain nine values".into());
        }
        for (dst, value) in poses[grid_index].iter_mut().zip(values) {
            *dst = value
                .as_f64()
                .ok_or("tile cameraToWorld value is invalid")?;
        }
        if !poses[grid_index].iter().all(|value| value.is_finite()) {
            return Err("tile cameraToWorld must contain finite values".into());
        }
        poses[grid_index] = normalize_rotation(poses[grid_index])
            .ok_or("tile cameraToWorld is not a finite SO(3) rotation")?;
    }
    let tile = &tiles[0];
    let req = Request {
        rows,
        columns,
        tiles: Vec::new(),
        fx: tile["fx"].as_f64().ok_or("tile fx is invalid")?,
        fy: tile["fy"].as_f64().ok_or("tile fy is invalid")?,
        cx: tile["cx"].as_f64().ok_or("tile cx is invalid")?,
        cy: tile["cy"].as_f64().ok_or("tile cy is invalid")?,
        source_width: u32::try_from(tile["width"].as_u64().ok_or("tile width is invalid")?)
            .map_err(|_| "tile width is out of range")?,
        source_height: u32::try_from(tile["height"].as_u64().ok_or("tile height is invalid")?)
            .map_err(|_| "tile height is out of range")?,
        output_dir: String::new(),
        placement_mode: String::new(),
        allow_nominal_grid_fallback: false,
        auto_grid_overlap: false,
        refine_grid_neighbors: false,
        seam_blend_mode: default_seam_blend_mode(),
        grid_horizontal_overlap: None,
        grid_vertical_overlap: None,
        neighbor_mode: default_neighbor_mode(),
        workers: default_workers(),
        parallel_matching: default_parallel_matching(),
        registration_megapixels: default_registration_megapixels(),
        feature_type: default_feature_type(),
        matcher_type: default_matcher_type(),
        include_diagnostic_correspondences: false,
        local_texture_warp: true,
    };
    if req.source_width == 0
        || req.source_height == 0
        || u64::from(req.source_width) * u64::from(req.source_height) > 80_000_000
        || ![req.fx, req.fy, req.cx, req.cy]
            .iter()
            .all(|value| value.is_finite())
        || req.fx <= 0.
        || req.fy <= 0.
        || req.cx < 0.
        || req.cx >= f64::from(req.source_width)
        || req.cy < 0.
        || req.cy >= f64::from(req.source_height)
    {
        return Err("layout source dimensions and pixel intrinsics are invalid".into());
    }
    for tile in &tiles {
        if tile["width"].as_u64() != Some(u64::from(req.source_width))
            || tile["height"].as_u64() != Some(u64::from(req.source_height))
            || tile["fx"].as_f64() != Some(req.fx)
            || tile["fy"].as_f64() != Some(req.fy)
            || tile["cx"].as_f64() != Some(req.cx)
            || tile["cy"].as_f64() != Some(req.cy)
        {
            return Err("layout tiles do not share source dimensions and intrinsics".into());
        }
    }
    let mut source_warps = vec![None; rows.saturating_mul(columns)];
    for tile in &tiles {
        let grid_index = tile["row"].as_u64().ok_or("layout tile row is invalid")? as usize
            * columns
            + tile["column"]
                .as_u64()
                .ok_or("layout tile column is invalid")? as usize;
        if let Some(value) = tile.get("sourcePlaneWarp") {
            let warp: crate::texture_warp::SourcePlaneWarp = serde_json::from_value(value.clone())
                .map_err(|error| format!("sourcePlaneWarp is invalid: {error}"))?;
            crate::texture_warp::validate_source_plane_warp(
                &warp,
                req.source_width,
                req.source_height,
            )?;
            source_warps[grid_index] = Some(warp);
        }
    }
    let (reference_index, applied_rotation) =
        reorient_poses_to_grid_center(&mut poses, rows, columns)
            .ok_or("could not reorient layout poses")?;
    let bounds = spherical_bounds_with_warps(&poses, &req, Some(&source_warps))
        .ok_or("could not calculate spherical bounds")?;
    if bounds[1] - bounds[0] < 1e-5 || bounds[3] - bounds[2] < 1e-5 {
        return Err("layout has degenerate spherical coverage".into());
    }
    let pixel_scale = (req.fx + req.fy) * 0.5;
    let output_width = ((bounds[1] - bounds[0]) * pixel_scale).ceil().max(1.);
    let output_height = ((bounds[3] - bounds[2]) * pixel_scale).ceil().max(1.);
    if !output_width.is_finite()
        || !output_height.is_finite()
        || output_width > f64::from(u32::MAX)
        || output_height > f64::from(u32::MAX)
    {
        return Err("layout output dimensions exceed supported integer range".into());
    }
    for (grid_index, tile_index) in ordered.iter().enumerate() {
        tiles[tile_index.unwrap()]["cameraToWorld"] = json!(poses[grid_index]);
    }
    let mut report = report_object;
    report.insert(
        "orientationReference".into(),
        json!({
            "row": (rows - 1) / 2,
            "column": (columns - 1) / 2,
            "index": reference_index,
            "strategy": "center-grid-tile; even dimensions use upper-left central tile"
        }),
    );
    report.insert(
        "visualConnectivityReference".into(),
        json!({"row":0,"column":0,"index":0,"strategy":"upper-left tile remains visual graph root"}),
    );
    report.insert("appliedGlobalRotation".into(), json!(applied_rotation));
    layout["tiles"] = json!(tiles);
    layout["width"] = json!(output_width as u32);
    layout["height"] = json!(output_height as u32);
    layout["yawMinRad"] = json!(bounds[0]);
    layout["yawMaxRad"] = json!(bounds[1]);
    layout["pitchMinRad"] = json!(bounds[2]);
    layout["pitchMaxRad"] = json!(bounds[3]);
    layout["report"] = Value::Object(report);
    if !layout["renderBlendMode"].is_string() {
        layout["renderBlendMode"] = json!("feather");
    }
    Ok(())
}

fn align_measured_grid_only(
    req: Request,
    tiles: Vec<CaptureTile>,
    forced_grid_indices: Vec<bool>,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
    alignment_started: std::time::Instant,
) -> std::result::Result<Value, SphericalFailure> {
    let estimate = grid_overlap::estimate(
        req.rows,
        req.columns,
        &tiles
            .iter()
            .map(|tile| tile.path.clone())
            .collect::<Vec<_>>(),
        &forced_grid_indices,
        req.source_width,
        req.source_height,
        req.fx,
        req.fy,
        (req.registration_megapixels * 1_000_000.0).round() as usize,
        checkpoint,
    );
    let estimate = match estimate {
        Ok(value) => value,
        Err((EstimateError::Cancelled, _)) => return Err(Error::Cancelled.into()),
        Err((EstimateError::Failed, evidence)) => return Err(SphericalFailure {
            code: "OVERLAP_ESTIMATION_FAILED",
            message: "central horizontal and vertical overlap samples did not pass the homography quality gates".into(),
            diagnostics: Some(evidence),
        }),
    };
    if req.refine_grid_neighbors {
        // Keep the measured central step as a grid fallback, while reusing the
        // existing four-neighbor visual-ray solver for every usable adjacent
        // pair. No all-pairs comparisons are introduced by this path.
        let central_overlap = estimate.report.clone();
        let mut refined_req = req;
        refined_req.auto_grid_overlap = false;
        refined_req.refine_grid_neighbors = false;
        refined_req.placement_mode = "grid-assisted".into();
        refined_req.allow_nominal_grid_fallback = true;
        refined_req.neighbor_mode = "four".into();
        let horizontal_fov =
            2.0 * (f64::from(refined_req.source_width) / (2.0 * refined_req.fx)).atan();
        let vertical_fov =
            2.0 * (f64::from(refined_req.source_height) / (2.0 * refined_req.fy)).atan();
        refined_req.grid_horizontal_overlap = (refined_req.columns > 1)
            .then_some(1.0 - estimate.horizontal_step_rad / horizontal_fov);
        refined_req.grid_vertical_overlap =
            (refined_req.rows > 1).then_some(1.0 - estimate.vertical_step_rad / vertical_fov);
        let blend_mode = refined_req.seam_blend_mode.clone();
        let mut layout = align(refined_req, checkpoint)?;
        layout["renderBlendMode"] = json!(blend_mode);
        layout["report"]["autoGridOverlap"] = json!(true);
        layout["report"]["refineGridNeighbors"] = json!(true);
        layout["report"]["gridOverlapEstimate"] = central_overlap.clone();
        layout["report"]["geometryModel"] = json!("central-overlap+four-neighbor-visual-ray-grid");
        layout["report"]["gridNeighborRefinement"] = json!({
            "enabled": true,
            "strategy": "existing-four-neighbor-visual-ray-solver",
            "allPairsMatching": false,
            "fallbackSource": "centralMeasuredOverlap",
            "visualTileCount": layout["report"]["visualTileCount"],
            "acceptedVisualEvidenceTileCount": layout["report"]["acceptedVisualEvidenceTileCount"],
            "rootAnchoredVisualTileCount": layout["report"]["rootAnchoredVisualTileCount"],
            "visualComponentCount": layout["report"]["visualComponentCount"],
            "estimatedTileCount": layout["report"]["gridEstimatedTileCount"],
            "visualEdgeCount": layout["report"]["matchedEdges"],
            "estimatedEdgeCount": layout["report"]["synthesizedGridEdgeCount"],
            "gridBridgedTileIndices": layout["report"]["gridBridgedTileIndices"],
            "gridBridgedEdges": layout["report"]["gridBridgedEdges"],
            "visualComponents": layout["report"]["visualComponents"],
            "rayReprojectionRmsPx": layout["report"]["globalRayReprojectionRmsPx"],
            "rayReprojectionP95Px": layout["report"]["globalRayReprojectionP95Px"],
            "centralHorizontalOverlap": estimate.horizontal_overlap,
            "centralVerticalOverlap": estimate.vertical_overlap,
            "centralHorizontalStepPixels": estimate.horizontal_step_px,
            "centralVerticalStepPixels": estimate.vertical_step_px
        });
        layout["report"]["gridHorizontalStepRadians"] = json!(estimate.horizontal_step_rad);
        layout["report"]["gridVerticalStepRadians"] = json!(estimate.vertical_step_rad);
        layout["report"]["gridEstimatedPlacementHasDirectVisualEvidence"] = json!(false);
        if let Some(edges) = layout["report"]["synthesizedGridEdges"].as_array_mut() {
            for edge in edges {
                if edge["rotationSource"] == "nominalFovOverlap" {
                    edge["rotationSource"] = json!("centralMeasuredOverlap");
                }
            }
        }
        for key in ["gridHorizontalStep", "gridVerticalStep"] {
            if layout["report"][key]["source"] == "nominalFovOverlap" {
                layout["report"][key]["source"] = json!("centralMeasuredOverlap");
            }
        }
        return Ok(layout);
    }
    let horizontal_fov = 2.0 * (f64::from(req.source_width) / (2.0 * req.fx)).atan();
    let vertical_fov = 2.0 * (f64::from(req.source_height) / (2.0 * req.fy)).atan();
    // Row and column order defines the positive grid axes. The signed image
    // displacement is retained in diagnostics; camera step magnitudes use atan.
    let horizontal = exp_rotation([0.0, estimate.horizontal_step_rad, 0.0]);
    let vertical = exp_rotation([estimate.vertical_step_rad, 0.0, 0.0]);
    let no_visual = vec![false; tiles.len()];
    let (unused_constraints, synthesized, horizontal_step, vertical_step) =
        synthesize_grid_constraints(
            req.rows,
            req.columns,
            &[],
            &no_visual,
            (req.columns > 1).then_some(horizontal),
            (req.rows > 1).then_some(vertical),
            horizontal_fov * 1.5,
            vertical_fov * 1.5,
        )
        .map_err(|message| SphericalFailure {
            code: "OVERLAP_ESTIMATION_FAILED",
            message,
            diagnostics: Some(estimate.report.clone()),
        })?;
    let mut poses = Vec::with_capacity(tiles.len());
    let mut row_rotation = ID;
    for _row in 0..req.rows {
        let mut column_rotation = ID;
        for _column in 0..req.columns {
            poses.push(
                normalize_rotation(mul(column_rotation, row_rotation)).ok_or_else(|| {
                    SphericalFailure {
                        code: "OVERLAP_ESTIMATION_FAILED",
                        message: "measured grid pose is invalid".into(),
                        diagnostics: Some(estimate.report.clone()),
                    }
                })?,
            );
            column_rotation = mul(column_rotation, horizontal);
        }
        row_rotation = mul(row_rotation, vertical);
    }
    let report = json!({
        "geometryModel":"central-measured-overlap-grid",
        "placementMode":"grid-assisted",
        "autoGridOverlap":true,
        "gridOverlapEstimate":estimate.report,
        "gridHorizontalOverlap":if req.columns > 1 { json!(estimate.horizontal_overlap) } else { Value::Null },
        "gridVerticalOverlap":if req.rows > 1 { json!(estimate.vertical_overlap) } else { Value::Null },
        "gridHorizontalStepRadians":if req.columns > 1 { json!(estimate.horizontal_step_rad) } else { Value::Null },
        "gridVerticalStepRadians":if req.rows > 1 { json!(estimate.vertical_step_rad) } else { Value::Null },
        "gridHorizontalStep":if req.columns > 1 { json!({"source":"centralMeasuredHomography","stepPixels":estimate.horizontal_step_px}) } else { Value::Null },
        "gridVerticalStep":if req.rows > 1 { json!({"source":"centralMeasuredHomography","stepPixels":estimate.vertical_step_px}) } else { Value::Null },
        "gridEstimatedPlacementHasDirectVisualEvidence":false,
        "visualTileCount":0,
        "gridEstimatedTileCount":tiles.len(),
        "gridEstimatedTileIndices":(0..tiles.len()).collect::<Vec<_>>(),
        "forcedGridTileCount":forced_grid_indices.iter().filter(|v| **v).count(),
        "forcedGridTileIndices":forced_grid_indices.iter().enumerate().filter_map(|(i,v)| v.then_some(i)).collect::<Vec<_>>(),
        "qualityStatus":"needs-visual-review",
        "qualityWarnings":["all grid positions are estimated from central overlap samples; inspect the complete panorama visually"],
        "estimatedPositionsVerified":false,
        "nominalGridOnlyNeedsVisualReview":true,
        "intrinsicsSource":"caller-supplied-pixel-intrinsics",
        "nominalIntrinsics":true,
        "featureType":"sift","matcherType":"bf","registrationMegapixels":req.registration_megapixels,
        "neighborMode":req.neighbor_mode,"parallelMatching":false,
        "requestedMatchingWorkers":req.workers,"effectiveMatchingWorkers":1,"requestedWorkers":req.workers,"effectiveWorkers":1,
        "featureCount":estimate.sampled_feature_count,"sampledFeatureCount":estimate.sampled_feature_count,
        "sampledTileCount":estimate.sampled_tile_count,"sampledPairCount":estimate.report["horizontal"]["pairs"].as_array().map_or(0,Vec::len)+estimate.report["vertical"]["pairs"].as_array().map_or(0,Vec::len),
        "sampleOverlapMs":estimate.sample_total_ms,"rawVisualMatches":0,"ransacInlierCount":0,"matchedEdges":0,"totalEdges":0,
        "synthesizedGridEdgeCount":synthesized.len(),"synthesizedGridEdges":synthesized,
        "totalConstraintCount":unused_constraints.len(),"connectedTileCount":0,"totalTileCount":tiles.len(),
        "poseConstruction":"analytic-uniform-grid","poseOptimizationMs":Value::Null,
        "totalAlignmentMs":alignment_started.elapsed().as_millis() as u64,
        "rendered":false,"outputDir":req.output_dir,
        "gridHorizontalStepDiagnostic":grid_step_diagnostic(horizontal_step.as_ref()),
        "gridVerticalStepDiagnostic":grid_step_diagnostic(vertical_step.as_ref())
    });
    reorient_poses_to_grid_center(&mut poses, req.rows, req.columns).ok_or_else(|| {
        SphericalFailure {
            code: "OVERLAP_ESTIMATION_FAILED",
            message: "could not center measured grid orientations".into(),
            diagnostics: Some(estimate.report.clone()),
        }
    })?;
    let bounds = spherical_bounds(&poses, &req).ok_or_else(|| SphericalFailure {
        code: "OVERLAP_ESTIMATION_FAILED",
        message: "could not calculate measured grid coverage".into(),
        diagnostics: Some(estimate.report.clone()),
    })?;
    let layout_tiles = tiles.iter().enumerate().map(|(index, tile)| json!({
        "row":tile.row,"column":tile.column,"path":tile.path,
        "width":req.source_width,"height":req.source_height,"fx":req.fx,"fy":req.fy,"cx":req.cx,"cy":req.cy,
        "cameraToWorld":poses[index],"positionSource":"gridEstimated","forceGrid":forced_grid_indices[index]
    })).collect::<Vec<_>>();
    let mut layout = json!({"schemaVersion":1,"projection":"spherical","tiles":layout_tiles,"renderBlendMode":req.seam_blend_mode,"report":report});
    reorient_layout_to_grid_center(&mut layout).map_err(|message| SphericalFailure {
        code: "OVERLAP_ESTIMATION_FAILED",
        message,
        diagnostics: Some(estimate.report.clone()),
    })?;
    let _ = (horizontal_step, vertical_step);
    if bounds[1] - bounds[0] < 1e-5 || bounds[3] - bounds[2] < 1e-5 {
        return Err(SphericalFailure {
            code: "OVERLAP_ESTIMATION_FAILED",
            message: "measured grid has degenerate coverage".into(),
            diagnostics: Some(estimate.report),
        });
    }
    Ok(layout)
}

fn solve_3x3(mut a: [[f64; 3]; 3], mut b: [f64; 3]) -> Option<[f64; 3]> {
    for column in 0..3 {
        let pivot =
            (column..3).max_by(|&i, &j| a[i][column].abs().total_cmp(&a[j][column].abs()))?;
        if a[pivot][column].abs() < 1e-14 {
            return None;
        }
        a.swap(column, pivot);
        b.swap(column, pivot);
        let scale = a[column][column];
        for j in column..3 {
            a[column][j] /= scale;
        }
        b[column] /= scale;
        for row in 0..3 {
            if row == column {
                continue;
            }
            let factor = a[row][column];
            for j in column..3 {
                a[row][j] -= factor * a[column][j];
            }
            b[row] -= factor * b[column];
        }
    }
    b.iter().all(|v| v.is_finite()).then_some(b)
}

fn fit_ray_rotation(
    points: &[[f64; 4]],
    fx: f64,
    fy: f64,
    cx: f64,
    cy: f64,
) -> Option<(Mat, f64, f64)> {
    if points.len() < 8 {
        return None;
    }
    let ray = |x: f64, y: f64| {
        let mut v = [(x - cx) / fx, -(y - cy) / fy, 1.];
        let n = (v[0] * v[0] + v[1] * v[1] + 1.).sqrt();
        for axis in &mut v {
            *axis /= n;
        }
        v
    };
    let pairs = points
        .iter()
        .map(|p| (ray(p[0], p[1]), ray(p[2], p[3])))
        .collect::<Vec<_>>();
    let focal = (fx + fy) * 0.5;
    let mut rotation = ID;
    for _ in 0..30 {
        let (mut normal, mut rhs) = ([[0.; 3]; 3], [0.; 3]);
        for &(source, target) in &pairs {
            let v = [
                rotation[0] * source[0] + rotation[1] * source[1] + rotation[2] * source[2],
                rotation[3] * source[0] + rotation[4] * source[1] + rotation[5] * source[2],
                rotation[6] * source[0] + rotation[7] * source[1] + rotation[8] * source[2],
            ];
            let error = [v[0] - target[0], v[1] - target[1], v[2] - target[2]];
            let pixel_error =
                (error[0] * error[0] + error[1] * error[1] + error[2] * error[2]).sqrt() * focal;
            let weight = if pixel_error > 3. {
                3. / pixel_error
            } else {
                1.
            };
            let jacobian = left_rotation_jacobian(v);
            for i in 0..3 {
                rhs[i] -= weight * (0..3).map(|r| jacobian[r][i] * error[r]).sum::<f64>();
                for j in 0..3 {
                    normal[i][j] +=
                        weight * (0..3).map(|r| jacobian[r][i] * jacobian[r][j]).sum::<f64>();
                }
            }
        }
        let delta = solve_3x3(normal, rhs)?;
        let magnitude = (delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]).sqrt();
        if magnitude > 0.5 {
            return None;
        }
        rotation = normalize_rotation(mul(exp_rotation(delta), rotation))?;
        if magnitude < 1e-10 {
            break;
        }
    }
    let mut residuals = pairs
        .iter()
        .map(|(source, target)| {
            let v = [
                rotation[0] * source[0] + rotation[1] * source[1] + rotation[2] * source[2],
                rotation[3] * source[0] + rotation[4] * source[1] + rotation[5] * source[2],
                rotation[6] * source[0] + rotation[7] * source[1] + rotation[8] * source[2],
            ];
            let d = [v[0] - target[0], v[1] - target[1], v[2] - target[2]];
            (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt() * focal
        })
        .collect::<Vec<_>>();
    residuals.sort_by(f64::total_cmp);
    let median = residuals[residuals.len() / 2];
    let rms = (residuals.iter().map(|v| v * v).sum::<f64>() / residuals.len() as f64).sqrt();
    Some((rotation, median, rms))
}

fn left_rotation_jacobian(v: [f64; 3]) -> [[f64; 3]; 3] {
    // exp(delta) * R left-multiplies the ray, so d(delta x v)/d(delta).
    [[0., v[2], -v[1]], [-v[2], 0., v[0]], [v[1], -v[0], 0.]]
}
fn ray_to_world(pose: Mat, x: f64, y: f64, r: &Request) -> [f64; 3] {
    let mut v = [(x - r.cx) / r.fx, -(y - r.cy) / r.fy, 1.];
    let n = (v[0] * v[0] + v[1] * v[1] + 1.).sqrt();
    for x in &mut v {
        *x /= n;
    }
    let w = [
        pose[0] * v[0] + pose[1] * v[1] + pose[2] * v[2],
        pose[3] * v[0] + pose[4] * v[1] + pose[5] * v[2],
        pose[6] * v[0] + pose[7] * v[1] + pose[8] * v[2],
    ];
    let n = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).sqrt();
    [w[0] / n, w[1] / n, w[2] / n]
}
fn project_camera_ray(ray: [f64; 3], req: &Request) -> Option<(f64, f64)> {
    if !ray.iter().all(|value| value.is_finite()) || ray[2] <= 1e-9 {
        return None;
    }
    let pixel = (
        req.fx * ray[0] / ray[2] + req.cx,
        req.cy - req.fy * ray[1] / ray[2],
    );
    (pixel.0.is_finite() && pixel.1.is_finite()).then_some(pixel)
}

fn global_reprojection_metrics(
    poses: &[Mat],
    constraints: &[Constraint],
    edges: &[crate::pipeline::SphericalMatchEdge],
    req: &Request,
) -> (f64, f64, f64, usize, Vec<(usize, usize, f64, usize)>, bool) {
    global_reprojection_metrics_with_warps(poses, constraints, edges, req, None)
}

fn global_reprojection_metrics_with_warps(
    poses: &[Mat],
    constraints: &[Constraint],
    edges: &[crate::pipeline::SphericalMatchEdge],
    req: &Request,
    warps: Option<&[Option<crate::texture_warp::SourcePlaneWarp>]>,
) -> (f64, f64, f64, usize, Vec<(usize, usize, f64, usize)>, bool) {
    let mut squared_errors = Vec::new();
    let mut per_edge = Vec::new();
    let mut complete_evidence = true;
    for constraint in constraints {
        let Some(edge) = edges
            .iter()
            .find(|edge| edge.from == constraint.from && edge.to == constraint.to)
        else {
            complete_evidence = false;
            continue;
        };
        if edge.points.len() != edge.inliers || edge.points.len() < 8 {
            complete_evidence = false;
        }
        let mut edge_squared = 0.;
        let mut edge_count = 0;
        for point in &edge.points {
            if !point.iter().all(|value| value.is_finite()) {
                complete_evidence = false;
                continue;
            }
            let source_pixel = warp_pixel(warps, constraint.from, point[0], point[1], req);
            let target_pixel = warp_pixel(warps, constraint.to, point[2], point[3], req);
            let (Some(source_pixel), Some(target_pixel)) = (source_pixel, target_pixel) else {
                complete_evidence = false;
                continue;
            };
            let world = ray_to_world(poses[constraint.from], source_pixel.0, source_pixel.1, req);
            let target_ray = mul_vec(transpose(poses[constraint.to]), world);
            let Some(projected) = project_camera_ray(target_ray, req) else {
                complete_evidence = false;
                continue;
            };
            let error = (projected.0 - target_pixel.0).hypot(projected.1 - target_pixel.1);
            if error.is_finite() {
                squared_errors.push(error * error);
                edge_squared += error * error;
                edge_count += 1;
            } else {
                complete_evidence = false;
            }
            if warps.is_some() {
                let reverse_world =
                    ray_to_world(poses[constraint.to], target_pixel.0, target_pixel.1, req);
                let source_ray = mul_vec(transpose(poses[constraint.from]), reverse_world);
                let Some(reverse_projected) = project_camera_ray(source_ray, req) else {
                    complete_evidence = false;
                    continue;
                };
                let reverse_error = (reverse_projected.0 - source_pixel.0)
                    .hypot(reverse_projected.1 - source_pixel.1);
                if reverse_error.is_finite() {
                    squared_errors.push(reverse_error * reverse_error);
                    edge_squared += reverse_error * reverse_error;
                    edge_count += 1;
                } else {
                    complete_evidence = false;
                }
            }
        }
        if edge_count != edge.points.len() * if warps.is_some() { 2 } else { 1 } {
            complete_evidence = false;
        }
        if edge_count > 0 {
            per_edge.push((
                constraint.from,
                constraint.to,
                (edge_squared / edge_count as f64).sqrt(),
                edge_count,
            ));
        }
    }
    if squared_errors.is_empty() {
        return (
            f64::INFINITY,
            f64::INFINITY,
            f64::INFINITY,
            0,
            per_edge,
            false,
        );
    }
    let rms = (squared_errors.iter().sum::<f64>() / squared_errors.len() as f64).sqrt();
    let mut pixel_errors = squared_errors
        .iter()
        .map(|error| error.sqrt())
        .collect::<Vec<_>>();
    pixel_errors.sort_by(f64::total_cmp);
    let p95 = pixel_errors[((pixel_errors.len() - 1) * 95) / 100];
    let max = *pixel_errors.last().unwrap();
    (
        rms,
        p95,
        max,
        pixel_errors.len(),
        per_edge,
        complete_evidence,
    )
}

fn warp_pixel(
    warps: Option<&[Option<crate::texture_warp::SourcePlaneWarp>]>,
    tile_index: usize,
    x: f64,
    y: f64,
    req: &Request,
) -> Option<(f64, f64)> {
    match warps {
        None => Some((x, y)),
        Some(warps) => match warps.get(tile_index).and_then(Option::as_ref) {
            Some(warp) => crate::texture_warp::source_to_corrected(
                warp,
                req.source_width,
                req.source_height,
                x,
                y,
            ),
            None => Some((x, y)),
        },
    }
}

fn fit_source_plane_warps(
    poses: &[Mat],
    visual_constraints: &[Constraint],
    matched_edges: &[crate::pipeline::SphericalMatchEdge],
    req: &Request,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
    smoothness_weight: f64,
) -> std::result::Result<
    (
        Vec<Option<crate::texture_warp::SourcePlaneWarp>>,
        Vec<Value>,
        Value,
    ),
    Error,
> {
    use crate::texture_warp::{fit_source_plane_warp_multilevel, SourceWarpSample};
    let components = visual_components(poses.len(), visual_constraints);
    let anchors = components
        .iter()
        .filter_map(|component| component.iter().copied().min())
        .collect::<std::collections::HashSet<_>>();
    let mut warps = vec![None; poses.len()];
    let mut tile_diagnostics = vec![Value::Null; poses.len()];
    let mut processed = 0usize;
    let (initial_rms, _, _, _, initial_edges, initial_complete) =
        global_reprojection_metrics_with_warps(
            poses,
            visual_constraints,
            matched_edges,
            req,
            Some(&warps),
        );
    let initial_worst = initial_edges
        .iter()
        .map(|edge| edge.2)
        .fold(0.0_f64, f64::max);
    let mut accepted_rounds = 0usize;
    let mut attempted_rounds = 0usize;
    let mut termination_reason = "iteration_limit";
    let mut converged = false;
    for outer_iteration in 0..8 {
        checkpoint("source-plane-warp-outer-iteration").map_err(|_| Error::Cancelled)?;
        attempted_rounds += 1;
        let current_warps = warps.clone();
        let mut proposed_warps = current_warps.clone();
        let mut samples = vec![Vec::<SourceWarpSample>::new(); poses.len()];
        for constraint in visual_constraints {
            let Some(edge) = matched_edges
                .iter()
                .find(|edge| edge.from == constraint.from && edge.to == constraint.to)
            else {
                continue;
            };
            let per_point_weight = constraint.weight.max(1e-3) / edge.points.len().max(1) as f64;
            for point in &edge.points {
                processed += 1;
                if processed % 256 == 0 {
                    checkpoint("source-plane-warp-correspondence").map_err(|_| Error::Cancelled)?;
                }
                let (source_dx, source_dy) = current_warps[constraint.from]
                    .as_ref()
                    .and_then(|warp| {
                        crate::texture_warp::source_to_corrected(
                            warp,
                            req.source_width,
                            req.source_height,
                            point[0],
                            point[1],
                        )
                    })
                    .map(|(corrected_x, corrected_y)| {
                        (corrected_x - point[0], corrected_y - point[1])
                    })
                    .unwrap_or((0.0, 0.0));
                let corrected_source_x = point[0] + source_dx;
                let corrected_source_y = point[1] + source_dy;
                let world = ray_to_world(
                    poses[constraint.from],
                    corrected_source_x,
                    corrected_source_y,
                    req,
                );
                let target_ray = mul_vec(transpose(poses[constraint.to]), world);
                let Some((predicted_target_x, predicted_target_y)) =
                    project_camera_ray(target_ray, req)
                else {
                    continue;
                };
                let (target_dx, target_dy) = current_warps[constraint.to]
                    .as_ref()
                    .and_then(|warp| {
                        crate::texture_warp::source_to_corrected(
                            warp,
                            req.source_width,
                            req.source_height,
                            point[2],
                            point[3],
                        )
                    })
                    .map(|(corrected_x, corrected_y)| {
                        (corrected_x - point[2], corrected_y - point[3])
                    })
                    .unwrap_or((0.0, 0.0));
                samples[constraint.to].push(SourceWarpSample {
                    x: point[2],
                    y: point[3],
                    dx: target_dx + 0.5 * (predicted_target_x - (point[2] + target_dx)),
                    dy: target_dy + 0.5 * (predicted_target_y - (point[3] + target_dy)),
                    weight: per_point_weight,
                });
                let corrected_target_x = point[2] + target_dx;
                let corrected_target_y = point[3] + target_dy;
                let reverse_world = ray_to_world(
                    poses[constraint.to],
                    corrected_target_x,
                    corrected_target_y,
                    req,
                );
                let source_ray = mul_vec(transpose(poses[constraint.from]), reverse_world);
                if let Some((predicted_source_x, predicted_source_y)) =
                    project_camera_ray(source_ray, req)
                {
                    samples[constraint.from].push(SourceWarpSample {
                        x: point[0],
                        y: point[1],
                        dx: source_dx + 0.5 * (predicted_source_x - (point[0] + source_dx)),
                        dy: source_dy + 0.5 * (predicted_source_y - (point[1] + source_dy)),
                        weight: per_point_weight,
                    });
                }
            }
        }
        for tile in 0..poses.len() {
            checkpoint("source-plane-warp-tile-fit").map_err(|_| Error::Cancelled)?;
            let (mut fitted, level_diagnostics) = fit_source_plane_warp_multilevel(
                req.source_width,
                req.source_height,
                &samples[tile],
                anchors.contains(&tile),
                smoothness_weight,
            );
            let diagnostics = final_accepted_warp_level(&level_diagnostics);
            if anchors.contains(&tile) {
                // Component anchors remain an exact zero to preserve the
                // global pose gauge and legacy panorama reference.
                fitted = Some(crate::texture_warp::SourcePlaneWarp::zero());
            } else if let Some(warp) = &fitted {
                let max = warp
                    .offsets
                    .iter()
                    .map(|offset| offset[0].hypot(offset[1]))
                    .fold(0.0_f64, f64::max);
                if max < 0.5 || !diagnostics.supported {
                    fitted = None;
                }
            }
            tile_diagnostics[tile] = json!({
                "tileIndex":tile,
                "componentAnchor":anchors.contains(&tile),
                "supported":diagnostics.supported,
                "correspondenceSupport":diagnostics.support_count,
                "occupiedGridCells":diagnostics.occupied_cells,
                "occupiedSupportQuadrants":diagnostics.occupied_cells,
                "supportedControlKnots":diagnostics.supported_control_knots,
                "coarseToFineLevels":level_diagnostics.iter().enumerate().map(|(level,diag)| json!({"grid":crate::texture_warp::SOURCE_WARP_GRID_LEVELS.get(level),"supported":diag.supported,"accepted":diag.accepted,"reason":if diag.accepted {"accepted_same_set_improvement"} else if diag.supported {"supported_but_not_improving_or_safe"} else {"insufficient_spatial_support"},"supportCount":diag.support_count,"supportedControlKnots":diag.supported_control_knots,"sampleRmsBeforePx":diag.sample_rms_before_px,"sampleRmsAfterPx":diag.sample_rms_after_px,"maxOffsetPx":diag.max_offset_px,"maxLocalStrain":diag.max_strain})).collect::<Vec<_>>(),
                "sampleRmsBeforePx":diagnostics.sample_rms_before_px,
                "sampleRmsAfterPx":diagnostics.sample_rms_after_px,
                "maxOffsetPx":diagnostics.max_offset_px,
                "maxLocalStrain":diagnostics.max_strain,
                "outerIteration":outer_iteration
            });
            proposed_warps[tile] = fitted;
        }
        let (current_rms, _, _, _, current_edges, current_complete) =
            global_reprojection_metrics_with_warps(
                poses,
                visual_constraints,
                matched_edges,
                req,
                Some(&current_warps),
            );
        let current_worst = current_edges
            .iter()
            .map(|edge| edge.2)
            .fold(0.0_f64, f64::max);
        let mut accepted = None;
        for step in 0..5 {
            checkpoint("source-plane-warp-line-search").map_err(|_| Error::Cancelled)?;
            let alpha = 0.5_f64.powi(step as i32);
            let trial_warps = current_warps
                .iter()
                .zip(&proposed_warps)
                .enumerate()
                .map(|(tile, (old, proposed))| {
                    if anchors.contains(&tile) {
                        return Some(crate::texture_warp::SourcePlaneWarp::zero());
                    }
                    match (old, proposed) {
                        (Some(old), Some(proposed)) => {
                            let columns = old.columns.max(proposed.columns);
                            let rows = old.rows.max(proposed.rows);
                            let old = crate::texture_warp::resample_source_plane_warp(
                                old,
                                req.source_width,
                                req.source_height,
                                columns,
                                rows,
                            );
                            let proposed = crate::texture_warp::resample_source_plane_warp(
                                proposed,
                                req.source_width,
                                req.source_height,
                                columns,
                                rows,
                            );
                            let offsets = old
                                .offsets
                                .iter()
                                .zip(&proposed.offsets)
                                .map(|(old, proposed)| {
                                    [
                                        old[0] + alpha * (proposed[0] - old[0]),
                                        old[1] + alpha * (proposed[1] - old[1]),
                                    ]
                                })
                                .collect::<Vec<_>>();
                            let warp = crate::texture_warp::SourcePlaneWarp {
                                columns,
                                rows,
                                offsets,
                            };
                            crate::texture_warp::validate_source_plane_warp(
                                &warp,
                                req.source_width,
                                req.source_height,
                            )
                            .ok()
                            .map(|()| warp)
                        }
                        (None, Some(proposed)) => {
                            let offsets = proposed
                                .offsets
                                .iter()
                                .map(|offset| [alpha * offset[0], alpha * offset[1]])
                                .collect();
                            let warp = crate::texture_warp::SourcePlaneWarp {
                                columns: proposed.columns,
                                rows: proposed.rows,
                                offsets,
                            };
                            crate::texture_warp::validate_source_plane_warp(
                                &warp,
                                req.source_width,
                                req.source_height,
                            )
                            .ok()
                            .map(|()| warp)
                        }
                        (Some(old), None) => Some(old.clone()),
                        (None, None) => None,
                    }
                })
                .collect::<Vec<_>>();
            let (trial_rms, _, _, _, trial_edges, trial_complete) =
                global_reprojection_metrics_with_warps(
                    poses,
                    visual_constraints,
                    matched_edges,
                    req,
                    Some(&trial_warps),
                );
            let trial_worst = trial_edges
                .iter()
                .map(|edge| edge.2)
                .fold(0.0_f64, f64::max);
            if current_complete
                && trial_complete
                && trial_rms + 1e-4 < current_rms
                && trial_worst <= current_worst + 1e-3
            {
                accepted = Some(trial_warps);
                break;
            }
        }
        if let Some(accepted_warps) = accepted {
            let mut max_step = 0.0_f64;
            for (old, new) in current_warps.iter().zip(&accepted_warps) {
                if let Some(new) = new {
                    max_step = max_step.max(source_warp_max_step(
                        old.as_ref(),
                        new,
                        req.source_width,
                        req.source_height,
                    ));
                }
            }
            warps = accepted_warps;
            accepted_rounds += 1;
            if max_step <= 0.05 {
                converged = true;
                termination_reason = "offset_step_tolerance";
                break;
            }
        } else {
            termination_reason = if tile_diagnostics
                .iter()
                .all(|diagnostic| diagnostic["supported"].as_bool() != Some(true))
            {
                "no_supported_proposal"
            } else {
                "no_improving_step"
            };
            break;
        }
    }
    let (final_rms, _, _, _, final_edges, final_complete) = global_reprojection_metrics_with_warps(
        poses,
        visual_constraints,
        matched_edges,
        req,
        Some(&warps),
    );
    let final_worst = final_edges
        .iter()
        .map(|edge| edge.2)
        .fold(0.0_f64, f64::max);
    for (tile, warp) in warps.iter().enumerate() {
        let applied = warp.as_ref().filter(|warp| !warp.is_zero());
        let (max_offset, max_strain) = applied.map_or((0.0, 0.0), |warp| {
            crate::texture_warp::source_plane_warp_limits(warp, req.source_width, req.source_height)
        });
        let validated = applied.map_or(true, |warp| {
            crate::texture_warp::validate_source_plane_warp(
                warp,
                req.source_width,
                req.source_height,
            )
            .is_ok()
        });
        tile_diagnostics[tile]["finalApplied"] = json!(applied.is_some());
        tile_diagnostics[tile]["finalMaxOffsetPx"] = json!(max_offset);
        tile_diagnostics[tile]["finalMaxLocalStrain"] = json!(max_strain);
        tile_diagnostics[tile]["finalFieldValidated"] = json!(validated);
        tile_diagnostics[tile]["proposalSampleRmsAfterPx"] =
            tile_diagnostics[tile]["sampleRmsAfterPx"].clone();
    }
    let summary = json!({
        "algorithm":"per-tile-coarse-to-fine-3-5-9-robust-source-plane-offsets-v1",
        "requested":req.local_texture_warp,
        "grid":{"columns":3,"rows":3,"offsetUnits":"original-source-pixels"},
        "maximumOffsetEuclideanPx":crate::texture_warp::SOURCE_WARP_MAX_DISPLACEMENT_PX,
        "maximumLocalStrain":crate::texture_warp::SOURCE_WARP_MAX_LOCAL_STRAIN,
        "irlsIterations":5,
        "maximumOuterIterations":8,
        "proposalDamping":0.5,
        "minimumSupportPoints":32,
        "minimumOccupiedSupportQuadrants":2,
        "minimumSupportedControlKnots":4,
        "zeroPriorWeight":0.025,
        "neighborSmoothnessWeight":smoothness_weight,
        "lineSearchSteps":5,
        "acceptedRmsImprovementPx":1e-4,
        "maximumWorstEdgeRegressionPx":1e-3,
        "inverseMaximumIterations":crate::texture_warp::SOURCE_WARP_INVERSE_ITERATIONS,
        "inverseRoundTripTolerancePx":0.02,
        "attemptedRounds":attempted_rounds,
        "acceptedRounds":accepted_rounds,
        "converged":converged,
        "terminationReason":termination_reason,
        "initialSymmetricRmsPx":initial_rms,
        "finalSymmetricRmsPx":final_rms,
        "initialWorstEdgeRmsPx":initial_worst,
        "finalWorstEdgeRmsPx":final_worst,
        "completeEvidence":initial_complete && final_complete,
        "maxDisplacementPx":crate::texture_warp::SOURCE_WARP_MAX_DISPLACEMENT_PX,
        "maxLocalStrain":crate::texture_warp::SOURCE_WARP_MAX_LOCAL_STRAIN,
        "tileDiagnostics":tile_diagnostics
    });
    Ok((warps, tile_diagnostics, summary))
}

fn source_warp_max_step(
    old: Option<&crate::texture_warp::SourcePlaneWarp>,
    new: &crate::texture_warp::SourcePlaneWarp,
    width: u32,
    height: u32,
) -> f64 {
    let old = old.map(|old| {
        crate::texture_warp::resample_source_plane_warp(old, width, height, new.columns, new.rows)
    });
    new.offsets
        .iter()
        .enumerate()
        .map(|(index, new_offset)| {
            let old_offset = old.as_ref().map_or([0.0, 0.0], |warp| warp.offsets[index]);
            (old_offset[0] - new_offset[0]).hypot(old_offset[1] - new_offset[1])
        })
        .fold(0.0_f64, f64::max)
}

fn final_accepted_warp_level(
    diagnostics: &[crate::texture_warp::SourceWarpFitDiagnostics],
) -> crate::texture_warp::SourceWarpFitDiagnostics {
    diagnostics
        .iter()
        .rev()
        .find(|level| level.accepted)
        .or_else(|| diagnostics.first())
        .cloned()
        .unwrap_or_default()
}

fn diagnostic_correspondence_snapshot(
    req: &Request,
    tiles: &[CaptureTile],
    poses: &[Mat],
    constraints: &[Constraint],
    edges: &[crate::pipeline::SphericalMatchEdge],
    warps: Option<&[Option<crate::texture_warp::SourcePlaneWarp>]>,
) -> Value {
    let reliability_scales = reliability_scales_from_constraints(constraints);
    let source_hashes = tiles
        .iter()
        .enumerate()
        .map(|(index, tile)| {
            let hash = crate::fingerprint::sha256_file(&tile.path).ok();
            json!({"tileIndex":index,"sha256":hash})
        })
        .collect::<Vec<_>>();
    let accepted_edges = constraints
        .iter()
        .filter_map(|constraint| {
            let edge = edges
                .iter()
                .find(|edge| edge.from == constraint.from && edge.to == constraint.to)?;
            Some(json!({
                "from":edge.from,
                "to":edge.to,
                "rotation":constraint.rotation,
                "weight":constraint.weight,
                "reliabilityWeightScale":reliability_scales.get(&(constraint.from,constraint.to)).copied().unwrap_or(1.0),
                "matches":edge.matches,
                "inliers":edge.inliers,
                "inlierRatio":edge.inlier_ratio,
                "homographyResidualPx":edge.homography_residual,
                "points":edge.points
            }))
        })
        .collect::<Vec<_>>();
    let mut snapshot = json!({
        "schemaVersion": 1,
        "pixelBundleAlgorithmVersion": PIXEL_BUNDLE_ALGORITHM_VERSION,
        "optimizer": "anchored-component-joint-symmetric-pixel-huber",
        "coordinateFrame": "pre-layout-center-reorientation",
        "solverParameters": current_pixel_solver_parameters(),
        "localTextureWarp": req.local_texture_warp,
        "grid": {"rows":req.rows,"columns":req.columns},
        "intrinsics": {"fx":req.fx,"fy":req.fy,"cx":req.cx,"cy":req.cy,"sourceWidth":req.source_width,"sourceHeight":req.source_height},
        "matchingParameters": {"featureType":req.feature_type,"matcherType":req.matcher_type,"registrationMegapixels":req.registration_megapixels,"neighborMode":req.neighbor_mode},
        "warmStartPoses": poses,
        "sourcePlaneWarps": warps,
        "sourceIdentities": source_hashes,
        "acceptedVisualEdges": accepted_edges
    });
    let identity =
        crate::fingerprint::sha256_bytes(&serde_json::to_vec(&snapshot).unwrap_or_default());
    snapshot["snapshotHash"] = json!(identity);
    snapshot
}
fn spherical_point(ray: [f64; 3]) -> (f64, f64) {
    (ray[0].atan2(ray[2]), ray[1].asin())
}

fn validate(req: &Request) -> Result<()> {
    if req.seam_blend_mode != "feather" && req.seam_blend_mode != "deghost" {
        return Err(Error::Invalid(
            "seamBlendMode must be feather or deghost".into(),
        ));
    }
    if !req.placement_mode.is_empty()
        && req.placement_mode != "visual"
        && req.placement_mode != "grid-assisted"
    {
        return Err(Error::Invalid(
            "placementMode must be visual or grid-assisted".into(),
        ));
    }
    if req.neighbor_mode != "four"
        && req.neighbor_mode != "eight"
        && req.neighbor_mode != "adaptive"
    {
        return Err(Error::Invalid(
            "neighborMode must be 'four' or 'eight'".into(),
        ));
    }
    if !req.auto_grid_overlap {
        for (axis, overlap) in [
            ("Horizontal", req.grid_horizontal_overlap.unwrap_or(0.3)),
            ("Vertical", req.grid_vertical_overlap.unwrap_or(0.3)),
        ] {
            if !overlap.is_finite() || !(0.15..=0.8).contains(&overlap) {
                return Err(Error::Invalid(format!(
                    "grid{axis}Overlap must be finite and between 0.15 and 0.8"
                )));
            }
        }
    }
    if req.workers == 0 || req.workers > 32 {
        return Err(Error::Invalid("workers must be between 1 and 32".into()));
    }
    if !req.registration_megapixels.is_finite()
        || !(0.1..=20.0).contains(&req.registration_megapixels)
    {
        return Err(Error::Invalid(
            "registrationMegapixels must be finite and between 0.1 and 20".into(),
        ));
    }
    if req.feature_type != "sift" && req.feature_type != "orb" {
        return Err(Error::Invalid("featureType must be sift or orb".into()));
    }
    if req.matcher_type != "bf" && req.matcher_type != "flann" {
        return Err(Error::Invalid("matcherType must be bf or flann".into()));
    }
    if req.feature_type == "orb" && req.matcher_type == "flann" {
        return Err(Error::Invalid(
            "ORB descriptors require the BF matcher".into(),
        ));
    }
    if req.tiles.len() < 2 || req.rows == 0 || req.columns == 0 {
        return Err(Error::Invalid(
            "spherical alignment requires at least two tiles and positive grid dimensions".into(),
        ));
    }
    if req.rows.checked_mul(req.columns) != Some(req.tiles.len()) {
        return Err(Error::Invalid(
            "spherical tile count must match the complete grid dimensions without overflow".into(),
        ));
    }
    if req.source_width == 0
        || req.source_height == 0
        || u64::from(req.source_width) * u64::from(req.source_height) > 80_000_000
        || [req.fx, req.fy, req.cx, req.cy]
            .iter()
            .any(|v| !v.is_finite())
        || req.fx <= 0.
        || req.fy <= 0.
        || req.cx < 0.
        || req.cx >= req.source_width as f64
        || req.cy < 0.
        || req.cy >= req.source_height as f64
    {
        return Err(Error::Invalid(
            "source dimensions and pixel intrinsics are invalid".into(),
        ));
    }
    let mut cells = vec![false; req.tiles.len()];
    for t in &req.tiles {
        if t.row >= req.rows || t.column >= req.columns || t.path.trim().is_empty() {
            return Err(Error::Invalid("tile cell/path is invalid".into()));
        }
        let i = t.row * req.columns + t.column;
        if cells[i] {
            return Err(Error::Invalid("duplicate tile cell".into()));
        }
        cells[i] = true;
    }
    Ok(())
}

fn align(
    req: Request,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<Value, SphericalFailure> {
    let alignment_started = std::time::Instant::now();
    validate(&req)?;
    checkpoint("validation-complete").map_err(|message| SphericalFailure {
        code: "CANCELLED",
        message,
        diagnostics: None,
    })?;
    let mut tiles = req
        .tiles
        .iter()
        .map(|t| CaptureTile {
            row: t.row,
            column: t.column,
            path: PathBuf::from(&t.path),
            geometry: None,
        })
        .collect::<Vec<_>>();
    tiles.sort_by_key(|t| (t.row, t.column));
    let effective_workers = req
        .workers
        .min(tiles.len())
        .min(
            std::thread::available_parallelism()
                .map(usize::from)
                .unwrap_or(1),
        )
        .max(1);
    let mut forced_grid_indices = vec![false; tiles.len()];
    for tile in &req.tiles {
        forced_grid_indices[tile.row * req.columns + tile.column] = tile.force_grid;
    }
    let mut job = StitchJob::new(StitchOptions {
        rows: req.rows,
        columns: req.columns,
        projection: Projection::Planar,
        ..StitchOptions::default()
    });
    for tile in &tiles {
        checkpoint("source-validation").map_err(|message| SphericalFailure {
            code: "CANCELLED",
            message,
            diagnostics: None,
        })?;
        let image = crate::image::load(&tile.path)?;
        let dimensions = (image.width(), image.height());
        drop(image);
        if dimensions != (req.source_width, req.source_height) {
            return Err(Error::Invalid(format!(
                "tile {} is {}x{} but intrinsics declare {}x{}",
                tile.path.display(),
                dimensions.0,
                dimensions.1,
                req.source_width,
                req.source_height
            ))
            .into());
        }
    }
    if req.auto_grid_overlap {
        return align_measured_grid_only(
            req,
            tiles,
            forced_grid_indices,
            checkpoint,
            alignment_started,
        );
    }
    let primary_extraction_started = std::time::Instant::now();
    let feature_frames = crate::pipeline::spherical_extract_features_parallel(
        &tiles
            .iter()
            .map(|tile| tile.path.clone())
            .collect::<Vec<_>>(),
        (req.registration_megapixels * 1_000_000.0).round() as usize,
        effective_workers,
        &req.feature_type,
        checkpoint,
    )?;
    let primary_feature_extraction_ms = primary_extraction_started.elapsed().as_millis() as u64;
    for (tile, feature) in tiles.iter().zip(feature_frames) {
        job.add_precomputed_tile(tile.clone(), feature)?;
    }
    let (
        feature_count,
        retry_feature_count,
        retry_endpoint_count,
        peak_retry_feature_count,
        peak_retry_frame_count,
        clahe_retry_feature_count,
        peak_clahe_feature_count,
        peak_clahe_frame_count,
        initial_matching_ms,
        low_contrast_retry_ms,
        clahe_retry_ms,
        matched_edges,
    ) = job.spherical_match_edges(
        (req.registration_megapixels * 1_000_000.0).round() as usize,
        SPHERICAL_FEATURE_THREAD_LIMIT,
        SPHERICAL_RETRY_CONTRAST_THRESHOLD,
        &req.neighbor_mode,
        if req.parallel_matching {
            effective_workers
        } else {
            1
        },
        &req.feature_type,
        &req.matcher_type,
        checkpoint,
    )?;
    let total_feature_count = feature_count + retry_feature_count;
    let raw_visual_matches: usize = matched_edges.iter().map(|edge| edge.matches).sum();
    let ransac_inlier_count: usize = matched_edges.iter().map(|edge| edge.inliers).sum();
    let ransac_inlier_ratio = ransac_inlier_count as f64 / raw_visual_matches.max(1) as f64;
    let homography_residual_sum: f64 = matched_edges
        .iter()
        .map(|edge| edge.homography_residual * edge.inliers as f64)
        .sum();
    let homography_residual_weight: usize = matched_edges.iter().map(|edge| edge.inliers).sum();
    let mut constraints = Vec::new();
    let mut pairwise_residual_sum = 0.;
    let mut pairwise_residual_weight = 0.;
    let mut edge_diagnostics = Vec::with_capacity(matched_edges.len());
    let attempt_diagnostic = |attempt: &crate::pipeline::SphericalMatchAttempt| json!({"fromFeatures":attempt.from_features,"toFeatures":attempt.to_features,"matches":attempt.matches,"inliers":attempt.inliers,"inlierRatio":attempt.inlier_ratio,"reason":attempt.reason,"contrastThreshold":attempt.contrast_threshold,"clahe":attempt.clahe});
    let edge_diagnostic = |edge: &crate::pipeline::SphericalMatchEdge,
                           disposition: &str,
                           ray_median: Option<f64>,
                           ray_rms: Option<f64>| {
        {
            let (source_cells, target_cells, score) = correspondence_coverage(&edge.points, &req);
            json!({"from":edge.from,"to":edge.to,"initial":attempt_diagnostic(&edge.initial),"retry":edge.retry.as_ref().map(&attempt_diagnostic),"claheRetry":edge.clahe_retry.as_ref().map(&attempt_diagnostic),"selectedAttempt":if edge.used_clahe_retry {"clahe"} else if edge.used_retry {"lowContrast"} else {"initial"},"usedRetry":edge.used_retry,"usedClaheRetry":edge.used_clahe_retry,"matches":edge.matches,"inliers":edge.inliers,"inlierRatio":edge.inlier_ratio,"rayMedianResidualPx":ray_median,"rayRmsResidualPx":ray_rms,"spatialCoverage":{"sourceOccupiedCells":source_cells,"targetOccupiedCells":target_cells,"score":score},"cycleConsistencyPixels":Value::Null,"reliabilityWeightScale":score,"loopConflictAmbiguous":false,"disposition":disposition})
        }
    };
    for edge in &matched_edges {
        if touches_forced_grid_cell(edge.from, edge.to, &forced_grid_indices) {
            edge_diagnostics.push(edge_diagnostic(edge, "forced_grid_cell", None, None));
            continue;
        }
        let mut disposition = if edge.reason != 0 {
            match edge.reason {
                1 => "descriptor_missing_or_invalid",
                2 => "too_few_ratio_test_matches",
                _ => "ransac_failed",
            }
        } else if edge.inliers < 8 {
            "too_few_inliers"
        } else if edge.inlier_ratio < 0.15 {
            "low_inlier_ratio"
        } else {
            "ray_fit_pending"
        };
        if edge.reason != 0 {
            edge_diagnostics.push(edge_diagnostic(edge, disposition, None, None));
            continue;
        }
        if edge.inliers < 8 || edge.inlier_ratio < 0.15 {
            edge_diagnostics.push(edge_diagnostic(edge, disposition, None, None));
            continue;
        }
        let Some((target_from_source, median_residual, rms_residual)) =
            fit_ray_rotation(&edge.points, req.fx, req.fy, req.cx, req.cy)
        else {
            disposition = "ray_fit_degenerate";
            edge_diagnostics.push(edge_diagnostic(edge, disposition, None, None));
            continue;
        };
        if !median_residual.is_finite()
            || !rms_residual.is_finite()
            || median_residual > 12.
            || rms_residual > 12.
        {
            disposition = "ray_residual_exceeds_12px";
            edge_diagnostics.push(edge_diagnostic(
                edge,
                disposition,
                Some(median_residual),
                Some(rms_residual),
            ));
            continue;
        }
        disposition = "accepted";
        let from = edge.from;
        let to = edge.to;
        let source_to_target = transpose(target_from_source);
        let (_, _, coverage_score) = correspondence_coverage(&edge.points, &req);
        let base_weight = (edge.inliers as f64 * edge.inlier_ratio.max(0.05)
            / (1. + median_residual))
            .clamp(0.1, 1000.);
        let weight = base_weight * coverage_score;
        constraints.push(Constraint {
            from,
            to,
            rotation: source_to_target,
            weight,
        });
        pairwise_residual_sum += median_residual * edge.inliers as f64;
        pairwise_residual_weight += edge.inliers as f64;
        edge_diagnostics.push(edge_diagnostic(
            edge,
            disposition,
            Some(median_residual),
            Some(rms_residual),
        ));
    }
    let (loop_residuals, loop_scales, ambiguous_loops) =
        weight_neighbor_loop_conflicts(req.rows, req.columns, &mut constraints, &req);
    // Carry the same inlier/residual/coverage/loop evidence into the pixel
    // bundle. The floor keeps a valid low-texture edge participating.
    let reliability_scales = reliability_scales_from_constraints(&constraints);
    for diagnostic in &mut edge_diagnostics {
        let pair = (
            diagnostic["from"].as_u64().unwrap_or(u64::MAX) as usize,
            diagnostic["to"].as_u64().unwrap_or(u64::MAX) as usize,
        );
        if let Some(residual) = loop_residuals.get(&pair) {
            diagnostic["cycleConsistencyPixels"] = json!(residual);
        }
        diagnostic["reliabilityWeightScale"] =
            json!(reliability_scales.get(&pair).copied().unwrap_or(1.0));
        diagnostic["loopConflictAmbiguous"] = json!(ambiguous_loops.contains(&pair));
    }
    let mut visual_constraints = constraints.clone();
    let root_graph_reachable = connected_tiles(tiles.len(), &visual_constraints);
    let visual_seen = root_anchored_visual_tiles(tiles.len(), &visual_constraints);
    let visual_components = visual_components(tiles.len(), &visual_constraints);
    let mut component_by_tile = vec![0usize; tiles.len()];
    let mut direct_visual_evidence = vec![false; tiles.len()];
    let mut visual_component_edge_counts = vec![0usize; visual_components.len()];
    for (component_id, members) in visual_components.iter().enumerate() {
        for &tile_index in members {
            component_by_tile[tile_index] = component_id;
        }
    }
    for edge in &visual_constraints {
        direct_visual_evidence[edge.from] = true;
        direct_visual_evidence[edge.to] = true;
        visual_component_edge_counts[component_by_tile[edge.from]] += 1;
    }
    let mut visual_component_diagnostics = visual_components
        .iter()
        .enumerate()
        .map(|(component_id, members)| {
            let is_root_component = members.contains(&0);
            json!({
                "componentId": component_id,
                "tileIndices": members,
                "tileCount": members.len(),
                "acceptedVisualEdgeCount": visual_component_edge_counts[component_id],
                "hasDirectVisualEvidence": visual_component_edge_counts[component_id] > 0,
                "rootAnchored": is_root_component && visual_component_edge_counts[component_id] > 0,
                "containsReferenceTile": is_root_component,
                "hasVisualAnchor": visual_component_edge_counts[component_id] > 0,
                "relativePlacementSource": if is_root_component && visual_component_edge_counts[component_id] > 0 { "rootVisualComponent" } else if is_root_component { "gridEstimatedReference" } else if visual_component_edge_counts[component_id] > 0 { "gridBridge" } else { "gridEstimated" }
            })
        })
        .collect::<Vec<_>>();
    let is_grid_assisted = req.placement_mode == "grid-assisted";
    let (grid_constraints, synthesized_grid_edges, horizontal_grid_step, vertical_grid_step) =
        if is_grid_assisted {
            let horizontal_fov = 2.0 * (req.source_width as f64 / (2.0 * req.fx)).atan();
            let vertical_fov = 2.0 * (req.source_height as f64 / (2.0 * req.fy)).atan();
            let nominal_horizontal_step = exp_rotation([
                0.0,
                horizontal_fov * (1.0 - req.grid_horizontal_overlap.unwrap_or(0.3)),
                0.0,
            ]);
            // Image rows increase downward, so the source-to-target rotation
            // for the next row is a positive camera-X rotation. In the
            // camera-to-world solution this turns the center ray downward.
            let nominal_vertical_step = exp_rotation([
                vertical_fov * (1.0 - req.grid_vertical_overlap.unwrap_or(0.3)),
                0.0,
                0.0,
            ]);
            match synthesize_grid_constraints(
                req.rows,
                req.columns,
                &visual_constraints,
                &visual_seen,
                req.allow_nominal_grid_fallback
                    .then_some(nominal_horizontal_step),
                req.allow_nominal_grid_fallback
                    .then_some(nominal_vertical_step),
                horizontal_fov * 0.9,
                vertical_fov * 0.9,
            ) {
                Ok((grid, diagnostics, horizontal, vertical)) => {
                    (grid, diagnostics, horizontal, vertical)
                }
                Err(message) => {
                    return Err(SphericalFailure {
                        code: "REGISTRATION_FAILED",
                        message,
                        diagnostics: Some(json!({
                            "placementMode": "grid-assisted",
                            "visualTileCount": visual_seen.iter().filter(|connected| **connected).count(),
                            "totalTileCount": tiles.len(),
                            "acceptedVisualEdgeCount": visual_constraints.len(),
                            "horizontalGridStep": grid_step_diagnostic(robust_grid_step(&visual_constraints.iter().filter(|edge| edge.from / req.columns == edge.to / req.columns && edge.to % req.columns == edge.from % req.columns + 1).map(|edge| edge.rotation).collect::<Vec<_>>()).as_ref()),
                            "verticalGridStep": grid_step_diagnostic(robust_grid_step(&visual_constraints.iter().filter(|edge| edge.from % req.columns == edge.to % req.columns && edge.to / req.columns == edge.from / req.columns + 1).map(|edge| edge.rotation).collect::<Vec<_>>()).as_ref()),
                            "edges": edge_diagnostics
                        })),
                    });
                }
            }
        } else {
            (Vec::new(), Vec::new(), None, None)
        };
    if is_grid_assisted {
        let horizontal_fov = 2.0 * (req.source_width as f64 / (2.0 * req.fx)).atan();
        let vertical_fov = 2.0 * (req.source_height as f64 / (2.0 * req.fy)).atan();
        for (axis, step, fov) in [
            ("horizontal", horizontal_grid_step.as_ref(), horizontal_fov),
            ("vertical", vertical_grid_step.as_ref(), vertical_fov),
        ] {
            if let Some(step) = step {
                let angle = log_rotation(step.rotation)
                    .iter()
                    .map(|value| value * value)
                    .sum::<f64>()
                    .sqrt();
                if !angle.is_finite() || angle <= 1e-6 || angle >= fov * 0.9 {
                    return Err(SphericalFailure {
                        code: "REGISTRATION_FAILED",
                        message: format!(
                            "grid-assisted {axis} step {angle:.4}rad is outside the useful overlap range"
                        ),
                        diagnostics: Some(json!({
                            "placementMode": "grid-assisted",
                            "axis": axis,
                            "stepRadians": angle,
                            "maximumOverlapStepRadians": fov * 0.9,
                            "gridHorizontalStep": grid_step_diagnostic(horizontal_grid_step.as_ref()),
                            "gridVerticalStep": grid_step_diagnostic(vertical_grid_step.as_ref()),
                            "edges": edge_diagnostics
                        })),
                    });
                }
            }
        }
    }
    constraints.extend_from_slice(&grid_constraints);
    let seen = connected_tiles(tiles.len(), &constraints);
    if seen.iter().any(|v| !*v) || (!is_grid_assisted && visual_constraints.is_empty()) {
        let disconnected_tiles = seen
            .iter()
            .enumerate()
            .filter_map(|(i, connected)| (!connected).then_some(i))
            .collect::<Vec<_>>();
        let mut failure = SphericalFailure {
            code: "REGISTRATION_FAILED",
            message: "visual registration graph is disconnected; no spherical layout emitted"
                .into(),
            diagnostics: Some(
                json!({"placementMode":if is_grid_assisted { "grid-assisted" } else { "visual" },"featureCount":feature_count,"retryFeatureCount":retry_feature_count,"retryEndpointTileCount":retry_endpoint_count,"claheRetryFeatureCount":clahe_retry_feature_count,"featureCacheConfiguredEstimateBytes":tiles.len() as u64*2*2500*576,"featureCacheEstimateIsConfiguredNotHardBound":true,"attemptedEdgeCount":matched_edges.len(),"acceptedEdgeCount":visual_constraints.len(),"synthesizedGridEdgeCount":synthesized_grid_edges.len(),"connectedTileCount":seen.iter().filter(|connected| **connected).count(),"visualTileCount":visual_seen.iter().filter(|connected| **connected).count(),"totalTileCount":tiles.len(),"disconnectedTileIndices":disconnected_tiles,"gridEstimatedTileIndices":visual_seen.iter().enumerate().filter_map(|(i, connected)| (!connected).then_some(i)).collect::<Vec<_>>(),"gridHorizontalStepRadians":horizontal_grid_step.as_ref().map(|step| log_rotation(step.rotation).iter().map(|value| value*value).sum::<f64>().sqrt()),"gridVerticalStepRadians":vertical_grid_step.as_ref().map(|step| log_rotation(step.rotation).iter().map(|value| value*value).sum::<f64>().sqrt()),"gridHorizontalStep":grid_step_diagnostic(horizontal_grid_step.as_ref()),"gridVerticalStep":grid_step_diagnostic(vertical_grid_step.as_ref()),"synthesizedGridEdges":synthesized_grid_edges,"edges":edge_diagnostics}),
            ),
        };
        // Keep the failure actionable in logs that only display the message field.
        failure.message.push_str(&format!(
            "; accepted {}/{} neighbor edges, {} tiles disconnected",
            visual_constraints.len(),
            matched_edges.len(),
            disconnected_tiles.len()
        ));
        return Err(failure);
    }
    let pose_optimization_started = std::time::Instant::now();
    let mut poses = solve_orientations(tiles.len(), &constraints)
        .ok_or_else(|| Error::Registration("camera orientation optimization failed".into()))?;
    let (
        pixel_reinitialized_camera_count,
        pixel_refined_camera_count,
        pixel_refinement_before_symmetric_l2_norm,
        pixel_refinement_after_symmetric_l2_norm,
        pixel_refinement_sweeps,
        pixel_refinement_converged,
        pixel_pcg_max_iterations,
        pixel_pcg_max_relative_residual,
        pixel_pcg_all_converged,
        pixel_pcg_failed_attempts,
        pixel_dense_cholesky_fallback_count,
        pixel_max_accepted_linear_residual,
    ) = if is_grid_assisted {
        refine_visual_component_pixels_with_reliability(
            &mut poses,
            &visual_constraints,
            &matched_edges,
            &req,
            checkpoint,
            true,
            &reliability_scales,
        )?
    } else {
        (0, 0, 0.0, 0.0, 0, true, 0, 0.0, true, 0, 0, 0.0)
    };
    let cycle_pruning_disabled_until_joint_loo = false;
    let pixel_post_prune_started = std::time::Instant::now();
    let prune_outcome = if is_grid_assisted {
        prune_visual_edges_with_joint_leave_one_out_weighted(
            &mut poses,
            &mut visual_constraints,
            &matched_edges,
            &req,
            checkpoint,
            None,
            &reliability_scales,
        )?
    } else {
        JointPruneOutcome {
            rejected_edges: Vec::new(),
            evaluations: Vec::new(),
            budget_exceeded: false,
            final_refinement: None,
        }
    };
    let cycle_rejected_visual_edges = prune_outcome.rejected_edges;
    let cycle_loo_evaluations = prune_outcome.evaluations;
    let cycle_prune_budget_exceeded = prune_outcome.budget_exceeded;
    let post_prune_pixel_refinement = prune_outcome.final_refinement;
    let pixel_post_prune_optimization_ms = if cycle_loo_evaluations.is_empty() {
        0
    } else {
        pixel_post_prune_started.elapsed().as_millis() as u64
    };
    let cycle_rejected_visual_edge_count = cycle_rejected_visual_edges.len();
    for rejected in &cycle_rejected_visual_edges {
        let from = rejected["from"].as_u64().unwrap_or(u64::MAX) as usize;
        let to = rejected["to"].as_u64().unwrap_or(u64::MAX) as usize;
        if let Some(edge) = edge_diagnostics.iter_mut().find(|entry| {
            entry["from"].as_u64() == Some(from as u64) && entry["to"].as_u64() == Some(to as u64)
        }) {
            edge["disposition"] = json!("rejected_joint_pixel_leave_one_out_conflict");
            edge["cyclePrune"] = rejected.clone();
        }
    }
    let mut remaining_component_edge_counts = vec![0usize; visual_components.len()];
    direct_visual_evidence.fill(false);
    for edge in &visual_constraints {
        remaining_component_edge_counts[component_by_tile[edge.from]] += 1;
        direct_visual_evidence[edge.from] = true;
        direct_visual_evidence[edge.to] = true;
    }
    for (component_id, diagnostic) in visual_component_diagnostics.iter_mut().enumerate() {
        diagnostic["acceptedVisualEdgeCount"] =
            json!(remaining_component_edge_counts[component_id]);
        diagnostic["hasDirectVisualEvidence"] =
            json!(remaining_component_edge_counts[component_id] > 0);
        if diagnostic["rootAnchored"].as_bool() == Some(true) {
            diagnostic["rootAnchored"] = json!(remaining_component_edge_counts[component_id] > 0);
        }
        diagnostic["hasVisualAnchor"] = json!(remaining_component_edge_counts[component_id] > 0);
    }
    // Leave-one-out may alter the accepted graph, and the joint pixel solve may
    // refine each visual component independently. Reconcile their final rigid
    // gauges against the grid bridges now, while every accepted visual component
    // remains an indivisible body.
    let grid_component_pose_refinement = if is_grid_assisted {
        refine_grid_component_poses(
            &mut poses,
            &visual_constraints,
            &grid_constraints,
            checkpoint,
        )?
    } else {
        json!({"applied":false,"reason":"disabled_for_visual_placement"})
    };
    let pose_optimization_ms = pose_optimization_started.elapsed().as_millis() as u64;
    let total_weight = visual_constraints
        .iter()
        .map(|edge| edge.weight)
        .sum::<f64>();
    let mut rotation_vector_sum = [0.; 3];
    for edge in &visual_constraints {
        let predicted = mul(transpose(poses[edge.from]), poses[edge.to]);
        let residual = mul(transpose(edge.rotation), predicted);
        let vector = log_rotation(residual);
        for axis in 0..3 {
            rotation_vector_sum[axis] += edge.weight * vector[axis] * vector[axis];
        }
    }
    let rotation_vector_rms = rotation_vector_sum.map(|sum| (sum / total_weight).sqrt());
    let rms = rotation_vector_rms
        .iter()
        .map(|value| value * value)
        .sum::<f64>()
        .sqrt();
    // This focal-scaled geodesic remains for diagnosis, but is not a pixel
    // reprojection metric: roll, yaw, and pitch have different image effects.
    let geodesic_rms_focal_equivalent = rms * (req.fx + req.fy) * 0.5;
    let (
        raw_global_reprojection_rms,
        raw_global_reprojection_p95,
        raw_global_reprojection_max,
        raw_global_reprojection_count,
        _raw_edge_reprojection,
        raw_complete_reprojection_evidence,
    ) = global_reprojection_metrics(&poses, &visual_constraints, &matched_edges, &req);
    let (source_plane_warps, source_warp_tile_diagnostics, source_warp_refinement) = if req
        .local_texture_warp
        && !visual_constraints.is_empty()
    {
        fit_source_plane_warps(
            &poses,
            &visual_constraints,
            &matched_edges,
            &req,
            checkpoint,
            crate::texture_warp::SOURCE_WARP_SMOOTHNESS_WEIGHT,
        )?
    } else {
        (
            vec![None; poses.len()],
            vec![Value::Null; poses.len()],
            json!({"requested":req.local_texture_warp,"enabled":false,"reason":"no supported visual correspondences or feature disabled"}),
        )
    };
    let (
        global_reprojection_rms,
        global_reprojection_p95,
        global_reprojection_max,
        global_reprojection_count,
        mut edge_reprojection,
        complete_reprojection_evidence,
    ) = if req.local_texture_warp {
        global_reprojection_metrics_with_warps(
            &poses,
            &visual_constraints,
            &matched_edges,
            &req,
            Some(&source_plane_warps),
        )
    } else {
        global_reprojection_metrics(&poses, &visual_constraints, &matched_edges, &req)
    };
    edge_reprojection.sort_by(|a, b| b.2.total_cmp(&a.2));
    let maximum_edge_reprojection_rms = edge_reprojection
        .first()
        .map(|entry| entry.2)
        .unwrap_or(f64::INFINITY);
    let worst_edge_reprojections = edge_reprojection.iter().take(5)
        .map(|(from, to, rms, count)| json!({"from":from,"to":to,"rmsPx":rms,"correspondenceCount":count}))
        .collect::<Vec<_>>();
    const MAX_GLOBAL_REPROJECTION_RMS_PIXELS: f64 = 12.0;
    const MAX_EDGE_REPROJECTION_RMS_PIXELS: f64 = 12.0;
    let nominal_only_layout = is_grid_assisted
        && req.allow_nominal_grid_fallback
        && visual_constraints.is_empty()
        && synthesized_grid_edges
            .iter()
            .any(|edge| edge["rotationSource"] == "nominalFovOverlap");
    if cycle_prune_budget_exceeded
        || (!nominal_only_layout && !global_reprojection_rms.is_finite())
        || !complete_reprojection_evidence && !nominal_only_layout
        || (!nominal_only_layout
            && (global_reprojection_rms > MAX_GLOBAL_REPROJECTION_RMS_PIXELS
                || maximum_edge_reprojection_rms > MAX_EDGE_REPROJECTION_RMS_PIXELS))
    {
        let message = format!(
            "global matched-ray reprojection is {:.2}px RMS (worst edge {:.2}px; limit {:.1}px); supplied intrinsics or scene parallax may be unsuitable",
            global_reprojection_rms,
            maximum_edge_reprojection_rms,
            MAX_GLOBAL_REPROJECTION_RMS_PIXELS
        );
        return Err(SphericalFailure {
            code: "REGISTRATION_FAILED",
            message,
            diagnostics: Some(json!({
                "featureCount":feature_count,
                "retryFeatureCount":retry_feature_count,
                "retryEndpointTileCount":retry_endpoint_count,
                "claheRetryFeatureCount":clahe_retry_feature_count,
                "placementMode":if is_grid_assisted { "grid-assisted" } else { "visual" },
                "matchedEdgeCount":visual_constraints.len(),
                "synthesizedGridEdgeCount":synthesized_grid_edges.len(),
                "gridEstimatedTileIndices":visual_seen.iter().enumerate().filter_map(|(i, connected)| (!connected).then_some(i)).collect::<Vec<_>>(),
                "correspondenceCount":global_reprojection_count,
                "completeCorrespondenceEvidence":complete_reprojection_evidence,
                "rotationGeodesicRmsRadians":rms,
                "rotationGeodesicRmsTimesFocalPx":geodesic_rms_focal_equivalent,
                "rotationVectorRmsRadians":rotation_vector_rms,
                "globalRayReprojectionRmsPx":global_reprojection_rms,
                "globalRayReprojectionP95Px":global_reprojection_p95,
                "globalRayReprojectionMaxPx":global_reprojection_max,
                "rawRotationOnlyGlobalRayReprojectionRmsPx":raw_global_reprojection_rms,
                "rawRotationOnlyGlobalRayReprojectionP95Px":raw_global_reprojection_p95,
                "rawRotationOnlyGlobalRayReprojectionMaxPx":raw_global_reprojection_max,
                "rawRotationOnlyCorrespondenceCount":raw_global_reprojection_count,
                "rawRotationOnlyCompleteEvidence":raw_complete_reprojection_evidence,
                "correctedSourcePlaneSymmetricReprojectionRmsPx":global_reprojection_rms,
                "localTextureWarpEnabled":req.local_texture_warp,
                "sourcePlaneWarpRefinement":source_warp_refinement,
                "sourcePlaneWarpTiles":source_warp_tile_diagnostics,
                "maximumEdgeReprojectionRmsPx":maximum_edge_reprojection_rms,
                "cycleRejectedVisualEdges":cycle_rejected_visual_edges,
                "cycleLeaveOneOutEvaluations":cycle_loo_evaluations,
                "cyclePruneBudgetExceeded":cycle_prune_budget_exceeded,
                "cyclePruningDisabledUntilJointLeaveOneOut":cycle_pruning_disabled_until_joint_loo,
                "pixelPcgMaxIterations":pixel_pcg_max_iterations,
                "pixelPcgMaxRelativeResidual":pixel_pcg_max_relative_residual,
                "pixelPcgAllSolvesConverged":pixel_pcg_all_converged,
                "pixelPcgFailedAttempts":pixel_pcg_failed_attempts,
                "pixelDenseCholeskyFallbackCount":pixel_dense_cholesky_fallback_count,
                "pixelMaxAcceptedLinearResidual":pixel_max_accepted_linear_residual,
                "cyclePruneBudgetPolicy":"max(1, floor(componentVisualEdgeCount / 20)); the minimum of one can exceed 5% for components smaller than 20 edges",
                "postPrunePixelRefinement":post_prune_pixel_refinement,
                "gridComponentPoseRefinement":grid_component_pose_refinement,
                "cyclePruneAndPostPruneOptimizationMs":pixel_post_prune_optimization_ms,
                "maximumGlobalRayReprojectionRmsPx":MAX_GLOBAL_REPROJECTION_RMS_PIXELS,
                "maximumEdgeReprojectionRmsLimitPx":MAX_EDGE_REPROJECTION_RMS_PIXELS,
                "initialPixelRefinement":{"cameraCount":pixel_refined_camera_count,"reinitializedCameraCount":pixel_reinitialized_camera_count,"beforeSymmetricL2NormPx":pixel_refinement_before_symmetric_l2_norm,"afterSymmetricL2NormPx":pixel_refinement_after_symmetric_l2_norm,"iterations":pixel_refinement_sweeps,"converged":pixel_refinement_converged,"pcgMaxIterations":pixel_pcg_max_iterations,"pcgMaxRelativeResidual":pixel_pcg_max_relative_residual,"pcgAllSolvesConverged":pixel_pcg_all_converged,"pcgFailedAttempts":pixel_pcg_failed_attempts},
                "pixelRefinementCameraCount":pixel_refined_camera_count,
                "pixelReinitializedCameraCount":pixel_reinitialized_camera_count,
                "pixelRefinementSweeps":pixel_refinement_sweeps,
                "pixelRefinementConverged":pixel_refinement_converged,
                "pixelRefinementBeforeSymmetricL2NormPx":pixel_refinement_before_symmetric_l2_norm,
                "pixelRefinementAfterSymmetricL2NormPx":pixel_refinement_after_symmetric_l2_norm,
                "pixelRefinementModel":if is_grid_assisted { "anchored-visual-component-joint-symmetric-pixel-huber-pcg" } else { "disabled" },
                "diagnosticTilePoses":tiles.iter().enumerate().map(|(index, tile)| json!({"index":index,"row":tile.row,"column":tile.column,"cameraToWorld":poses[index]})).collect::<Vec<_>>(),
                "diagnosticCorrespondenceSnapshot":req.include_diagnostic_correspondences.then(|| diagnostic_correspondence_snapshot(&req, &tiles, &poses, &visual_constraints, &matched_edges, Some(&source_plane_warps))),
                "worstEdges":worst_edge_reprojections,
                "edges":edge_diagnostics
            })),
        });
    }
    let report = json!({
        "geometryModel": if source_plane_warps.iter().flatten().any(|warp| !warp.is_zero()) { "visual-global-rotation-with-bounded-local-source-plane-warp" } else { "visual-sift-ransac-inlier-rays-wahba-global-rotation" },
        "featurePixelBudget": (req.registration_megapixels * 1_000_000.0).round() as usize,
        "featureThreadLimit": SPHERICAL_FEATURE_THREAD_LIMIT,
        "featureCacheEstimateBytes": total_feature_count as u64 * 576,
        "featureCacheConfiguredEstimateBytes": tiles.len() as u64 * 2 * 2500 * 576,
        "featureCacheEstimateIsConfiguredNotHardBound": true,
        "featureCacheSets": if retry_endpoint_count == 0 { 1 } else { 2 },
        "peakMemoryMeasured": false,
        "featureCount": feature_count,
        "retryFeatureCount": retry_feature_count,
        "retryEndpointTileCount": retry_endpoint_count,
        "claheRetryFeatureCount": clahe_retry_feature_count,
        "rawVisualMatches": raw_visual_matches,
        "ransacInlierCount": ransac_inlier_count,
        "ransacInlierRatio": ransac_inlier_ratio,
        "usedRayCorrespondenceCount": pairwise_residual_weight,
        "matchedEdges": visual_constraints.len(),
        "totalEdges": matched_edges.len(),
        "totalTileCount": tiles.len(),
        "medianHomographyRansacResidualPx": if homography_residual_weight > 0 { json!(homography_residual_sum / homography_residual_weight as f64) } else { Value::Null },
        "pairwiseMedianRotationResidualPixelEquivalent": if pairwise_residual_weight > 0. { json!(pairwise_residual_sum / pairwise_residual_weight) } else { Value::Null },
        "orientationRmsRadians": rms,
        "orientationRmsPixelEquivalent": geodesic_rms_focal_equivalent,
        "rotationGeodesicRmsTimesFocalPx": geodesic_rms_focal_equivalent,
        "rotationVectorRmsRadians": rotation_vector_rms,
        "globalRayReprojectionRmsPx": global_reprojection_rms,
        "globalRayReprojectionP95Px": global_reprojection_p95,
        "globalRayReprojectionMaxPx": global_reprojection_max,
        "rawRotationOnlyGlobalRayReprojectionRmsPx":raw_global_reprojection_rms,
        "rawRotationOnlyGlobalRayReprojectionP95Px":raw_global_reprojection_p95,
        "rawRotationOnlyGlobalRayReprojectionMaxPx":raw_global_reprojection_max,
        "rawRotationOnlyCorrespondenceCount":raw_global_reprojection_count,
        "rawRotationOnlyCompleteEvidence":raw_complete_reprojection_evidence,
        "correctedSourcePlaneSymmetricReprojectionRmsPx":global_reprojection_rms,
        "localTextureWarpEnabled":req.local_texture_warp,
        "sourcePlaneWarpRefinement":source_warp_refinement,
        "sourcePlaneWarpTiles":source_warp_tile_diagnostics,
        "maximumEdgeReprojectionRmsPx": maximum_edge_reprojection_rms,
        "cycleRejectedVisualEdges": cycle_rejected_visual_edges,
        "cycleLeaveOneOutEvaluations": cycle_loo_evaluations,
        "cyclePruneBudgetExceeded": cycle_prune_budget_exceeded,
        "cyclePruningDisabledUntilJointLeaveOneOut": cycle_pruning_disabled_until_joint_loo,
        "reliabilityWeightScaleDefinition": "relative confidence = final edge constraint weight / median accepted visual constraint weight, clamped to [0.001, 1.0]; it is not a blur score",
        "cyclePruneBudgetPolicy": "max(1, floor(componentVisualEdgeCount / 20)); the minimum of one can exceed 5% for components smaller than 20 edges",
        "postPrunePixelRefinement": post_prune_pixel_refinement,
        "gridComponentPoseRefinement": grid_component_pose_refinement,
        "cyclePruneAndPostPruneOptimizationMs": pixel_post_prune_optimization_ms,
        "maximumGlobalRayReprojectionRmsPx": MAX_GLOBAL_REPROJECTION_RMS_PIXELS,
        "maximumEdgeReprojectionRmsLimitPx": MAX_EDGE_REPROJECTION_RMS_PIXELS,
        "globalReprojectionCorrespondenceCount": global_reprojection_count,
        "completeCorrespondenceEvidence": complete_reprojection_evidence,
        "nominalGridOnlyNeedsVisualReview": nominal_only_layout,
        "intrinsicsSource": "caller-supplied-pixel-intrinsics",
        "nominalIntrinsics": true,
        "rendered": false,
        "outputDir": req.output_dir,
        "edgeDiagnostics": edge_diagnostics
    });
    let mut report = report;
    if nominal_only_layout {
        report["geometryModel"] = json!("nominal-fov-grid");
    }
    report["neighborMode"] = json!(req.neighbor_mode);
    report["parallelMatching"] = json!(req.parallel_matching);
    report["requestedMatchingWorkers"] = json!(req.workers);
    report["effectiveMatchingWorkers"] = json!(if req.parallel_matching {
        effective_workers.min(matched_edges.len().max(1))
    } else {
        1
    });
    report["featureType"] = json!(req.feature_type);
    report["matcherType"] = json!(req.matcher_type);
    report["registrationMegapixels"] = json!(req.registration_megapixels);
    report["requestedWorkers"] = json!(req.workers);
    report["effectiveWorkers"] = json!(effective_workers);
    report["estimatedPrimaryDescriptorBytes"] = json!(feature_count as u64 * 576);
    report["estimatedPrimaryDescriptorBytesOnly"] = json!(true);
    report["alignmentMemoryBudgetIsSeparateFromRendererMemoryBudget"] = json!(true);
    report["estimatedPeakRetryDescriptorBytes"] = json!(peak_retry_feature_count as u64 * 576);
    report["peakRetryFeatureFrames"] = json!(peak_retry_frame_count);
    report["estimatedPeakClaheDescriptorBytes"] = json!(peak_clahe_feature_count as u64 * 576);
    report["peakClaheFeatureFrames"] = json!(peak_clahe_frame_count);
    report["estimatedPeakDescriptorBytes"] = json!(
        (feature_count
            .max(peak_retry_feature_count)
            .max(peak_clahe_feature_count) as u64)
            * 576
    );
    report["primaryFeatureExtractionMs"] = json!(primary_feature_extraction_ms);
    report["featureExtractionMs"] = json!(primary_feature_extraction_ms);
    report["initialMatchingMs"] = json!(initial_matching_ms);
    report["lowContrastRetryMs"] = json!(low_contrast_retry_ms);
    report["claheRetryMs"] = json!(clahe_retry_ms);
    report["poseOptimizationMs"] = json!(pose_optimization_ms);
    report["pixelRefinementCameraCount"] = json!(pixel_refined_camera_count);
    report["pixelReinitializedCameraCount"] = json!(pixel_reinitialized_camera_count);
    report["pixelRefinementBeforeSymmetricL2NormPx"] =
        json!(pixel_refinement_before_symmetric_l2_norm);
    report["pixelRefinementAfterSymmetricL2NormPx"] =
        json!(pixel_refinement_after_symmetric_l2_norm);
    report["pixelRefinementSweeps"] = json!(pixel_refinement_sweeps);
    report["pixelRefinementConverged"] = json!(pixel_refinement_converged);
    report["pixelPcgMaxIterations"] = json!(pixel_pcg_max_iterations);
    report["pixelPcgMaxRelativeResidual"] = json!(pixel_pcg_max_relative_residual);
    report["pixelPcgAllSolvesConverged"] = json!(pixel_pcg_all_converged);
    report["pixelPcgFailedAttempts"] = json!(pixel_pcg_failed_attempts);
    report["pixelDenseCholeskyFallbackCount"] = json!(pixel_dense_cholesky_fallback_count);
    report["pixelMaxAcceptedLinearResidual"] = json!(pixel_max_accepted_linear_residual);
    report["initialPixelRefinement"] = json!({
        "cameraCount":pixel_refined_camera_count,
        "reinitializedCameraCount":pixel_reinitialized_camera_count,
        "beforeSymmetricL2NormPx":pixel_refinement_before_symmetric_l2_norm,
        "afterSymmetricL2NormPx":pixel_refinement_after_symmetric_l2_norm,
        "iterations":pixel_refinement_sweeps,
        "converged":pixel_refinement_converged,
        "pcgMaxIterations":pixel_pcg_max_iterations,
        "pcgMaxRelativeResidual":pixel_pcg_max_relative_residual,
        "pcgAllSolvesConverged":pixel_pcg_all_converged,
        "pcgFailedAttempts":pixel_pcg_failed_attempts
    });
    report["pixelRefinementModel"] = json!(if is_grid_assisted {
        "anchored-visual-component-joint-symmetric-pixel-huber-pcg"
    } else {
        "disabled"
    });
    report["totalAlignmentMs"] = json!(alignment_started.elapsed().as_millis() as u64);
    report["placementMode"] = json!(if is_grid_assisted {
        "grid-assisted"
    } else {
        "visual"
    });
    report["renderBlendMode"] = json!(req.seam_blend_mode);
    if is_grid_assisted {
        report["geometryModel"] = json!(
            "visual-component-rigid-grid-bridge-refinement-plus-sift-ransac-local-rotation-steps"
        );
    }
    report["synthesizedGridEdgeCount"] = json!(synthesized_grid_edges.len());
    report["synthesizedGridEdges"] = json!(synthesized_grid_edges);
    report["totalConstraintCount"] = json!(visual_constraints.len() + grid_constraints.len());
    report["forcedGridTileCount"] =
        json!(forced_grid_indices.iter().filter(|forced| **forced).count());
    report["forcedGridTileIndices"] = json!(forced_grid_indices
        .iter()
        .enumerate()
        .filter_map(|(index, forced)| forced.then_some(index))
        .collect::<Vec<_>>());
    report["connectedTileCount"] =
        json!(visual_seen.iter().filter(|connected| **connected).count());
    report["visualTileCount"] = json!(visual_seen.iter().filter(|connected| **connected).count());
    report["acceptedVisualEvidenceTileCount"] = json!(direct_visual_evidence
        .iter()
        .filter(|supported| **supported)
        .count());
    report["acceptedVisualEvidenceTileIndices"] = json!(direct_visual_evidence
        .iter()
        .enumerate()
        .filter_map(|(index, supported)| supported.then_some(index))
        .collect::<Vec<_>>());
    report["rootAnchoredVisualTileCount"] =
        json!(visual_seen.iter().filter(|connected| **connected).count());
    report["rootGraphReachableTileCount"] = json!(root_graph_reachable
        .iter()
        .filter(|connected| **connected)
        .count());
    report["graphConnectedTileCount"] = json!(seen.iter().filter(|connected| **connected).count());
    report["visualGraphComponentCount"] = json!(visual_components.len());
    report["visualComponentCount"] = json!(visual_component_edge_counts
        .iter()
        .filter(|edge_count| **edge_count > 0)
        .count());
    report["visualComponents"] = json!(visual_component_diagnostics);
    report["gridBridgedTileIndices"] = json!(visual_seen
        .iter()
        .enumerate()
        .filter_map(|(index, connected)| (!*connected).then_some(index))
        .collect::<Vec<_>>());
    report["gridBridgedEdges"] = json!(synthesized_grid_edges);
    report["gridBridgedEdgeCount"] = json!(synthesized_grid_edges.len());
    report["gridEstimatedTileCount"] =
        json!(visual_seen.iter().filter(|connected| !**connected).count());
    report["gridEstimatedTileIndices"] = json!(visual_seen
        .iter()
        .enumerate()
        .filter_map(|(i, connected)| (!connected).then_some(i))
        .collect::<Vec<_>>());
    report["gridHorizontalStepRadians"] = json!(horizontal_grid_step.as_ref().map(|step| {
        log_rotation(step.rotation)
            .iter()
            .map(|value| value * value)
            .sum::<f64>()
            .sqrt()
    }));
    report["gridVerticalStepRadians"] = json!(vertical_grid_step.as_ref().map(|step| {
        log_rotation(step.rotation)
            .iter()
            .map(|value| value * value)
            .sum::<f64>()
            .sqrt()
    }));
    report["gridHorizontalStep"] = grid_step_diagnostic(horizontal_grid_step.as_ref());
    report["gridVerticalStep"] = grid_step_diagnostic(vertical_grid_step.as_ref());
    report["gridEstimatedPlacementHasDirectVisualEvidence"] = json!(false);
    let mut quality_warnings = Vec::<String>::new();
    if is_grid_assisted && !pixel_refinement_converged {
        quality_warnings.push(format!(
            "joint symmetric pixel bundle did not converge within {} iterations",
            MAX_PIXEL_REFINEMENT_ITERATIONS
        ));
    }
    if is_grid_assisted && grid_component_pose_refinement["converged"].as_bool() == Some(false) {
        quality_warnings.push(
            "component-level grid bridge pose refinement did not converge; estimated placements require visual review".into(),
        );
    }
    if is_grid_assisted && !pixel_pcg_all_converged {
        quality_warnings.push(format!(
            "at least one PCG linear solve was inexact (maximum relative residual {:.3e}); inspect pixel bundle diagnostics",
            pixel_pcg_max_relative_residual
        ));
    }
    if global_reprojection_rms.is_finite()
        && global_reprojection_rms > MAX_GLOBAL_REPROJECTION_RMS_PIXELS
    {
        quality_warnings.push(format!(
            "global matched-ray reprojection is {:.2}px RMS (limit {:.1}px)",
            global_reprojection_rms, MAX_GLOBAL_REPROJECTION_RMS_PIXELS
        ));
    }
    if maximum_edge_reprojection_rms.is_finite()
        && maximum_edge_reprojection_rms > MAX_EDGE_REPROJECTION_RMS_PIXELS
    {
        quality_warnings.push(format!(
            "worst measured neighbor edge reprojection is {:.2}px RMS (limit {:.1}px)",
            maximum_edge_reprojection_rms, MAX_EDGE_REPROJECTION_RMS_PIXELS
        ));
    }
    if cycle_rejected_visual_edge_count > 0 {
        quality_warnings.push(format!(
            "{} visual edges were rejected after converged joint pixel leave-one-out review; inspect the held-out residuals and review the panorama",
            cycle_rejected_visual_edge_count
        ));
    }
    let locally_warped_tile_count = source_plane_warps
        .iter()
        .flatten()
        .filter(|warp| !warp.is_zero())
        .count();
    if locally_warped_tile_count > 0 {
        quality_warnings.push(format!(
            "bounded local source-plane warps were applied to {locally_warped_tile_count} tiles; inspect structure and seams visually"
        ));
    }
    if is_grid_assisted && visual_seen.iter().any(|connected| !connected) {
        quality_warnings.push(format!(
            "{} tiles are outside the visual component rooted at tile (0,0); accepted visual components remain visible in diagnostics, and synthesized grid edges determine their relative placement; inspect the preview",
            visual_seen.iter().filter(|connected| !**connected).count()
        ));
    }
    if is_grid_assisted && !direct_visual_evidence[0] && !visual_constraints.is_empty() {
        quality_warnings.push(
            "reference tile (0,0) has no accepted visual edge; other visual components still contribute to the solved layout but are positioned relative to the reference through synthesized grid edges".into(),
        );
    }
    if !ambiguous_loops.is_empty() {
        quality_warnings.push(format!(
            "{} neighbor-loop conflicts have similar correspondence support across competing edges; loop evidence could not identify a single bad edge, so inspect the affected seams",
            ambiguous_loops.len()
        ));
    } else if !loop_scales.is_empty() {
        quality_warnings.push(format!(
            "{} lower-support neighbor edges were downweighted after inconsistent 2x2 loops; inspect the affected seams",
            loop_scales.len()
        ));
    }
    if nominal_only_layout {
        quality_warnings.push(
            "all camera placements use nominal FOV overlap without visual correspondence evidence; inspect the preview before use".into(),
        );
    }
    report["qualityStatus"] = json!(if quality_warnings.is_empty() {
        "passed-measured-checks"
    } else {
        "needs-visual-review"
    });
    report["qualityWarnings"] = json!(quality_warnings);
    report["estimatedPositionsVerified"] = json!(false);
    report["worstMeasuredEdges"] = json!(worst_edge_reprojections);
    let layout_tiles = tiles
        .iter()
        .enumerate()
        .map(|(i, tile)| {
            let mut entry = json!({
                "row":tile.row,"column":tile.column,"path":tile.path,
                "width":req.source_width,"height":req.source_height,
                "fx":req.fx,"fy":req.fy,"cx":req.cx,"cy":req.cy,
                "cameraToWorld":poses[i],
                "positionSource":if visual_seen[i] { "visual" } else { "gridEstimated" },
                "directVisualEvidence":direct_visual_evidence[i],
                "visualComponentId":component_by_tile[i],
                "visualConnectedToReference":visual_seen[i],
                "gridBridgeRequired":!visual_seen[i],
                "forceGrid":forced_grid_indices[i]
            });
            if let Some(warp) = source_plane_warps
                .get(i)
                .and_then(Option::as_ref)
                .filter(|warp| !warp.is_zero())
            {
                entry["sourcePlaneWarp"] = json!(warp);
            }
            entry
        })
        .collect::<Vec<_>>();
    let mut layout = json!({
        "schemaVersion": 1,
        "projection": "spherical",
        "tiles": layout_tiles,
        "renderBlendMode": req.seam_blend_mode,
        "report": report
    });
    reorient_layout_to_grid_center(&mut layout).map_err(|message| {
        Error::Registration(format!("could not center spherical orientation: {message}"))
    })?;
    if nominal_only_layout {
        layout["report"]["geometryModel"] = json!("nominal-fov-grid");
    }
    let bounds = [
        layout["yawMinRad"].as_f64().unwrap(),
        layout["yawMaxRad"].as_f64().unwrap(),
        layout["pitchMinRad"].as_f64().unwrap(),
        layout["pitchMaxRad"].as_f64().unwrap(),
    ];
    if bounds[1] - bounds[0] < 1e-5 || bounds[3] - bounds[2] < 1e-5 {
        return Err(Error::Registration("degenerate spherical coverage".into()).into());
    }
    Ok(layout)
}

pub fn align_json_with_checkpoint(
    input: &str,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<Value, SphericalFailure> {
    let request: Request = serde_json::from_str(input).map_err(|e| SphericalFailure {
        code: "INVALID_REQUEST",
        message: format!("invalid spherical request JSON: {e}"),
        diagnostics: None,
    })?;
    align(request, checkpoint)
}

pub fn align_json_detailed(input: &str) -> std::result::Result<Value, SphericalFailure> {
    align_json_with_checkpoint(input, &mut |_| Ok(()))
}

pub fn align_json(input: &str) -> std::result::Result<Value, (&'static str, String)> {
    align_json_detailed(input).map_err(|failure| (failure.code, failure.message))
}

/// Explicitly upgrade the one reviewed v2 snapshot format emitted by the reliable
/// probe DLL. This migration only adds solver identity/provenance metadata.
pub fn upgrade_approved_v2_correspondence_snapshot_json(
    request_json: &str,
    snapshot_json: &str,
    producer_dll_path: &str,
) -> std::result::Result<Value, SphericalFailure> {
    let failure = |message: String| SphericalFailure {
        code: "INVALID_DIAGNOSTIC_SNAPSHOT",
        message,
        diagnostics: None,
    };
    let req: Request = serde_json::from_str(request_json)
        .map_err(|error| failure(format!("invalid source request: {error}")))?;
    let mut snapshot: Value = serde_json::from_str(snapshot_json)
        .map_err(|error| failure(format!("invalid correspondence snapshot: {error}")))?;
    if snapshot["schemaVersion"].as_u64() != Some(1)
        || snapshot["pixelBundleAlgorithmVersion"].as_u64() != Some(2)
        || snapshot["optimizer"].as_str() != Some("anchored-component-joint-symmetric-pixel-huber")
        || snapshot["coordinateFrame"].as_str() != Some("pre-layout-center-reorientation")
        || !snapshot["solverParameters"].is_null()
        || !snapshot["solverParameterProvenance"].is_null()
    {
        return Err(failure(
            "only an un-upgraded v2 diagnostic snapshot with the approved solver identity can be migrated".into(),
        ));
    }
    let original_hash = snapshot["snapshotHash"]
        .as_str()
        .ok_or_else(|| failure("original snapshot hash is missing".into()))?
        .to_owned();
    snapshot.as_object_mut().unwrap().remove("snapshotHash");
    let computed_original_hash =
        crate::fingerprint::sha256_bytes(&serde_json::to_vec(&snapshot).unwrap_or_default());
    if original_hash != computed_original_hash {
        return Err(failure("original snapshot integrity hash mismatch".into()));
    }
    if snapshot["grid"]["rows"].as_u64() != Some(req.rows as u64)
        || snapshot["grid"]["columns"].as_u64() != Some(req.columns as u64)
        || snapshot["intrinsics"]["fx"].as_f64() != Some(req.fx)
        || snapshot["intrinsics"]["fy"].as_f64() != Some(req.fy)
        || snapshot["intrinsics"]["cx"].as_f64() != Some(req.cx)
        || snapshot["intrinsics"]["cy"].as_f64() != Some(req.cy)
        || snapshot["intrinsics"]["sourceWidth"].as_u64() != Some(req.source_width as u64)
        || snapshot["intrinsics"]["sourceHeight"].as_u64() != Some(req.source_height as u64)
        || snapshot["matchingParameters"]["featureType"].as_str() != Some(req.feature_type.as_str())
        || snapshot["matchingParameters"]["matcherType"].as_str() != Some(req.matcher_type.as_str())
        || snapshot["matchingParameters"]["registrationMegapixels"].as_f64()
            != Some(req.registration_megapixels)
        || snapshot["matchingParameters"]["neighborMode"].as_str()
            != Some(req.neighbor_mode.as_str())
    {
        return Err(failure(
            "source request does not match snapshot grid, intrinsics, or matching parameters"
                .into(),
        ));
    }
    let source_hashes = snapshot["sourceIdentities"]
        .as_array()
        .ok_or_else(|| failure("snapshot source identities are missing".into()))?;
    if source_hashes.len() != req.tiles.len() {
        return Err(failure("snapshot source identity count mismatch".into()));
    }
    let indices = source_hashes
        .iter()
        .map(|entry| entry["tileIndex"].as_u64().map(|index| index as usize))
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| failure("snapshot source tile index is invalid".into()))?;
    let unique = indices
        .iter()
        .copied()
        .collect::<std::collections::HashSet<_>>();
    if unique.len() != req.tiles.len() || (0..req.tiles.len()).any(|index| !unique.contains(&index))
    {
        return Err(failure(
            "snapshot source indices must cover every tile exactly once".into(),
        ));
    }
    for entry in source_hashes {
        let index = entry["tileIndex"].as_u64().unwrap() as usize;
        let tile = req
            .tiles
            .iter()
            .find(|tile| tile.row * req.columns + tile.column == index)
            .ok_or_else(|| failure(format!("source tile {index} is absent from request")))?;
        let expected = entry["sha256"]
            .as_str()
            .ok_or_else(|| failure(format!("source hash {index} is missing")))?;
        let actual = crate::fingerprint::sha256_file(std::path::Path::new(&tile.path))
            .map_err(|error| failure(format!("cannot hash source tile {index}: {error}")))?;
        if expected != actual {
            return Err(failure(format!(
                "source tile {index} changed since alignment"
            )));
        }
    }
    let producer_hash = crate::fingerprint::sha256_file(std::path::Path::new(producer_dll_path))
        .map_err(|error| failure(format!("cannot hash approved producer DLL: {error}")))?;
    if producer_hash != APPROVED_V2_SNAPSHOT_PRODUCER_SHA256 {
        return Err(failure(format!(
            "producer DLL SHA256 {producer_hash} is not the approved v2 snapshot producer"
        )));
    }
    let original_points = snapshot["acceptedVisualEdges"].clone();
    let original_poses = snapshot["warmStartPoses"].clone();
    let parameters = current_pixel_solver_parameters();
    snapshot["pixelBundleAlgorithmVersion"] = json!(PIXEL_BUNDLE_ALGORITHM_VERSION);
    snapshot["localTextureWarp"] = json!(true);
    snapshot["sourcePlaneWarps"] = Value::Null;
    snapshot["solverParameters"] = parameters.clone();
    snapshot["solverParameterProvenance"] = json!({
        "migrationVersion":1,
        "sourcePixelBundleAlgorithmVersion":2,
        "producerDllSha256":producer_hash,
        "originalSnapshotHash":original_hash,
        "verifiedSourceTileCount":req.tiles.len(),
        "parameterBasis":"fixed constants compiled into the approved producer DLL; no correspondence or pose values modified",
        "pcgIterationPolicy":"clamp(4 * scalarDimension, 64, 4096)",
        "parameters":parameters
    });
    if snapshot["acceptedVisualEdges"] != original_points
        || snapshot["warmStartPoses"] != original_poses
    {
        return Err(failure(
            "metadata upgrade unexpectedly changed points or poses".into(),
        ));
    }
    let upgraded_hash =
        crate::fingerprint::sha256_bytes(&serde_json::to_vec(&snapshot).unwrap_or_default());
    snapshot["snapshotHash"] = json!(upgraded_hash);
    Ok(json!({
        "diagnosticOnly":true,
        "productionLayoutEmitted":false,
        "migration":"approved-v2-solver-metadata-only",
        "originalSnapshotHash":original_hash,
        "upgradedSnapshotHash":upgraded_hash,
        "producerDllSha256":producer_hash,
        "verifiedSourceTileCount":req.tiles.len(),
        "pointsAndPosesPreserved":true,
        "diagnosticCorrespondenceSnapshot":snapshot
    }))
}

/// Refine an opt-in failed-alignment snapshot without rerunning feature extraction.
/// This diagnostic API never emits a production layout and rechecks source hashes,
/// snapshot integrity, solver identity, and the ordinary reprojection gates.
pub fn refine_correspondence_snapshot_json(
    request_json: &str,
    snapshot_json: &str,
) -> std::result::Result<Value, SphericalFailure> {
    refine_correspondence_snapshot_excluding_json(request_json, snapshot_json, &[])
}

/// Diagnostic bounded auto-prune mode, using the same sequential warm-start
/// joint leave-one-out helper as production. This never emits a layout.
pub fn refine_correspondence_snapshot_auto_prune_json(
    request_json: &str,
    snapshot_json: &str,
) -> std::result::Result<Value, SphericalFailure> {
    refine_correspondence_snapshot_excluding_internal(request_json, snapshot_json, &[], true, false)
}

/// Explicit fit-only diagnostic path for a previously verified correspondence
/// snapshot. It returns a preview layout and never emits a production layout.
pub fn fit_texture_warp_from_snapshot_json(
    request_json: &str,
    snapshot_json: &str,
) -> std::result::Result<Value, SphericalFailure> {
    refine_correspondence_snapshot_excluding_internal(request_json, snapshot_json, &[], false, true)
}

/// Diagnostic leave-one-out variant; excluded edges remain in the snapshot as
/// held-out evidence, and the function never emits a production layout.
pub fn refine_correspondence_snapshot_excluding_json(
    request_json: &str,
    snapshot_json: &str,
    excluded_edges: &[(usize, usize)],
) -> std::result::Result<Value, SphericalFailure> {
    refine_correspondence_snapshot_excluding_internal(
        request_json,
        snapshot_json,
        excluded_edges,
        false,
        false,
    )
}

fn refine_correspondence_snapshot_excluding_internal(
    request_json: &str,
    snapshot_json: &str,
    excluded_edges: &[(usize, usize)],
    auto_prune: bool,
    fit_texture_warp: bool,
) -> std::result::Result<Value, SphericalFailure> {
    let failure = |message: String| SphericalFailure {
        code: "INVALID_DIAGNOSTIC_SNAPSHOT",
        message,
        diagnostics: None,
    };
    let req: Request = serde_json::from_str(request_json)
        .map_err(|error| failure(format!("invalid source request: {error}")))?;
    if fit_texture_warp && !req.local_texture_warp {
        return Err(failure(
            "--fit-texture-warp requires localTextureWarp=true in the request".into(),
        ));
    }
    let mut snapshot: Value = serde_json::from_str(snapshot_json)
        .map_err(|error| failure(format!("invalid correspondence snapshot: {error}")))?;
    let snapshot_algorithm = snapshot["pixelBundleAlgorithmVersion"].as_u64();
    let reviewed_legacy_fit_snapshot = fit_texture_warp
        && snapshot_algorithm == Some(2)
        && snapshot["solverParameterProvenance"]["producerDllSha256"].as_str()
            == Some(APPROVED_V2_SNAPSHOT_PRODUCER_SHA256)
        && snapshot["solverParameterProvenance"]["migrationVersion"].as_u64() == Some(1)
        && snapshot["solverParameterProvenance"]["originalSnapshotHash"]
            .as_str()
            .is_some_and(|hash| hash.len() == 64 && hash.chars().all(|c| c.is_ascii_hexdigit()))
        && snapshot["solverParameterProvenance"]["verifiedSourceTileCount"].as_u64()
            == Some(req.tiles.len() as u64)
        && snapshot["solverParameters"] == current_pixel_solver_parameters();
    let reviewed_prior_warp_fit_snapshot = fit_texture_warp
        && matches!(snapshot_algorithm, Some(3 | 4))
        && snapshot["localTextureWarp"].as_bool() == Some(true)
        && snapshot["solverParameters"] == current_pixel_solver_parameters();
    let legacy_fit_compatible = reviewed_legacy_fit_snapshot || reviewed_prior_warp_fit_snapshot;
    if snapshot["schemaVersion"].as_u64() != Some(1)
        || (snapshot_algorithm != Some(PIXEL_BUNDLE_ALGORITHM_VERSION as u64)
            && !legacy_fit_compatible)
    {
        return Err(failure(
            "snapshot schema or pixel bundle algorithm version mismatch".into(),
        ));
    }
    let expected_solver_parameters = current_pixel_solver_parameters();
    if snapshot["optimizer"].as_str() != Some("anchored-component-joint-symmetric-pixel-huber")
        || snapshot["coordinateFrame"].as_str() != Some("pre-layout-center-reorientation")
        || snapshot["solverParameters"] != expected_solver_parameters
        || (!legacy_fit_compatible
            && snapshot["localTextureWarp"].as_bool() != Some(req.local_texture_warp))
    {
        return Err(failure(
            "snapshot optimizer parameters do not match this solver".into(),
        ));
    }
    let recorded_hash = snapshot["snapshotHash"]
        .as_str()
        .ok_or_else(|| failure("snapshot hash is missing".into()))?
        .to_owned();
    snapshot.as_object_mut().unwrap().remove("snapshotHash");
    let actual_hash =
        crate::fingerprint::sha256_bytes(&serde_json::to_vec(&snapshot).unwrap_or_default());
    if actual_hash != recorded_hash {
        return Err(failure("snapshot integrity hash mismatch".into()));
    }
    snapshot["snapshotHash"] = json!(recorded_hash);
    if snapshot["grid"]["rows"].as_u64() != Some(req.rows as u64)
        || snapshot["grid"]["columns"].as_u64() != Some(req.columns as u64)
        || snapshot["intrinsics"]["fx"].as_f64() != Some(req.fx)
        || snapshot["intrinsics"]["fy"].as_f64() != Some(req.fy)
        || snapshot["intrinsics"]["cx"].as_f64() != Some(req.cx)
        || snapshot["intrinsics"]["cy"].as_f64() != Some(req.cy)
        || snapshot["intrinsics"]["sourceWidth"].as_u64() != Some(req.source_width as u64)
        || snapshot["intrinsics"]["sourceHeight"].as_u64() != Some(req.source_height as u64)
        || snapshot["matchingParameters"]["featureType"].as_str() != Some(req.feature_type.as_str())
        || snapshot["matchingParameters"]["matcherType"].as_str() != Some(req.matcher_type.as_str())
        || snapshot["matchingParameters"]["registrationMegapixels"].as_f64()
            != Some(req.registration_megapixels)
        || snapshot["matchingParameters"]["neighborMode"].as_str()
            != Some(req.neighbor_mode.as_str())
        || (!legacy_fit_compatible
            && snapshot["localTextureWarp"].as_bool() != Some(req.local_texture_warp))
    {
        return Err(failure(
            "snapshot grid or intrinsics do not match the source request".into(),
        ));
    }
    let hashes = snapshot["sourceIdentities"]
        .as_array()
        .ok_or_else(|| failure("snapshot source identity list is missing".into()))?;
    if hashes.len() != req.tiles.len() {
        return Err(failure(
            "snapshot source identity count does not match request".into(),
        ));
    }
    let source_indices = hashes
        .iter()
        .map(|entry| entry["tileIndex"].as_u64().map(|index| index as usize))
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| failure("snapshot source identity has an invalid tile index".into()))?;
    let unique_source_indices = source_indices
        .iter()
        .copied()
        .collect::<std::collections::HashSet<_>>();
    if unique_source_indices.len() != req.tiles.len()
        || (0..req.tiles.len()).any(|index| !unique_source_indices.contains(&index))
    {
        return Err(failure(
            "snapshot source identities must cover every tile index exactly once".into(),
        ));
    }
    for hash_entry in hashes {
        let grid_index = hash_entry["tileIndex"].as_u64().unwrap_or(u64::MAX) as usize;
        let Some(tile) = req
            .tiles
            .iter()
            .find(|tile| tile.row * req.columns + tile.column == grid_index)
        else {
            return Err(failure(format!(
                "source tile {grid_index} is missing from request"
            )));
        };
        let expected = hash_entry["sha256"].as_str().ok_or_else(|| {
            failure(format!(
                "snapshot source hash for tile {grid_index} is missing"
            ))
        })?;
        let actual = crate::fingerprint::sha256_file(std::path::Path::new(&tile.path))
            .map_err(|error| failure(format!("cannot hash source tile {grid_index}: {error}")))?;
        if actual != expected {
            return Err(failure(format!(
                "source tile {grid_index} changed since alignment"
            )));
        }
    }
    let poses: Vec<Mat> = serde_json::from_value(snapshot["warmStartPoses"].clone())
        .map_err(|error| failure(format!("invalid warm-start poses: {error}")))?;
    if poses.len() != req.rows.saturating_mul(req.columns)
        || poses.iter().any(|pose| normalize_rotation(*pose).is_none())
    {
        return Err(failure(
            "warm-start pose count or rotation is invalid".into(),
        ));
    }
    let cache_edges = snapshot["acceptedVisualEdges"]
        .as_array()
        .ok_or_else(|| failure("accepted visual edge list is missing".into()))?;
    let mut constraints = Vec::with_capacity(cache_edges.len());
    let mut edges = Vec::with_capacity(cache_edges.len());
    let mut cached_reliability_scales = std::collections::HashMap::new();
    let mut reconstructed_legacy_reliability = false;
    for item in cache_edges {
        let from = item["from"].as_u64().unwrap_or(u64::MAX) as usize;
        let to = item["to"].as_u64().unwrap_or(u64::MAX) as usize;
        let rotation: Mat = serde_json::from_value(item["rotation"].clone())
            .map_err(|error| failure(format!("invalid cached edge rotation: {error}")))?;
        let points: Vec<[f64; 4]> = serde_json::from_value(item["points"].clone())
            .map_err(|error| failure(format!("invalid cached edge points: {error}")))?;
        if from >= poses.len()
            || to >= poses.len()
            || from == to
            || points.is_empty()
            || points.iter().flatten().any(|value| !value.is_finite())
        {
            return Err(failure(
                "cached visual edge contains invalid endpoints or points".into(),
            ));
        }
        let matches = item["matches"].as_u64().unwrap_or(0) as usize;
        let inliers = item["inliers"].as_u64().unwrap_or(0) as usize;
        let inlier_ratio = item["inlierRatio"].as_f64().unwrap_or(0.0);
        let homography_residual = item["homographyResidualPx"]
            .as_f64()
            .unwrap_or(f64::INFINITY);
        constraints.push(Constraint {
            from,
            to,
            rotation,
            weight: item["weight"].as_f64().unwrap_or(1.0),
        });
        if item.get("reliabilityWeightScale").is_none() {
            if !legacy_fit_compatible {
                return Err(failure(
                    "snapshot edge is missing its reliability weight; regenerate the alignment snapshot".into(),
                ));
            }
            reconstructed_legacy_reliability = true;
        } else {
            let Some(scale) = item["reliabilityWeightScale"].as_f64() else {
                return Err(failure(
                    "cached edge reliability weight is not numeric".into(),
                ));
            };
            if !scale.is_finite() || !(0.0..=1.0).contains(&scale) || scale <= 0.0 {
                return Err(failure(
                    "cached edge reliability weight is outside the valid range".into(),
                ));
            }
            cached_reliability_scales.insert((from, to), scale);
        }
        let attempt = crate::pipeline::SphericalMatchAttempt {
            from_features: 0,
            to_features: 0,
            matches,
            inliers,
            inlier_ratio,
            reason: 0,
            contrast_threshold: 0.0,
            clahe: false,
        };
        edges.push(crate::pipeline::SphericalMatchEdge {
            from,
            to,
            from_features: 0,
            to_features: 0,
            matches,
            inliers,
            inlier_ratio,
            homography_residual,
            reason: 0,
            points,
            initial: attempt,
            retry: None,
            clahe_retry: None,
            used_retry: false,
            used_clahe_retry: false,
        });
    }
    if constraints.is_empty() {
        return Err(failure("snapshot contains no accepted visual edges".into()));
    }
    let mut excluded_set = snapshot["diagnosticExcludedEdges"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    Some((
                        item["from"].as_u64()? as usize,
                        item["to"].as_u64()? as usize,
                    ))
                })
                .collect::<std::collections::HashSet<_>>()
        })
        .unwrap_or_default();
    let newly_requested = excluded_edges
        .iter()
        .copied()
        .collect::<std::collections::HashSet<_>>();
    if newly_requested.len() != excluded_edges.len()
        || newly_requested
            .iter()
            .any(|edge| excluded_set.contains(edge))
    {
        return Err(failure("duplicate excluded edge was specified".into()));
    }
    if newly_requested.iter().any(|edge| {
        !constraints
            .iter()
            .any(|constraint| (constraint.from, constraint.to) == *edge)
    }) {
        return Err(failure(
            "one or more excluded edges are absent from snapshot".into(),
        ));
    }
    let snapshot_excluded = constraints
        .iter()
        .filter(|edge| excluded_set.contains(&(edge.from, edge.to)))
        .map(|edge| (edge.from, edge.to))
        .collect::<std::collections::HashSet<_>>();
    if snapshot_excluded.len() != excluded_set.len() {
        return Err(failure(
            "snapshot lists an absent previously excluded edge".into(),
        ));
    }
    let original_component_count = visual_components(poses.len(), &constraints).len();
    let all_constraints = constraints.clone();
    constraints.retain(|edge| !excluded_set.contains(&(edge.from, edge.to)));
    if constraints.is_empty()
        || visual_components(poses.len(), &constraints).len() != original_component_count
    {
        return Err(failure(
            "existing diagnostic exclusions split a visual component".into(),
        ));
    }
    // The snapshot stores the final constraint weight (including spatial and
    // loop reliability). Reconstruct the same relative scales during replay.
    let mut reliability_scales = reliability_scales_from_constraints(&constraints);
    reliability_scales.extend(cached_reliability_scales);
    let mut refined_poses = poses;
    let mut checkpoint = |_: &str| -> std::result::Result<(), String> { Ok(()) };
    let outcome = prune_visual_edges_with_joint_leave_one_out_weighted(
        &mut refined_poses,
        &mut constraints,
        &edges,
        &req,
        &mut checkpoint,
        if auto_prune {
            None
        } else {
            Some(&newly_requested)
        },
        &reliability_scales,
    )
    .map_err(|error| failure(format!("offline joint leave-one-out failed: {error}")))?;
    let accepted_new = outcome
        .rejected_edges
        .iter()
        .filter_map(|item| {
            Some((
                item["from"].as_u64()? as usize,
                item["to"].as_u64()? as usize,
            ))
        })
        .collect::<Vec<_>>();
    excluded_set.extend(accepted_new.iter().copied());
    let held_out_constraints = edges
        .iter()
        .filter(|edge| excluded_set.contains(&(edge.from, edge.to)))
        .map(|edge| Constraint {
            from: edge.from,
            to: edge.to,
            rotation: all_constraints
                .iter()
                .find(|active| active.from == edge.from && active.to == edge.to)
                .map(|active| active.rotation)
                .unwrap_or([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]),
            weight: 1.0,
        })
        .collect::<Vec<_>>();
    let held_out_edges = edges
        .iter()
        .filter(|edge| excluded_set.contains(&(edge.from, edge.to)))
        .cloned()
        .collect::<Vec<_>>();
    let (rms, p95, maximum, count, edge_rms, complete) =
        global_reprojection_metrics(&refined_poses, &constraints, &edges, &req);
    let raw_edge_rms = edge_rms.clone();
    let (diagnostic_warps, warp_tile_diagnostics, warp_summary, corrected_metrics) =
        if fit_texture_warp {
            let mut checkpoint = |_: &str| -> std::result::Result<(), String> { Ok(()) };
            let (warps, tile_diagnostics, mut summary) = fit_source_plane_warps(
                &refined_poses,
                &constraints,
                &edges,
                &req,
                &mut checkpoint,
                crate::texture_warp::SOURCE_WARP_SMOOTHNESS_WEIGHT,
            )
            .map_err(|error| failure(format!("offline source-plane warp fit failed: {error}")))?;
            let metrics = global_reprojection_metrics_with_warps(
                &refined_poses,
                &constraints,
                &edges,
                &req,
                Some(&warps),
            );
            let held_out_corrected = global_reprojection_metrics_with_warps(
                &refined_poses,
                &held_out_constraints,
                &held_out_edges,
                &req,
                Some(&warps),
            );
            let mut smoothness_comparison = Vec::new();
            for weight in [0.25, 0.025, 0.0025] {
                let (candidate_warps, candidate_tiles, candidate_summary) = fit_source_plane_warps(
                    &refined_poses,
                    &constraints,
                    &edges,
                    &req,
                    &mut checkpoint,
                    weight,
                )
                .map_err(|error| {
                    failure(format!(
                        "offline smoothness sensitivity fit failed: {error}"
                    ))
                })?;
                let candidate = global_reprojection_metrics_with_warps(
                    &refined_poses,
                    &constraints,
                    &edges,
                    &req,
                    Some(&candidate_warps),
                );
                let candidate_worst = candidate
                    .4
                    .iter()
                    .map(|edge| edge.2)
                    .fold(0.0_f64, f64::max);
                let candidate_held_out = global_reprojection_metrics_with_warps(
                    &refined_poses,
                    &held_out_constraints,
                    &held_out_edges,
                    &req,
                    Some(&candidate_warps),
                );
                let candidate_held_out_worst = candidate_held_out
                    .4
                    .iter()
                    .map(|edge| edge.2)
                    .fold(0.0_f64, f64::max);
                smoothness_comparison.push(json!({
                    "neighborSmoothnessWeight":weight,
                    "symmetricRmsPx":candidate.0,
                    "symmetricP95Px":candidate.1,
                    "symmetricMaxPx":candidate.2,
                    "worstEdgeRmsPx":candidate_worst,
                    "correspondenceCount":candidate.3,
                    "completeEvidence":candidate.5,
                    "strict12pxGatePassed":candidate.5 && candidate.0 <= 12.0 && candidate_worst <= 12.0,
                    "heldOutSymmetricRmsPx":candidate_held_out.0,
                    "heldOutWorstEdgeRmsPx":candidate_held_out_worst,
                    "heldOutCompleteEvidence":candidate_held_out.5,
                    "acceptedRounds":candidate_summary["acceptedRounds"],
                    "converged":candidate_summary["converged"],
                    "terminationReason":candidate_summary["terminationReason"],
                    "supportedTileCount":candidate_tiles.iter().filter(|tile|tile["supported"] == true && tile["componentAnchor"] != true).count(),
                    "appliedTileCount":candidate_warps.iter().filter(|warp|warp.as_ref().is_some_and(|warp|!warp.is_zero())).count()
                }));
            }
            summary["smoothnessSensitivitySameTrainingSet"] = json!(smoothness_comparison);
            summary["heldOutCorrectedSourcePlaneSymmetricRmsPx"] = json!(held_out_corrected.0);
            summary["heldOutCorrectedSourcePlaneSymmetricWorstEdgeRmsPx"] =
                json!(held_out_corrected
                    .4
                    .iter()
                    .map(|edge| edge.2)
                    .fold(0.0_f64, f64::max));
            summary["heldOutCorrectedEvidenceComplete"] = json!(held_out_corrected.5);
            (Some(warps), tile_diagnostics, summary, Some(metrics))
        } else {
            (None, Vec::new(), Value::Null, None)
        };
    let (reported_rms, reported_p95, reported_max, reported_count, mut edge_rms, complete) =
        corrected_metrics
            .clone()
            .unwrap_or((rms, p95, maximum, count, edge_rms.clone(), complete));
    edge_rms.sort_by(|a, b| b.2.total_cmp(&a.2));
    let worst_edge_rms = edge_rms.first().map(|edge| edge.2).unwrap_or(f64::INFINITY);
    let gate_passed = complete && rms <= 12.0 && worst_edge_rms <= 12.0;
    let worst_edge_diagnostics = edge_rms
        .iter()
        .take(10)
        .map(|(from, to, corrected_rms, point_count)| {
            let constraint = constraints
                .iter()
                .find(|constraint| constraint.from == *from && constraint.to == *to);
            let edge = edges
                .iter()
                .find(|edge| edge.from == *from && edge.to == *to);
            let raw_rms = raw_edge_rms
                .iter()
                .find(|entry| entry.0 == *from && entry.1 == *to)
                .map(|entry| entry.2);
            let adjacent = constraints
                .iter()
                .filter(|other| {
                    (other.from == *from
                        || other.to == *from
                        || other.from == *to
                        || other.to == *to)
                        && (other.from != *from || other.to != *to)
                })
                .take(12)
                .map(|other| {
                    let quality = edges
                        .iter()
                        .find(|candidate| candidate.from == other.from && candidate.to == other.to);
                    json!({
                        "from":other.from,"to":other.to,"constraintWeight":other.weight,
                        "inliers":quality.map(|edge|edge.inliers),
                        "inlierRatio":quality.map(|edge|edge.inlier_ratio),
                        "homographyResidualPx":quality.map(|edge|edge.homography_residual)
                    })
                })
                .collect::<Vec<_>>();
            json!({
                "from":from,"to":to,"rawRotationOnlyRmsPx":raw_rms,
                "correctedSourcePlaneSymmetricRmsPx":corrected_rms,
                "correspondenceCount":point_count,
                "constraintWeight":constraint.map(|value|value.weight),
                "matches":edge.map(|value|value.matches),"inliers":edge.map(|value|value.inliers),
                "inlierRatio":edge.map(|value|value.inlier_ratio),
                "homographyResidualPx":edge.map(|value|value.homography_residual),
                "incidentNeighborEvidence":adjacent
            })
        })
        .collect::<Vec<_>>();
    let held_out_diagnostics = held_out_constraints
        .iter()
        .filter_map(|constraint| {
            let edge = held_out_edges
                .iter()
                .find(|edge| edge.from == constraint.from && edge.to == constraint.to)?;
            let (_, _, _, _, metrics, evidence) = global_reprojection_metrics(
                &refined_poses,
                std::slice::from_ref(constraint),
                std::slice::from_ref(edge),
                &req,
            );
            Some(json!({
                "from":constraint.from,
                "to":constraint.to,
                "heldOutRmsPx":metrics.first().map(|entry|entry.2),
                "correspondenceCount":edge.points.len(),
                "completeEvidence":evidence
            }))
        })
        .collect::<Vec<_>>();
    snapshot["warmStartPoses"] = json!(refined_poses);
    if let Some(warps) = &diagnostic_warps {
        snapshot["pixelBundleAlgorithmVersion"] = json!(PIXEL_BUNDLE_ALGORITHM_VERSION);
        snapshot["localTextureWarp"] = json!(true);
        snapshot["sourcePlaneWarps"] = json!(warps);
        snapshot["diagnosticWarpFitProvenance"] = json!({
            "diagnosticOnly":true,
            "sourceSnapshotHash":recorded_hash,
            "sourcePixelBundleAlgorithmVersion":snapshot_algorithm,
                "sourceProducerDllSha256":if reviewed_legacy_fit_snapshot { Some(APPROVED_V2_SNAPSHOT_PRODUCER_SHA256) } else { None },
            "verifiedSourceTileCount":req.tiles.len(),
            "sourceCorrespondencesPreserved":true,
            "algorithm":"bounded-coarse-to-fine-3-5-9-source-plane-warp-v1",
            "productionLayoutEmitted":false
        });
    }
    let mut sorted_excluded = excluded_set.iter().copied().collect::<Vec<_>>();
    sorted_excluded.sort_unstable();
    snapshot["diagnosticExcludedEdges"] = json!(sorted_excluded
        .iter()
        .map(|(from, to)| json!({"from":from,"to":to}))
        .collect::<Vec<_>>());
    let mut attempted_edges = snapshot["diagnosticAttemptedEdges"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| {
            Some((
                item["from"].as_u64()? as usize,
                item["to"].as_u64()? as usize,
            ))
        })
        .collect::<std::collections::HashSet<_>>();
    attempted_edges.extend(newly_requested.iter().copied());
    let mut sorted_attempted = attempted_edges.into_iter().collect::<Vec<_>>();
    sorted_attempted.sort_unstable();
    snapshot["diagnosticAttemptedEdges"] = json!(sorted_attempted
        .iter()
        .map(|(from, to)| json!({"from":from,"to":to}))
        .collect::<Vec<_>>());
    snapshot.as_object_mut().unwrap().remove("snapshotHash");
    let next_hash =
        crate::fingerprint::sha256_bytes(&serde_json::to_vec(&snapshot).unwrap_or_default());
    snapshot["snapshotHash"] = json!(next_hash);
    let mut result = json!({
        "diagnosticOnly":true,
        "productionLayoutEmitted":false,
        "qualityGatePassed":!fit_texture_warp && gate_passed && excluded_set.is_empty() && newly_requested.is_empty(),
        "retainedGraphGatePassed":gate_passed,
        "globalReprojectionRmsPx":reported_rms,
        "globalReprojectionP95Px":reported_p95,
        "globalReprojectionMaxPx":reported_max,
        "worstEdgeReprojectionRmsPx":worst_edge_rms,
        "correspondenceCount":reported_count,
        "completeCorrespondenceEvidence":complete,
        "refinement":outcome.final_refinement,
        "leaveOneOutEvaluations":outcome.evaluations,
        "rejectedEdges":outcome.rejected_edges,
        "pruneBudgetExceeded":outcome.budget_exceeded,
        "warmStartPoses":refined_poses,
        "worstEdges":worst_edge_diagnostics,
        "excludedEdgesHeldOut":held_out_diagnostics,
        "diagnosticCorrespondenceSnapshot":snapshot
    });
    result["reliabilityScaleCompatibility"] = json!(if reconstructed_legacy_reliability {
        "reconstructed_from_legacy_constraint_weights"
    } else {
        "restored_from_snapshot"
    });
    if let (Some(warps), Some(metrics)) = (diagnostic_warps, corrected_metrics) {
        let tiles = req
            .tiles
            .iter()
            .map(|tile| {
                let index = tile.row * req.columns + tile.column;
                let mut value = json!({
                    "row":tile.row,"column":tile.column,"path":tile.path,
                    "width":req.source_width,"height":req.source_height,
                    "fx":req.fx,"fy":req.fy,"cx":req.cx,"cy":req.cy,
                    "cameraToWorld":refined_poses[index],"positionSource":"diagnostic-warm-start",
                    "forceGrid":false
                });
                if let Some(warp) = warps
                    .get(index)
                    .and_then(Option::as_ref)
                    .filter(|warp| !warp.is_zero())
                {
                    value["sourcePlaneWarp"] = json!(warp);
                }
                value
            })
            .collect::<Vec<_>>();
        let _bounds = spherical_bounds_with_warps(&refined_poses, &req, Some(&warps))
            .ok_or_else(|| failure("could not compute warped diagnostic panorama bounds".into()))?;
        let mut layout = json!({
            "schemaVersion":1,"projection":"spherical","tiles":tiles,
            "renderBlendMode":req.seam_blend_mode,
            "report":{
                "diagnosticOnly":true,"productionLayoutEmitted":false,
                "rawRotationOnlyGlobalReprojectionRmsPx":rms,
                "correctedSourcePlaneSymmetricReprojectionRmsPx":metrics.0,
                "correctedSourcePlaneSymmetricReprojectionP95Px":metrics.1,
                "correctedSourcePlaneSymmetricReprojectionMaxPx":metrics.2,
                "correspondenceCount":metrics.3,"completeCorrespondenceEvidence":metrics.5,
                "worstEdgeReprojectionRmsPx":worst_edge_rms,
                "sourcePlaneWarpRefinement":warp_summary,
                "sourcePlaneWarpTiles":warp_tile_diagnostics,
                "qualityStatus":"needs-visual-review",
                "qualityWarnings":["diagnostic source-plane warp preview; not a production-qualified layout"]
            }
        });
        reorient_layout_to_grid_center(&mut layout)
            .map_err(|message| failure(format!("cannot center diagnostic layout: {message}")))?;
        result["diagnosticLayout"] = layout;
        result["sourcePlaneWarpRefinement"] = warp_summary;
        result["sourcePlaneWarpTiles"] = json!(warp_tile_diagnostics);
        result["correctedSourcePlaneSymmetricReprojectionRmsPx"] = json!(metrics.0);
        result["correctedSourcePlaneSymmetricReprojectionP95Px"] = json!(metrics.1);
        result["correctedSourcePlaneSymmetricReprojectionMaxPx"] = json!(metrics.2);
        result["rawRotationOnlyGlobalReprojectionRmsPx"] = json!(rms);
        result["correctedSourcePlaneCorrespondenceCount"] = json!(metrics.3);
        result["correctedSourcePlaneCompleteEvidence"] = json!(metrics.5);
        result["retainedGraphGatePassed"] =
            json!(metrics.5 && metrics.0 <= 12.0 && worst_edge_rms <= 12.0);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn warp_step_comparison_handles_grid_level_changes_without_losing_field() {
        let coarse = crate::texture_warp::SourcePlaneWarp {
            columns: 3,
            rows: 3,
            offsets: vec![[2.0, -1.0]; 9],
        };
        let fine = crate::texture_warp::SourcePlaneWarp {
            columns: 9,
            rows: 9,
            offsets: vec![[2.0, -1.0]; 81],
        };
        assert!(source_warp_max_step(Some(&coarse), &fine, 101, 101) < 1e-9);
        assert!(source_warp_max_step(Some(&fine), &coarse, 101, 101) < 1e-9);
    }

    #[test]
    fn production_warp_caller_keeps_accepted_coarse_field_when_fine_level_is_rejected() {
        let samples = [8.0, 50.0, 92.0]
            .into_iter()
            .flat_map(|center_y| {
                [8.0, 50.0, 92.0].into_iter().flat_map(move |center_x| {
                    (-2..=2).flat_map(move |dy| {
                        (-2..=2).map(move |dx| crate::texture_warp::SourceWarpSample {
                            x: center_x + f64::from(dx),
                            y: center_y + f64::from(dy),
                            dx: 4.0,
                            dy: -2.0,
                            weight: 1.0,
                        })
                    })
                })
            })
            .collect::<Vec<_>>();
        let (fitted, levels) =
            crate::texture_warp::fit_source_plane_warp_multilevel(101, 101, &samples, false, 0.025);
        assert!(fitted.is_some(), "coarse fit should be retained");
        assert!(levels[0].accepted);
        assert!(
            levels.iter().skip(1).any(|level| !level.accepted),
            "fixture must exercise a rejected finer level"
        );
        let selected = final_accepted_warp_level(&levels);
        assert!(selected.supported && selected.accepted);
        assert_eq!(selected.support_count, samples.len());
    }

    fn snapshot_validation_fixture() -> (String, Value) {
        let request = json!({
            "rows":1,"columns":2,
            "tiles":[{"row":0,"column":0,"path":"missing-0.jpg"},{"row":0,"column":1,"path":"missing-1.jpg"}],
            "fx":100.0,"fy":100.0,"cx":50.0,"cy":50.0,
            "sourceWidth":100,"sourceHeight":100
        });
        let snapshot = json!({
            "schemaVersion":1,
            "pixelBundleAlgorithmVersion":PIXEL_BUNDLE_ALGORITHM_VERSION,
            "optimizer":"anchored-component-joint-symmetric-pixel-huber",
            "coordinateFrame":"pre-layout-center-reorientation",
            "localTextureWarp":true,
            "solverParameters":current_pixel_solver_parameters(),
            "grid":{"rows":1,"columns":2},
            "intrinsics":{"fx":100.0,"fy":100.0,"cx":50.0,"cy":50.0,"sourceWidth":100,"sourceHeight":100},
            "matchingParameters":{"featureType":"sift","matcherType":"bf","registrationMegapixels":2.0,"neighborMode":"four"},
            "warmStartPoses":[],
            "sourceIdentities":[{"tileIndex":0,"sha256":"a".repeat(64)},{"tileIndex":1,"sha256":"b".repeat(64)}],
            "acceptedVisualEdges":[]
        });
        (request.to_string(), snapshot)
    }

    fn rehash_snapshot(snapshot: &mut Value) {
        snapshot.as_object_mut().unwrap().remove("snapshotHash");
        let hash = crate::fingerprint::sha256_bytes(&serde_json::to_vec(snapshot).unwrap());
        snapshot["snapshotHash"] = json!(hash);
    }

    #[test]
    fn diagnostic_snapshot_rejects_missing_or_mismatched_identity_metadata() {
        let (request, base) = snapshot_validation_fixture();
        for field in ["solverParameters", "optimizer", "coordinateFrame"] {
            let mut snapshot = base.clone();
            snapshot.as_object_mut().unwrap().remove(field);
            rehash_snapshot(&mut snapshot);
            let error =
                refine_correspondence_snapshot_json(&request, &snapshot.to_string()).unwrap_err();
            assert_eq!(error.code, "INVALID_DIAGNOSTIC_SNAPSHOT");
        }

        let mut duplicate_sources = base.clone();
        duplicate_sources["sourceIdentities"][1]["tileIndex"] = json!(0);
        rehash_snapshot(&mut duplicate_sources);
        assert!(
            refine_correspondence_snapshot_json(&request, &duplicate_sources.to_string())
                .unwrap_err()
                .message
                .contains("exactly once")
        );

        let mut mismatched_matching = base;
        mismatched_matching["matchingParameters"]["neighborMode"] = json!("eight");
        rehash_snapshot(&mut mismatched_matching);
        assert!(
            refine_correspondence_snapshot_json(&request, &mismatched_matching.to_string())
                .unwrap_err()
                .message
                .contains("grid or intrinsics")
        );
    }

    #[test]
    fn diagnostic_exclusions_are_cumulative_rehashed_and_never_pass_production_gate() {
        let root = std::env::temp_dir().join(format!(
            "lumia-spherical-snapshot-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let paths = (0..3)
            .map(|index| {
                let path = root.join(format!("{index}.jpg"));
                std::fs::write(&path, [index as u8, 17, 42]).unwrap();
                path
            })
            .collect::<Vec<_>>();
        let request = json!({
            "rows":1,"columns":3,
            "tiles":paths.iter().enumerate().map(|(index,path)| json!({"row":0,"column":index,"path":path})).collect::<Vec<_>>(),
            "fx":200.0,"fy":200.0,"cx":100.0,"cy":100.0,
            "sourceWidth":200,"sourceHeight":200,
            "featureType":"sift","matcherType":"bf","registrationMegapixels":2.0,"neighborMode":"four"
        });
        let req: Request = serde_json::from_value(request.clone()).unwrap();
        let poses = [ry(0.0), ry(0.02), ry(0.04)];
        let corners = [
            (25.0, 25.0),
            (175.0, 25.0),
            (25.0, 175.0),
            (175.0, 175.0),
            (80.0, 70.0),
            (120.0, 130.0),
            (60.0, 145.0),
            (145.0, 60.0),
        ];
        let mut accepted_edges = Vec::new();
        for (from, to) in [(0usize, 1usize), (1, 2), (0, 2)] {
            let points = corners
                .iter()
                .map(|&(x, y)| {
                    let world = mul_vec(poses[from], camera_ray(x, y, &req));
                    let target = mul_vec(transpose(poses[to]), world);
                    let (tx, ty) = project_camera_ray(target, &req).unwrap();
                    [x, y, tx, ty]
                })
                .collect::<Vec<_>>();
            accepted_edges.push(json!({
                "from":from,"to":to,"rotation":mul(transpose(poses[from]), poses[to]),"weight":1.0,
                "reliabilityWeightScale":if from == 0 && to == 1 { 0.0171875 } else { 1.0 },
                "points":points,"matches":corners.len(),"inliers":corners.len(),"inlierRatio":1.0,"homographyResidualPx":0.5
            }));
        }
        let source_identities = paths
            .iter()
            .enumerate()
            .map(|(index, path)| {
                json!({
                    "tileIndex":index,"sha256":crate::fingerprint::sha256_file(path).unwrap()
                })
            })
            .collect::<Vec<_>>();
        let mut snapshot = json!({
            "schemaVersion":1,
            "pixelBundleAlgorithmVersion":PIXEL_BUNDLE_ALGORITHM_VERSION,
            "optimizer":"anchored-component-joint-symmetric-pixel-huber",
            "coordinateFrame":"pre-layout-center-reorientation",
            "localTextureWarp":true,
            "solverParameters":current_pixel_solver_parameters(),
            "grid":{"rows":1,"columns":3},
            "intrinsics":{"fx":200.0,"fy":200.0,"cx":100.0,"cy":100.0,"sourceWidth":200,"sourceHeight":200},
            "matchingParameters":{"featureType":"sift","matcherType":"bf","registrationMegapixels":2.0,"neighborMode":"four"},
            "warmStartPoses":poses,
            "sourceIdentities":source_identities,
            "acceptedVisualEdges":accepted_edges
        });
        rehash_snapshot(&mut snapshot);
        let request_json = request.to_string();
        let initial = refine_correspondence_snapshot_excluding_json(
            &request_json,
            &snapshot.to_string(),
            &[(0, 2)],
        )
        .unwrap();
        assert_eq!(
            initial["diagnosticCorrespondenceSnapshot"]["acceptedVisualEdges"][0]
                ["reliabilityWeightScale"],
            0.0171875
        );
        let mut invalid_scale_snapshot = snapshot.clone();
        invalid_scale_snapshot["acceptedVisualEdges"][0]["reliabilityWeightScale"] = json!(0.0);
        rehash_snapshot(&mut invalid_scale_snapshot);
        assert!(refine_correspondence_snapshot_json(
            &request_json,
            &invalid_scale_snapshot.to_string()
        )
        .unwrap_err()
        .message
        .contains("reliability weight"));
        let mut missing_scale_snapshot = snapshot.clone();
        missing_scale_snapshot["acceptedVisualEdges"][0]
            .as_object_mut()
            .unwrap()
            .remove("reliabilityWeightScale");
        rehash_snapshot(&mut missing_scale_snapshot);
        assert!(refine_correspondence_snapshot_json(
            &request_json,
            &missing_scale_snapshot.to_string()
        )
        .unwrap_err()
        .message
        .contains("missing its reliability weight"));
        assert_eq!(initial["retainedGraphGatePassed"], true);
        assert_eq!(initial["qualityGatePassed"], false);
        assert_eq!(initial["productionLayoutEmitted"], false);
        assert!(initial.get("layout").is_none());

        let warp_preview =
            fit_texture_warp_from_snapshot_json(&request_json, &snapshot.to_string()).unwrap();
        assert_eq!(warp_preview["diagnosticOnly"], true);
        assert_eq!(warp_preview["qualityGatePassed"], false);
        assert_eq!(warp_preview["productionLayoutEmitted"], false);
        assert!(warp_preview.get("layout").is_none());
        assert_eq!(
            warp_preview["diagnosticLayout"]["report"]["qualityStatus"],
            "needs-visual-review"
        );
        assert!(warp_preview["diagnosticLayout"]["tiles"]
            .as_array()
            .unwrap()
            .iter()
            .all(|tile| tile.get("sourcePlaneWarp").is_none()));
        assert_eq!(warp_preview["sourcePlaneWarpTiles"][1]["supported"], false);
        assert_eq!(warp_preview["sourcePlaneWarpTiles"][2]["supported"], false);

        let mut reviewed_v2 = snapshot.clone();
        let original_v2_hash = reviewed_v2["snapshotHash"].as_str().unwrap().to_owned();
        reviewed_v2["pixelBundleAlgorithmVersion"] = json!(2);
        reviewed_v2
            .as_object_mut()
            .unwrap()
            .remove("localTextureWarp");
        reviewed_v2["solverParameterProvenance"] = json!({
            "migrationVersion":1,
            "producerDllSha256":APPROVED_V2_SNAPSHOT_PRODUCER_SHA256,
            "originalSnapshotHash":original_v2_hash,
            "verifiedSourceTileCount":3
        });
        rehash_snapshot(&mut reviewed_v2);
        let migrated_preview =
            fit_texture_warp_from_snapshot_json(&request_json, &reviewed_v2.to_string()).unwrap();
        assert_eq!(migrated_preview["productionLayoutEmitted"], false);
        assert_eq!(
            migrated_preview["diagnosticCorrespondenceSnapshot"]["pixelBundleAlgorithmVersion"],
            PIXEL_BUNDLE_ALGORITHM_VERSION
        );
        assert_eq!(
            migrated_preview["diagnosticCorrespondenceSnapshot"]["diagnosticWarpFitProvenance"]
                ["sourcePixelBundleAlgorithmVersion"],
            2
        );
        assert_eq!(
            migrated_preview["diagnosticCorrespondenceSnapshot"]["diagnosticWarpFitProvenance"]
                ["sourceProducerDllSha256"],
            APPROVED_V2_SNAPSHOT_PRODUCER_SHA256
        );

        let mut cumulative = initial["diagnosticCorrespondenceSnapshot"].clone();
        cumulative["diagnosticExcludedEdges"] = json!([{"from":0,"to":1}]);
        rehash_snapshot(&mut cumulative);
        let prior_hash = cumulative["snapshotHash"].as_str().unwrap().to_owned();
        let next = refine_correspondence_snapshot_excluding_json(
            &request_json,
            &cumulative.to_string(),
            &[(1, 2)],
        )
        .unwrap();
        assert_eq!(next["qualityGatePassed"], false);
        assert_eq!(next["productionLayoutEmitted"], false);
        let next_snapshot = &next["diagnosticCorrespondenceSnapshot"];
        assert_eq!(
            next_snapshot["diagnosticExcludedEdges"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(next_snapshot["diagnosticExcludedEdges"][0]["from"], 0);
        assert_eq!(next_snapshot["diagnosticExcludedEdges"][0]["to"], 1);
        assert_eq!(
            next_snapshot["diagnosticAttemptedEdges"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_ne!(
            next_snapshot["snapshotHash"].as_str(),
            Some(prior_hash.as_str())
        );
        let mut verified = next_snapshot.clone();
        let recorded_hash = verified["snapshotHash"].as_str().unwrap().to_owned();
        verified.as_object_mut().unwrap().remove("snapshotHash");
        assert_eq!(
            crate::fingerprint::sha256_bytes(&serde_json::to_vec(&verified).unwrap()),
            recorded_hash
        );

        assert!(refine_correspondence_snapshot_excluding_json(
            &request_json,
            &snapshot.to_string(),
            &[(0, 2), (0, 2)],
        )
        .unwrap_err()
        .message
        .contains("duplicate"));
        assert!(refine_correspondence_snapshot_excluding_json(
            &request_json,
            &snapshot.to_string(),
            &[(0, 3)],
        )
        .unwrap_err()
        .message
        .contains("absent"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn dense_cholesky_reports_true_residual_for_ill_conditioned_spd_system() {
        let diagonal = [1e-8, 1.0, 1e8];
        let matrix = vec![
            diagonal[0],
            0.0,
            0.0,
            0.0,
            diagonal[1],
            0.0,
            0.0,
            0.0,
            diagonal[2],
        ];
        let expected = [1.25, -2.0, 0.75];
        let rhs = diagonal
            .iter()
            .zip(expected)
            .map(|(a, b)| a * b)
            .collect::<Vec<_>>();
        let mut checkpoint = |_: &str| -> std::result::Result<(), String> { Ok(()) };
        let solved = dense_cholesky_solve(&matrix, &rhs, 3, &mut checkpoint).unwrap();
        let delta = solved.delta.expect("SPD solve must return a direction");
        assert!(solved.relative_residual.is_finite());
        assert!(
            solved.relative_residual <= 1e-3,
            "true residual {}",
            solved.relative_residual
        );
        assert!(delta
            .iter()
            .zip(expected)
            .all(|(actual, expected)| (actual - expected).abs() < 1e-5));
    }

    #[test]
    fn cycle_pruning_requires_alternate_visual_path_and_respects_budget() {
        let identity_rotation = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
        let triangle = vec![
            Constraint {
                from: 0,
                to: 1,
                rotation: identity_rotation,
                weight: 1.0,
            },
            Constraint {
                from: 1,
                to: 2,
                rotation: identity_rotation,
                weight: 1.0,
            },
            Constraint {
                from: 0,
                to: 2,
                rotation: identity_rotation,
                weight: 1.0,
            },
        ];
        assert!(visual_edge_has_alternate_path(3, &triangle, 2));
        assert!(visual_edge_has_alternate_path(3, &triangle, 0));
        let bridge = triangle[..2].to_vec();
        assert!(!visual_edge_has_alternate_path(3, &bridge, 0));
        assert_eq!(cycle_prune_budget(19), 1);
        assert_eq!(cycle_prune_budget(20), 1);
        assert_eq!(cycle_prune_budget(40), 2);
    }

    #[test]
    fn ray_rms_separates_outliers_from_a_low_median_residual() {
        let mut req = grid_request(1, 2);
        req.fx = 400.0;
        req.fy = 400.0;
        req.cx = 200.0;
        req.cy = 150.0;
        let mut points = (0..20)
            .map(|i| {
                let x = 40.0 + (i % 5) as f64 * 70.0;
                let y = 30.0 + (i / 5) as f64 * 70.0;
                [x, y, x, y]
            })
            .collect::<Vec<_>>();
        points[18][2] += 40.0;
        points[19][2] -= 40.0;
        let (_, median_residual, rms_residual) =
            fit_ray_rotation(&points, req.fx, req.fy, req.cx, req.cy).unwrap();
        assert!(median_residual < 3.0, "median={median_residual}");
        assert!(rms_residual > 3.0, "RMS={rms_residual}");
    }

    #[test]
    fn cycle_pruning_drops_weak_inconsistent_loop_edge_and_keeps_strong_path() {
        let mut req = grid_request(1, 3);
        req.fx = 400.0;
        req.fy = 400.0;
        req.cx = 200.0;
        req.cy = 150.0;
        req.source_width = 400;
        req.source_height = 300;
        let truth = [ry(0.0), ry(0.1), ry(0.2)];
        let corners = [
            (30.0, 30.0),
            (360.0, 30.0),
            (30.0, 270.0),
            (360.0, 270.0),
            (100.0, 80.0),
            (300.0, 220.0),
            (190.0, 40.0),
            (210.0, 260.0),
        ];
        let make_edge = |from: usize, to: usize| {
            let points = corners
                .iter()
                .map(|&(x, y)| {
                    let world_ray = mul_vec(truth[from], camera_ray(x, y, &req));
                    let target_ray = mul_vec(transpose(truth[to]), world_ray);
                    let (tx, ty) = project_camera_ray(target_ray, &req).unwrap();
                    [x, y, tx, ty]
                })
                .collect();
            let mut edge = reprojection_fixture_edge(points);
            edge.from = from;
            edge.to = to;
            edge
        };
        let mut bad_edge = make_edge(0, 2);
        for point in &mut bad_edge.points {
            point[2] += 60.0;
        }
        bad_edge.inliers = 3;
        bad_edge.inlier_ratio = 0.30;
        bad_edge.matches = 10;
        bad_edge.homography_residual = 6.0;
        let mut matches = vec![make_edge(0, 1), make_edge(1, 2), bad_edge];
        for edge in &mut matches[..2] {
            edge.inliers = 8;
            edge.inlier_ratio = 0.95;
        }
        let mut constraints = vec![
            Constraint {
                from: 0,
                to: 1,
                rotation: mul(transpose(truth[0]), truth[1]),
                weight: 10.0,
            },
            Constraint {
                from: 1,
                to: 2,
                rotation: mul(transpose(truth[1]), truth[2]),
                weight: 10.0,
            },
            Constraint {
                from: 0,
                to: 2,
                rotation: ry(0.50),
                weight: 0.01,
            },
        ];
        let mut poses = solve_orientations(3, &constraints).unwrap();
        let mut checkpoint = |_: &str| -> std::result::Result<(), String> { Ok(()) };
        let (rejected, budget_exceeded, final_refinement) = prune_cycle_inconsistent_visual_edges(
            &mut poses,
            &mut constraints,
            &[],
            &matches,
            &req,
            &mut checkpoint,
        )
        .unwrap();
        assert!(!budget_exceeded);
        assert_eq!(
            rejected.len(),
            1,
            "expected only the weak bad loop edge to be rejected"
        );
        assert_eq!(rejected[0]["from"], 0);
        assert_eq!(rejected[0]["to"], 2);
        assert!(
            rejected[0]["retainedGlobalRmsAfterPx"].as_f64().unwrap()
                < rejected[0]["retainedGlobalRmsBeforePx"].as_f64().unwrap()
        );
        assert!(
            rejected[0]["retainedWorstEdgeRmsAfterPx"].as_f64().unwrap()
                <= rejected[0]["retainedWorstEdgeRmsBeforePx"]
                    .as_f64()
                    .unwrap()
                    + 1e-3
        );
        assert_eq!(constraints.len(), 2);
        assert!(constraints
            .iter()
            .any(|edge| edge.from == 0 && edge.to == 1));
        assert!(constraints
            .iter()
            .any(|edge| edge.from == 1 && edge.to == 2));
        assert_eq!(visual_components(3, &constraints).len(), 1);
        assert!(final_refinement.is_some());

        // If removing the candidate cannot improve retained evidence, restore
        // both the original poses and the full visual constraint set.
        let mut rollback_constraints = vec![
            Constraint {
                from: 0,
                to: 1,
                rotation: mul(transpose(truth[0]), truth[1]),
                weight: 10.0,
            },
            Constraint {
                from: 1,
                to: 2,
                rotation: mul(transpose(truth[1]), truth[2]),
                weight: 10.0,
            },
            Constraint {
                from: 0,
                to: 2,
                rotation: ry(0.50),
                weight: 0.01,
            },
        ];
        let original_constraints = rollback_constraints.clone();
        let mut rollback_poses = truth.to_vec();
        let original_poses = rollback_poses.clone();
        let (rollback_rejected, rollback_budget_exceeded, rollback_refinement) =
            prune_cycle_inconsistent_visual_edges(
                &mut rollback_poses,
                &mut rollback_constraints,
                &[],
                &matches,
                &req,
                &mut checkpoint,
            )
            .unwrap();
        assert!(!rollback_budget_exceeded);
        assert!(rollback_rejected.is_empty());
        assert_eq!(rollback_constraints.len(), original_constraints.len());
        assert_eq!(rollback_poses, original_poses);

        // High-confidence edges are never rejected, even when the supplied
        // initial poses make their pixel residual exceed the candidate gate.
        assert!(rollback_refinement.is_none());
        let mut high_confidence_edges = [make_edge(0, 1), make_edge(1, 2), make_edge(0, 2)];
        for edge in &mut high_confidence_edges {
            edge.inliers = 64;
            edge.inlier_ratio = 0.95;
        }
        let mut high_confidence_constraints = original_constraints;
        let mut displaced_poses = vec![ry(0.0), ry(0.2), ry(0.4)];
        let displaced_original = displaced_poses.clone();
        let (high_confidence_rejected, high_confidence_budget, high_confidence_refinement) =
            prune_cycle_inconsistent_visual_edges(
                &mut displaced_poses,
                &mut high_confidence_constraints,
                &[],
                &high_confidence_edges,
                &req,
                &mut checkpoint,
            )
            .unwrap();
        assert!(high_confidence_rejected.is_empty());
        assert!(!high_confidence_budget);
        assert!(high_confidence_refinement.is_none());
        assert_eq!(high_confidence_constraints.len(), 3);
        assert_eq!(displaced_poses, displaced_original);
    }
    fn grid_request(rows: usize, columns: usize) -> Request {
        Request {
            rows,
            columns,
            tiles: (0..rows)
                .flat_map(|row| {
                    (0..columns).map(move |column| InputTile {
                        row,
                        column,
                        path: "fixture.png".into(),
                        force_grid: false,
                    })
                })
                .collect(),
            fx: 100.,
            fy: 100.,
            cx: 50.,
            cy: 50.,
            source_width: 100,
            source_height: 100,
            output_dir: String::new(),
            placement_mode: String::new(),
            allow_nominal_grid_fallback: false,
            auto_grid_overlap: false,
            refine_grid_neighbors: false,
            seam_blend_mode: default_seam_blend_mode(),
            grid_horizontal_overlap: None,
            grid_vertical_overlap: None,
            neighbor_mode: default_neighbor_mode(),
            workers: default_workers(),
            parallel_matching: default_parallel_matching(),
            registration_megapixels: default_registration_megapixels(),
            feature_type: default_feature_type(),
            matcher_type: default_matcher_type(),
            include_diagnostic_correspondences: false,
            local_texture_warp: true,
        }
    }

    #[test]
    fn correspondence_coverage_distinguishes_broad_and_concentrated_support() {
        let req = grid_request(1, 2);
        let broad = (0..4)
            .flat_map(|row| {
                (0..4).map(move |column| {
                    let x = 10.0 + column as f64 * 20.0;
                    let y = 10.0 + row as f64 * 20.0;
                    [x, y, x, y]
                })
            })
            .collect::<Vec<_>>();
        let concentrated = vec![[20.0, 20.0, 20.0, 20.0]; 16];
        let (_, _, broad_score) = correspondence_coverage(&broad, &req);
        let (source_cells, target_cells, concentrated_score) =
            correspondence_coverage(&concentrated, &req);
        assert_eq!((source_cells, target_cells), (1, 1));
        assert_eq!(broad_score, 1.0);
        assert!(concentrated_score < broad_score);
        assert!(
            concentrated_score > 0.0,
            "valid narrow evidence stays usable"
        );
    }

    #[test]
    fn neighbor_loop_uses_noncommuting_rotations_and_scales_only_weak_conflict() {
        let mut req = grid_request(2, 2);
        req.fx = 400.0;
        req.fy = 420.0;
        let truth = [
            ID,
            mul(rx(0.08), ry(0.12)),
            mul(rz(-0.1), rx(0.15)),
            mul(ry(0.2), rz(0.05)),
        ];
        let pairs = [(0, 1), (1, 3), (2, 3), (0, 2)];
        let mut constraints = pairs
            .iter()
            .map(|&(from, to)| Constraint {
                from,
                to,
                rotation: mul(transpose(truth[from]), truth[to]),
                weight: if (from, to) == (0, 1) { 0.1 } else { 10.0 },
            })
            .collect::<Vec<_>>();
        let (positive_residuals, positive_scales, _) =
            weight_neighbor_loop_conflicts(2, 2, &mut constraints, &req);
        assert!(positive_residuals[&(0, 1)] < 12.0);
        assert!(positive_scales.is_empty());

        constraints[0].rotation = mul(constraints[0].rotation, ry(0.2));
        let (negative_residuals, negative_scales, ambiguous) =
            weight_neighbor_loop_conflicts(2, 2, &mut constraints, &req);
        assert!(negative_residuals[&(0, 1)] > 12.0);
        assert_eq!(negative_scales.get(&(0, 1)), Some(&0.05));
        assert!(ambiguous.is_empty());
        assert!(constraints[0].weight < 0.1);
        assert!(constraints[1..].iter().all(|edge| edge.weight == 10.0));

        let mut tied_constraints = constraints
            .iter()
            .cloned()
            .map(|mut edge| {
                edge.weight = 1.0;
                edge
            })
            .collect::<Vec<_>>();
        let (_, tied_scales, tied_ambiguity) =
            weight_neighbor_loop_conflicts(2, 2, &mut tied_constraints, &req);
        assert!(tied_scales.is_empty());
        assert_eq!(tied_ambiguity.len(), 4);
        assert!(tied_constraints.iter().all(|edge| edge.weight == 1.0));
    }

    #[test]
    fn accepts_large_grids_without_arbitrary_axis_or_photo_caps() {
        assert!(validate(&grid_request(16, 24)).is_ok());
        assert!(validate(&grid_request(32, 32)).is_ok());
        assert!(validate(&grid_request(33, 33)).is_ok());
        assert!(validate(&grid_request(129, 2)).is_ok());
    }

    #[test]
    fn spherical_grid_dimension_overflow_is_rejected() {
        let mut request = grid_request(1, 2);
        request.rows = usize::MAX;
        request.columns = 2;
        assert!(validate(&request).is_err());
    }

    #[test]
    fn neighbor_mode_and_worker_fields_are_optional_but_bounded() {
        let request = serde_json::json!({
            "rows": 1, "columns": 2,
            "tiles": [{"row":0,"column":0,"path":"a"},{"row":0,"column":1,"path":"b"}],
            "fx":100.0,"fy":100.0,"cx":50.0,"cy":50.0,"sourceWidth":100,"sourceHeight":100
        });
        let legacy: Request = serde_json::from_value(request.clone()).unwrap();
        assert_eq!(legacy.neighbor_mode, "four");
        assert_eq!(legacy.workers, 1);
        let eight: Request = serde_json::from_value(serde_json::json!({
            "rows":1,"columns":2,"tiles":request["tiles"],"fx":100,"fy":100,"cx":50,"cy":50,
            "sourceWidth":100,"sourceHeight":100,"neighborMode":"eight","workers":2
        }))
        .unwrap();
        assert!(validate(&eight).is_ok());
        let invalid: Request = serde_json::from_value(serde_json::json!({
            "rows":1,"columns":2,"tiles":request["tiles"],"fx":100,"fy":100,"cx":50,"cy":50,
            "sourceWidth":100,"sourceHeight":100,"neighborMode":"six","workers":2
        }))
        .unwrap();
        assert!(validate(&invalid).is_err());
        let too_many: Request = serde_json::from_value(serde_json::json!({
            "rows":1,"columns":2,"tiles":request["tiles"],"fx":100,"fy":100,"cx":50,"cy":50,
            "sourceWidth":100,"sourceHeight":100,"neighborMode":"four","workers":33
        }))
        .unwrap();
        assert!(validate(&too_many).is_err());
    }

    #[test]
    fn spherical_grid_accepts_axis_lengths_above_128() {
        assert!(validate(&grid_request(1, 129)).is_ok());
    }

    #[test]
    fn eight_neighbor_edge_counts_and_order_are_stable() {
        use crate::pipeline::spherical_neighbor_pairs;
        let four = spherical_neighbor_pairs(16, 24, false);
        let eight = spherical_neighbor_pairs(16, 24, true);
        assert_eq!(four.len(), 728);
        assert_eq!(eight.len(), 1418);
        assert_eq!(&eight[..4], &[(0, 1), (0, 24), (0, 25), (1, 2)]);
        assert_eq!(spherical_neighbor_pairs(1, 3, true), vec![(0, 1), (1, 2)]);
        assert!(eight.iter().all(|(from, to)| {
            let fr = from / 24;
            let fc = from % 24;
            let tr = to / 24;
            let tc = to % 24;
            tr >= fr && tc.abs_diff(fc) <= 1 && tr.abs_diff(fr) <= 1 && (tr != fr || tc != fc)
        }));
        let mut unique = std::collections::HashSet::new();
        let mut degree = vec![0usize; 16 * 24];
        for &(from, to) in &eight {
            assert!(unique.insert((from, to)));
            degree[from] += 1;
            degree[to] += 1;
        }
        assert!(degree.into_iter().all(|count| count <= 8));
    }

    #[test]
    fn force_grid_removes_incident_visual_edges_but_retains_the_cell() {
        let mut forced = vec![false; 9];
        forced[4] = true;
        assert!(touches_forced_grid_cell(1, 4, &forced));
        assert!(touches_forced_grid_cell(4, 7, &forced));
        assert!(!touches_forced_grid_cell(1, 2, &forced));
        assert!(!touches_forced_grid_cell(1, 2, &[false; 9]));
        let request = serde_json::json!({"rows":1,"columns":2,"tiles":[
            {"row":0,"column":0,"path":"a.png"},
            {"row":0,"column":1,"path":"b.png","forceGrid":true}],
            "fx":100.0,"fy":100.0,"cx":50.0,"cy":50.0,"sourceWidth":100,"sourceHeight":100});
        let parsed: Request = serde_json::from_value(request).unwrap();
        assert!(parsed.tiles[1].force_grid);
        assert!(!parsed.tiles[0].force_grid);
        assert_eq!(parsed.tiles.len(), 2);
    }

    fn rx(a: f64) -> Mat {
        let (s, c) = a.sin_cos();
        [1., 0., 0., 0., c, -s, 0., s, c]
    }
    fn rz(a: f64) -> Mat {
        let (s, c) = a.sin_cos();
        [c, -s, 0., s, c, 0., 0., 0., 1.]
    }
    fn ry(a: f64) -> Mat {
        let (s, c) = a.sin_cos();
        [c, 0., s, 0., 1., 0., -s, 0., c]
    }
    fn homography(from_world: Mat, to_world: Mat, k: Mat) -> Mat {
        let ki = inverse(k).unwrap();
        let flip_y = [1., 0., 0., 0., -1., 0., 0., 0., 1.];
        mul(
            mul(
                k,
                mul(flip_y, mul(transpose(to_world), mul(from_world, flip_y))),
            ),
            ki,
        )
    }
    fn project_pixel(camera_to_world: Mat, direction: [f64; 3], k: Mat) -> Option<(f64, f64)> {
        let p = mul_vec(transpose(camera_to_world), direction);
        (p[2] > 0.).then(|| (k[0] * p[0] / p[2] + k[2], -k[4] * p[1] / p[2] + k[5]))
    }
    fn mul_vec(a: Mat, v: [f64; 3]) -> [f64; 3] {
        [
            a[0] * v[0] + a[1] * v[1] + a[2] * v[2],
            a[3] * v[0] + a[4] * v[1] + a[5] * v[2],
            a[6] * v[0] + a[7] * v[1] + a[8] * v[2],
        ]
    }
    #[test]
    fn rotation_graph_recovers_camera_to_world_and_closes_loop() {
        let truth = [ID, rz(0.2), mul(rz(0.2), rz(-0.12)), rz(0.08)];
        let edges = [(0, 1), (1, 2), (2, 3), (0, 3), (0, 2)].map(|(from, to)| Constraint {
            from,
            to,
            rotation: mul(transpose(truth[from]), truth[to]),
            weight: 1.,
        });
        let got = solve_orientations(4, &edges).unwrap();
        for i in 0..4 {
            let e = log_rotation(mul(transpose(truth[i]), got[i]));
            assert!(e.iter().map(|v| v * v).sum::<f64>().sqrt() < 1e-6);
        }
    }

    #[test]
    fn center_reorientation_is_deterministic_and_preserves_relative_rotations() {
        for (rows, columns, expected_index) in [(3, 3, 4), (4, 4, 5), (2, 5, 2)] {
            let original = (0..rows * columns)
                .map(|index| mul(ry(index as f64 * 0.013), rz(index as f64 * -0.007)))
                .collect::<Vec<_>>();
            let mut first = original.clone();
            let mut second = original.clone();
            let (index, rotation) =
                reorient_poses_to_grid_center(&mut first, rows, columns).unwrap();
            let (second_index, second_rotation) =
                reorient_poses_to_grid_center(&mut second, rows, columns).unwrap();
            assert_eq!(index, expected_index);
            assert_eq!(second_index, expected_index);
            assert_eq!(first, second);
            assert_eq!(rotation, second_rotation);
            assert!(
                log_rotation(first[index])
                    .iter()
                    .map(|value| value * value)
                    .sum::<f64>()
                    .sqrt()
                    < 1e-7
            );
            assert!(first.iter().all(|pose| {
                let orthogonality = mul(transpose(*pose), *pose);
                orthogonality
                    .iter()
                    .zip(ID)
                    .all(|(actual, expected)| (actual - expected).abs() < 1e-8)
                    && (determinant(*pose) - 1.).abs() < 1e-8
            }));
            for i in 0..first.len() {
                for j in 0..first.len() {
                    let before = mul(transpose(original[i]), original[j]);
                    let after = mul(transpose(first[i]), first[j]);
                    assert!(
                        log_rotation(mul(transpose(before), after))
                            .iter()
                            .map(|value| value * value)
                            .sum::<f64>()
                            .sqrt()
                            < 1e-7
                    );
                }
            }
        }
    }

    #[test]
    fn center_reorientation_preserves_matched_ray_residuals_and_bounds_corners() {
        let mut req = grid_request(3, 3);
        req.fx = 200.;
        req.fy = 200.;
        req.cx = 49.5;
        req.cy = 49.5;
        req.source_width = 100;
        req.source_height = 100;
        let mut poses = (0..9)
            .map(|index| {
                mul(
                    ry(std::f64::consts::PI - 0.02 + (index % 3) as f64 * 0.08),
                    rz((index / 3) as f64 * 0.025),
                )
            })
            .collect::<Vec<_>>();
        let mut points = Vec::new();
        for &(x, y) in &[
            (32., 32.),
            (42., 32.),
            (52., 32.),
            (62., 32.),
            (32., 42.),
            (42., 42.),
            (52., 42.),
            (62., 42.),
        ] {
            let source_ray = [(x - req.cx) / req.fx, -(y - req.cy) / req.fy, 1.];
            let world = mul_vec(poses[0], source_ray);
            let target_ray = mul_vec(transpose(poses[1]), world);
            let target = project_camera_ray(target_ray, &req).unwrap();
            points.push([x, y, target.0, target.1]);
        }
        let edge = crate::pipeline::SphericalMatchEdge {
            from: 0,
            to: 1,
            from_features: 8,
            to_features: 8,
            matches: 8,
            inliers: 8,
            inlier_ratio: 1.,
            homography_residual: 0.,
            reason: 0,
            points,
            initial: crate::pipeline::SphericalMatchAttempt {
                from_features: 8,
                to_features: 8,
                matches: 8,
                inliers: 8,
                inlier_ratio: 1.,
                reason: 0,
                contrast_threshold: 0.004,
                clahe: false,
            },
            retry: None,
            clahe_retry: None,
            used_retry: false,
            used_clahe_retry: false,
        };
        let constraint = Constraint {
            from: 0,
            to: 1,
            rotation: mul(transpose(poses[0]), poses[1]),
            weight: 1.,
        };
        let before = global_reprojection_metrics(
            &poses,
            std::slice::from_ref(&constraint),
            std::slice::from_ref(&edge),
            &req,
        );
        let (index, _) = reorient_poses_to_grid_center(&mut poses, 3, 3).unwrap();
        let after = global_reprojection_metrics(
            &poses,
            std::slice::from_ref(&constraint),
            std::slice::from_ref(&edge),
            &req,
        );
        assert_eq!(index, 4);
        assert!((before.0 - after.0).abs() < 1e-9);
        assert!((before.1 - after.1).abs() < 1e-9);
        assert!((before.2 - after.2).abs() < 1e-9);
        assert_eq!(before.3, after.3);
        assert_eq!(before.4.len(), after.4.len());
        assert!((before.4[0].2 - after.4[0].2).abs() < 1e-9);

        let bounds = spherical_bounds(&poses, &req).unwrap();
        let center_yaw = spherical_point(ray_to_world(poses[index], req.cx, req.cy, &req)).0;
        assert!(bounds[1] - bounds[0] < 1.);
        for pose in &poses {
            for (x, y) in [(0., 0.), (99., 0.), (0., 99.), (99., 99.)] {
                let (yaw, pitch) = spherical_point(ray_to_world(*pose, x, y, &req));
                let yaw = center_yaw
                    + (yaw - center_yaw + std::f64::consts::PI)
                        .rem_euclid(2. * std::f64::consts::PI)
                    - std::f64::consts::PI;
                assert!(yaw >= bounds[0] - 1e-12 && yaw <= bounds[1] + 1e-12);
                assert!(pitch >= bounds[2] - 1e-12 && pitch <= bounds[3] + 1e-12);
            }
        }
    }

    #[test]
    fn saved_layout_reorientation_updates_poses_bounds_and_reference_report() {
        let req = grid_request(3, 3);
        let truth = (0..9)
            .map(|index| mul(ry(index as f64 * 0.04), rz(index as f64 * -0.01)))
            .collect::<Vec<_>>();
        let mut layout = json!({
            "schemaVersion":1,
            "projection":"spherical",
            "tiles":req.tiles.iter().enumerate().map(|(index, tile)| json!({
                "row":tile.row,"column":tile.column,"path":tile.path,
                "width":req.source_width,"height":req.source_height,
                "fx":req.fx,"fy":req.fy,"cx":req.cx,"cy":req.cy,
                "cameraToWorld":truth[index]
            })).collect::<Vec<_>>(),
            "report":{"visualTileCount":9,"edgeDiagnostics":[]}
        });
        reorient_layout_to_grid_center(&mut layout).unwrap();
        assert_eq!(layout["report"]["orientationReference"]["row"], 1);
        assert_eq!(layout["report"]["orientationReference"]["column"], 1);
        assert_eq!(layout["report"]["orientationReference"]["index"], 4);
        assert_eq!(layout["report"]["visualConnectivityReference"]["row"], 0);
        assert_eq!(layout["report"]["visualConnectivityReference"]["column"], 0);
        assert_eq!(layout["report"]["visualConnectivityReference"]["index"], 0);
        assert_eq!(layout["report"]["visualTileCount"], 9);
        let center: Mat =
            serde_json::from_value(layout["tiles"][4]["cameraToWorld"].clone()).unwrap();
        assert!(
            log_rotation(center)
                .iter()
                .map(|value| value * value)
                .sum::<f64>()
                .sqrt()
                < 1e-7
        );
        let mut poses = Vec::new();
        for tile in layout["tiles"].as_array().unwrap() {
            let pose: Mat = serde_json::from_value(tile["cameraToWorld"].clone()).unwrap();
            poses.push(pose);
        }
        let bounds = spherical_bounds(&poses, &req).unwrap();
        assert_eq!(layout["yawMinRad"].as_f64().unwrap(), bounds[0]);
        assert_eq!(layout["yawMaxRad"].as_f64().unwrap(), bounds[1]);
        assert_eq!(layout["pitchMinRad"].as_f64().unwrap(), bounds[2]);
        assert_eq!(layout["pitchMaxRad"].as_f64().unwrap(), bounds[3]);

        let mut missing_report = layout.clone();
        missing_report["report"] = Value::Null;
        let original = missing_report.clone();
        assert!(reorient_layout_to_grid_center(&mut missing_report).is_err());
        assert_eq!(missing_report, original);

        let mut overflowing_coordinate = layout.clone();
        overflowing_coordinate["tiles"][0]["row"] = json!(u64::MAX);
        let original = overflowing_coordinate.clone();
        assert!(reorient_layout_to_grid_center(&mut overflowing_coordinate).is_err());
        assert_eq!(overflowing_coordinate, original);

        let mut invalid_intrinsics = layout.clone();
        invalid_intrinsics["tiles"][0]["fx"] = json!(0.0);
        let original = invalid_intrinsics.clone();
        assert!(reorient_layout_to_grid_center(&mut invalid_intrinsics).is_err());
        assert_eq!(invalid_intrinsics, original);
    }
    #[test]
    fn disconnected_or_degenerate_graph_fails_closed() {
        assert!(solve_orientations(2, &[]).is_none());
        assert!(calibrated_rotation([0.; 9], 100., 100., 50., 50.).is_none());
    }
    #[test]
    fn placement_mode_rejects_unknown_values() {
        let req = Request {
            rows: 1,
            columns: 2,
            tiles: Vec::new(),
            fx: 100.,
            fy: 100.,
            cx: 50.,
            cy: 50.,
            source_width: 100,
            source_height: 100,
            output_dir: String::new(),
            placement_mode: "nominal".into(),
            allow_nominal_grid_fallback: false,
            auto_grid_overlap: false,
            refine_grid_neighbors: false,
            seam_blend_mode: default_seam_blend_mode(),
            grid_horizontal_overlap: None,
            grid_vertical_overlap: None,
            neighbor_mode: default_neighbor_mode(),
            workers: default_workers(),
            parallel_matching: default_parallel_matching(),
            registration_megapixels: default_registration_megapixels(),
            feature_type: default_feature_type(),
            matcher_type: default_matcher_type(),
            include_diagnostic_correspondences: false,
            local_texture_warp: true,
        };
        assert!(validate(&req)
            .unwrap_err()
            .to_string()
            .contains("placementMode must be visual or grid-assisted"));
    }
    #[test]
    fn grid_step_inference_classifies_single_column_edges_as_vertical() {
        let visual = [Constraint {
            from: 0,
            to: 1,
            rotation: exp_rotation([0.23, 0.0, 0.0]),
            weight: 10.0,
        }];
        let (synthesized, _, horizontal, vertical) =
            synthesize_grid_constraints(3, 1, &visual, &[true, true, false], None, None, 1.0, 1.0)
                .unwrap();
        assert!(horizontal.is_none());
        assert!(vertical.is_some());
        assert_eq!(synthesized.len(), 1);
        assert_eq!((synthesized[0].from, synthesized[0].to), (1, 2));
        assert!(log_rotation(synthesized[0].rotation)[0].abs() > 0.2);
    }

    fn constraints_for_grid_poses(rows: usize, columns: usize, poses: &[Mat]) -> Vec<Constraint> {
        let mut constraints = Vec::new();
        for row in 0..rows {
            for column in 0..columns {
                let from = row * columns + column;
                for to in [
                    (column + 1 < columns).then_some(from + 1),
                    (row + 1 < rows).then_some(from + columns),
                ]
                .into_iter()
                .flatten()
                {
                    constraints.push(Constraint {
                        from,
                        to,
                        rotation: mul(transpose(poses[from]), poses[to]),
                        weight: 1.0,
                    });
                }
            }
        }
        constraints
    }

    #[test]
    fn rigid_component_bridge_refinement_repairs_component_gauge_without_touching_visual_edges() {
        let truth = [ID, ry(0.04), ry(0.08), ry(0.12), ry(0.16)];
        let visual = vec![
            Constraint {
                from: 0,
                to: 1,
                rotation: mul(transpose(truth[0]), truth[1]),
                weight: 1.0,
            },
            Constraint {
                from: 2,
                to: 3,
                rotation: mul(transpose(truth[2]), truth[3]),
                weight: 1.0,
            },
        ];
        let grid = [(0, 2), (1, 2), (2, 4), (3, 4)]
            .into_iter()
            .map(|(from, to)| Constraint {
                from,
                to,
                rotation: mul(transpose(truth[from]), truth[to]),
                weight: 1.0,
            })
            .collect::<Vec<_>>();
        let component_error = exp_rotation([0.006, -0.014, 0.004]);
        let mut poses = truth;
        poses[2] = mul(component_error, poses[2]);
        poses[3] = mul(component_error, poses[3]);
        let anchored_pose = poses[0];
        let original_first_visual_edge = mul(transpose(poses[0]), poses[1]);
        let original_second_visual_edge = mul(transpose(poses[2]), poses[3]);
        let mut no_cancel = |_phase: &str| -> std::result::Result<(), String> { Ok(()) };

        let report =
            refine_grid_component_poses(&mut poses, &visual, &grid, &mut no_cancel).unwrap();

        assert_eq!(report["applied"], true);
        assert!(
            report["afterBridgeCorrectionRmsRadians"].as_f64().unwrap()
                < report["beforeBridgeCorrectionRmsRadians"].as_f64().unwrap() * 0.01
        );
        assert_eq!(
            poses[0], anchored_pose,
            "anchor component gauge stays fixed"
        );
        let refined_first_visual_edge = mul(transpose(poses[0]), poses[1]);
        let refined_second_visual_edge = mul(transpose(poses[2]), poses[3]);
        for (before, after) in [
            (original_first_visual_edge, refined_first_visual_edge),
            (original_second_visual_edge, refined_second_visual_edge),
        ] {
            assert!(
                before
                    .iter()
                    .zip(after)
                    .all(|(before, after)| (before - after).abs() < 1e-10),
                "rigid component movement preserves accepted internal texture geometry"
            );
        }
        assert!(
            poses
                .iter()
                .zip(truth)
                .all(
                    |(actual, expected)| rotation_angle(mul(transpose(expected), *actual)) < 0.005
                ),
            "multiple consistent bridge observations recover the relative component pose"
        );
    }

    #[test]
    fn component_pose_solver_robustly_downweights_one_bad_bridge_observation() {
        let expected = ry(0.006);
        let bad = mul(expected, ry(0.08));
        let constraints = [
            Constraint {
                from: 0,
                to: 1,
                rotation: expected,
                weight: 1.0,
            },
            Constraint {
                from: 0,
                to: 1,
                rotation: expected,
                weight: 1.0,
            },
            Constraint {
                from: 0,
                to: 1,
                rotation: expected,
                weight: 1.0,
            },
            Constraint {
                from: 0,
                to: 1,
                rotation: bad,
                weight: 1.0,
            },
            Constraint {
                from: 1,
                to: 2,
                rotation: ID,
                weight: 1.0,
            },
        ];
        let mut no_cancel = |_phase: &str| -> std::result::Result<(), String> { Ok(()) };
        let solve = solve_component_corrections(3, &constraints, &mut no_cancel)
            .unwrap()
            .unwrap();
        assert!(solve.converged, "{solve:?}");
        let corrections = solve.corrections;
        assert!(
            rotation_angle(mul(transpose(expected), corrections[1])) < 0.004,
            "unexpected bridge correction: {:?}",
            corrections
        );
        assert!(rotation_angle(mul(transpose(expected), corrections[2])) < 0.004);
    }

    #[test]
    fn component_normal_equations_are_positive_definite_and_pcg_true_residual_is_checked() {
        let constraints = [
            Constraint {
                from: 0,
                to: 1,
                rotation: ry(0.02),
                weight: 1.0,
            },
            Constraint {
                from: 1,
                to: 2,
                rotation: exp_rotation([0.01, 0.0, 0.0]),
                weight: 0.5,
            },
            Constraint {
                from: 0,
                to: 2,
                rotation: mul(ry(0.04), exp_rotation([0.0, 0.0, 0.002])),
                weight: 0.25,
            },
        ];
        let corrections = vec![ID; 3];
        let mut no_cancel = |_phase: &str| -> std::result::Result<(), String> { Ok(()) };
        let (matrix, rhs, gradient_norm) =
            assemble_component_normal_equations(&corrections, &constraints, &mut no_cancel)
                .unwrap();
        assert!(gradient_norm > 0.0);
        let dimension = rhs.len();
        assert_eq!(dimension, 6);
        for row in 0..dimension {
            for column in 0..dimension {
                assert!((matrix.get(row, column) - matrix.get(column, row)).abs() < 1e-10);
            }
        }
        let probe = [0.2, -0.4, 0.1, -0.3, 0.15, 0.25];
        let quadratic = (0..dimension)
            .map(|row| {
                probe[row]
                    * (0..dimension)
                        .map(|column| matrix.get(row, column) * probe[column])
                        .sum::<f64>()
            })
            .sum::<f64>();
        assert!(
            quadratic > 0.0,
            "anchored normal matrix is not positive definite"
        );

        let solved = solve_pcg(&matrix, &rhs, dimension, &mut no_cancel).unwrap();
        assert!(solved.converged);
        assert!(solved.relative_residual <= 1e-8);
        let delta = solved.delta.unwrap();
        let predicted = matrix.apply(&delta).unwrap();
        let true_residual = rhs
            .iter()
            .zip(predicted)
            .map(|(value, predicted)| (value - predicted).powi(2))
            .sum::<f64>()
            .sqrt()
            / rhs.iter().map(|value| value * value).sum::<f64>().sqrt();
        assert!(true_residual <= 1e-8, "true PCG residual {true_residual:e}");
        // Six scalar variables for two non-anchor components prove the fixed
        // component gauge is excluded from both normal assembly and PCG.
        assert_eq!(rhs.len(), 2 * 3);
    }

    #[test]
    fn large_normal_storage_tracks_actual_neighbor_blocks() {
        let node_count = 2048usize;
        let mut matrix = NormalMatrix::new(node_count * 3).unwrap();
        assert!(matrix.dense().is_none());
        for node in 0..node_count {
            for axis in 0..3 {
                matrix.add(node * 3 + axis, node * 3 + axis, 1.0).unwrap();
            }
            if node + 1 < node_count {
                matrix.add(node * 3, (node + 1) * 3, -0.25).unwrap();
                matrix.add((node + 1) * 3, node * 3, -0.25).unwrap();
            }
        }
        let stored_blocks = match &matrix {
            NormalMatrix::SparseBlocks { rows, .. } => rows.iter().map(Vec::len).sum::<usize>(),
            NormalMatrix::Dense { .. } => unreachable!(),
        };
        assert!(stored_blocks <= node_count * 3);
        assert!(
            stored_blocks * (std::mem::size_of::<NormalBlock>() + std::mem::size_of::<usize>())
                < node_count * node_count * 9 * std::mem::size_of::<f64>() / 100
        );
    }

    #[test]
    fn sparse_block_pcg_recomputes_true_residual_on_large_neighbor_graph() {
        let node_count = 450usize;
        let dimension = node_count * 3;
        let mut matrix = NormalMatrix::new(dimension).unwrap();
        assert!(matrix.dense().is_none());
        for node in 0..node_count {
            for axis in 0..3 {
                matrix.add(node * 3 + axis, node * 3 + axis, 4.0).unwrap();
                if node + 1 < node_count {
                    matrix
                        .add(node * 3 + axis, (node + 1) * 3 + axis, -0.25)
                        .unwrap();
                    matrix
                        .add((node + 1) * 3 + axis, node * 3 + axis, -0.25)
                        .unwrap();
                }
            }
        }
        let truth = (0..dimension)
            .map(|index| (index as f64 * 0.013).sin())
            .collect::<Vec<_>>();
        let rhs = matrix.apply(&truth).unwrap();
        let mut no_cancel = |_phase: &str| -> std::result::Result<(), String> { Ok(()) };
        let solved = solve_pcg(&matrix, &rhs, dimension, &mut no_cancel).unwrap();
        assert!(solved.converged, "sparse PCG did not converge: {solved:?}");
        let delta = solved.delta.unwrap();
        let actual = matrix.apply(&delta).unwrap();
        let rhs_norm = rhs.iter().map(|value| value * value).sum::<f64>().sqrt();
        let residual = rhs
            .iter()
            .zip(actual)
            .map(|(expected, actual)| (expected - actual).powi(2))
            .sum::<f64>()
            .sqrt()
            / rhs_norm;
        assert!(residual <= 1e-8, "sparse PCG true residual {residual:e}");
        assert!(solved.relative_residual <= 1e-8);
    }

    #[test]
    fn pcg_does_not_claim_convergence_when_block_preconditioner_is_singular() {
        let matrix = NormalMatrix::new(3).unwrap();
        let rhs = [1.0, 0.0, 0.0];
        let mut no_cancel = |_phase: &str| -> std::result::Result<(), String> { Ok(()) };
        let result = solve_pcg(&matrix, &rhs, 3, &mut no_cancel).unwrap();
        assert!(!result.converged);
        assert!(result.delta.is_none());
        assert!(!result.relative_residual.is_finite());
    }

    #[test]
    fn component_pose_solver_converges_on_a_132_node_sparse_bridge_lattice() {
        let (rows, columns) = (12usize, 11usize);
        let truth = (0..rows)
            .flat_map(|row| {
                (0..columns).map(move |column| {
                    exp_rotation([
                        row as f64 * 0.0017,
                        column as f64 * 0.0031,
                        (row * column) as f64 * 0.000006,
                    ])
                })
            })
            .collect::<Vec<_>>();
        let mut pairs = Vec::new();
        for row in 0..rows {
            for column in 0..columns {
                let from = row * columns + column;
                if column + 1 < columns {
                    pairs.push((from, from + 1));
                }
                if row + 1 < rows {
                    pairs.push((from, from + columns));
                }
            }
        }
        assert_eq!(pairs.len(), 241);
        for index in 0..29 {
            pairs.push((index, index + 37));
        }
        assert_eq!(pairs.len(), 270);
        let constraints = pairs
            .into_iter()
            .enumerate()
            .map(|(index, (from, to))| {
                let mut rotation = mul(transpose(truth[from]), truth[to]);
                if index == 173 {
                    rotation = mul(rotation, exp_rotation([0.07, -0.02, 0.01]));
                }
                Constraint {
                    from,
                    to,
                    rotation,
                    weight: 1.0,
                }
            })
            .collect::<Vec<_>>();
        let initial = vec![ID; truth.len()];
        let initial_cost = component_huber_objective(&initial, &constraints);
        let initial_rms = component_constraint_rms(&initial, &constraints);
        let mut no_cancel = |_phase: &str| -> std::result::Result<(), String> { Ok(()) };
        let solve = solve_component_corrections(truth.len(), &constraints, &mut no_cancel)
            .unwrap()
            .unwrap();
        assert!(
            solve.converged,
            "132 node sparse bridge solve failed: {solve:?}"
        );
        assert!(solve.iterations <= 30);
        assert_eq!(solve.corrections[0], ID);
        assert!(solve.max_pcg_relative_residual <= 1e-8);
        assert_eq!(solve.pcg_failed_attempts, 0);
        assert!(solve.final_objective < initial_cost);
        assert!(component_constraint_rms(&solve.corrections, &constraints) < initial_rms);
        for component in 1..truth.len() {
            assert!(
                rotation_angle(mul(
                    transpose(truth[component]),
                    solve.corrections[component]
                )) < 0.01,
                "component {component} drifted from synthetic truth by {} rad",
                rotation_angle(mul(
                    transpose(truth[component]),
                    solve.corrections[component]
                ))
            );
        }
    }

    #[test]
    fn component_bridge_refinement_handles_a_full_16_by_24_grid_and_is_noop_without_bridges() {
        let (rows, columns) = (16, 24);
        let truth = (0..rows)
            .flat_map(|row| {
                (0..columns).map(move |column| {
                    mul(
                        ry(column as f64 * 0.035),
                        exp_rotation([row as f64 * 0.018, 0.0, 0.0]),
                    )
                })
            })
            .collect::<Vec<_>>();
        let grid = constraints_for_grid_poses(rows, columns, &truth);
        let mut noisy = truth
            .iter()
            .enumerate()
            .map(|(index, pose)| {
                mul(
                    exp_rotation([
                        ((index % 7) as f64 - 3.0) * 0.0007,
                        ((index % 5) as f64 - 2.0) * 0.0005,
                        ((index % 3) as f64 - 1.0) * 0.0004,
                    ]),
                    *pose,
                )
            })
            .collect::<Vec<_>>();
        let anchor_pose = noisy[0];
        let mut no_cancel = |_phase: &str| -> std::result::Result<(), String> { Ok(()) };
        let report = refine_grid_component_poses(&mut noisy, &[], &grid, &mut no_cancel).unwrap();
        assert_eq!(report["applied"], true);
        assert_eq!(noisy[0], anchor_pose);
        assert!(
            report["afterBridgeCorrectionRmsRadians"].as_f64().unwrap()
                < report["beforeBridgeCorrectionRmsRadians"].as_f64().unwrap() * 0.1
        );

        let one_component_visual = (0..3)
            .map(|index| Constraint {
                from: index,
                to: index + 1,
                rotation: mul(transpose(truth[index]), truth[index + 1]),
                weight: 1.0,
            })
            .collect::<Vec<_>>();
        let internal_grid = (0..3)
            .map(|index| Constraint {
                from: index,
                to: index + 1,
                rotation: mul(transpose(truth[index]), truth[index + 1]),
                weight: 1.0,
            })
            .collect::<Vec<_>>();
        let mut unchanged = truth[..4].to_vec();
        let before = unchanged.clone();
        let no_op = refine_grid_component_poses(
            &mut unchanged,
            &one_component_visual,
            &internal_grid,
            &mut no_cancel,
        )
        .unwrap();
        assert_eq!(no_op["applied"], false);
        assert_eq!(no_op["reason"], "no_cross_component_grid_bridges");
        assert_eq!(unchanged, before);
    }

    #[test]
    #[ignore = "set LUMIA_GRID_COMPONENT_LAYOUT_FIXTURE to replay the preserved 384-photo bridge topology"]
    fn component_solver_replays_preserved_384_bridge_topology() {
        let path = std::env::var("LUMIA_GRID_COMPONENT_LAYOUT_FIXTURE")
            .expect("set LUMIA_GRID_COMPONENT_LAYOUT_FIXTURE to accepted-layout.json");
        let layout: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        let tiles = layout["tiles"].as_array().unwrap();
        let report = &layout["report"];
        assert_eq!(tiles.len(), 384);
        let poses = tiles
            .iter()
            .map(|tile| {
                let values = tile["cameraToWorld"].as_array().unwrap();
                std::array::from_fn(|index| values[index].as_f64().unwrap())
            })
            .collect::<Vec<Mat>>();
        let rows = report["gridComponentPoseRefinement"]["componentCount"]
            .as_u64()
            .expect("preserved layout should report grid components");
        assert_eq!(rows, 132, "real 384 component topology changed");
        let components = report["visualComponents"].as_array().unwrap();
        let mut component_by_tile = vec![usize::MAX; tiles.len()];
        for component in components {
            let id = component["componentId"].as_u64().unwrap() as usize;
            for tile in component["tileIndices"].as_array().unwrap() {
                component_by_tile[tile.as_u64().unwrap() as usize] = id;
            }
        }
        assert!(component_by_tile.iter().all(|id| *id != usize::MAX));

        let row_count = tiles
            .iter()
            .map(|tile| tile["row"].as_u64().unwrap() as usize)
            .max()
            .unwrap()
            + 1;
        let column_count = tiles
            .iter()
            .map(|tile| tile["column"].as_u64().unwrap() as usize)
            .max()
            .unwrap()
            + 1;
        let mut horizontal_by_row = vec![Vec::<Mat>::new(); row_count];
        let mut vertical_by_column = vec![Vec::<Mat>::new(); column_count];
        let mut horizontal_all = Vec::new();
        let mut vertical_all = Vec::new();
        let mut replay_visual_constraints = Vec::new();
        for edge in report["edgeDiagnostics"].as_array().unwrap() {
            if edge["disposition"] != "accepted" {
                continue;
            }
            let from = edge["from"].as_u64().unwrap() as usize;
            let to = edge["to"].as_u64().unwrap() as usize;
            let from_row = tiles[from]["row"].as_u64().unwrap() as usize;
            let from_column = tiles[from]["column"].as_u64().unwrap() as usize;
            let to_row = tiles[to]["row"].as_u64().unwrap() as usize;
            let to_column = tiles[to]["column"].as_u64().unwrap() as usize;
            let relative = mul(transpose(poses[from]), poses[to]);
            replay_visual_constraints.push(Constraint {
                from,
                to,
                rotation: relative,
                weight: 1.0,
            });
            if from_row == to_row && to_column == from_column + 1 {
                horizontal_by_row[from_row].push(relative);
                horizontal_all.push(relative);
            } else if from_column == to_column && to_row == from_row + 1 {
                vertical_by_column[from_column].push(relative);
                vertical_all.push(relative);
            }
        }
        let horizontal_fallback = robust_grid_step(&horizontal_all).unwrap();
        let vertical_fallback = robust_grid_step(&vertical_all).unwrap();
        let horizontal_by_row = horizontal_by_row
            .iter()
            .map(|samples| robust_grid_step(samples).unwrap_or_else(|| horizontal_fallback.clone()))
            .collect::<Vec<_>>();
        let vertical_by_column = vertical_by_column
            .iter()
            .map(|samples| robust_grid_step(samples).unwrap_or_else(|| vertical_fallback.clone()))
            .collect::<Vec<_>>();

        let mut visual_edge_counts = vec![0usize; components.len()];
        for edge in report["edgeDiagnostics"].as_array().unwrap() {
            if edge["disposition"] == "accepted" {
                let from = edge["from"].as_u64().unwrap() as usize;
                visual_edge_counts[component_by_tile[from]] += 1;
            }
        }
        let anchor_component = (0..components.len())
            .max_by_key(|component| {
                (
                    visual_edge_counts[*component] > 0,
                    visual_edge_counts[*component],
                    components[*component]["tileIndices"]
                        .as_array()
                        .unwrap()
                        .len(),
                    std::cmp::Reverse(
                        components[*component]["tileIndices"][0].as_u64().unwrap() as usize
                    ),
                )
            })
            .unwrap();
        let mut component_order = vec![anchor_component];
        component_order.extend((0..components.len()).filter(|id| *id != anchor_component));
        let mut ordered_component = vec![usize::MAX; components.len()];
        for (ordered, component) in component_order.iter().copied().enumerate() {
            ordered_component[component] = ordered;
        }
        let mut constraints = Vec::new();
        let mut replay_grid_constraints = Vec::new();
        for edge in report["gridBridgedEdges"].as_array().unwrap() {
            let from = edge["from"].as_u64().unwrap() as usize;
            let to = edge["to"].as_u64().unwrap() as usize;
            let from_component = component_by_tile[from];
            let to_component = component_by_tile[to];
            if from_component == to_component {
                continue;
            }
            let direction = edge["direction"].as_str().unwrap();
            let step = if direction == "horizontal" {
                horizontal_by_row[tiles[from]["row"].as_u64().unwrap() as usize].rotation
            } else {
                vertical_by_column[tiles[from]["column"].as_u64().unwrap() as usize].rotation
            };
            replay_grid_constraints.push(Constraint {
                from,
                to,
                rotation: step,
                weight: 1.0,
            });
            let relative_correction = mul(mul(poses[from], step), transpose(poses[to]));
            constraints.push(Constraint {
                from: ordered_component[from_component],
                to: ordered_component[to_component],
                rotation: relative_correction,
                weight: 1.0,
            });
        }
        assert_eq!(constraints.len(), 270, "real 384 bridge topology changed");
        let initial = vec![ID; components.len()];
        let initial_cost = component_huber_objective(&initial, &constraints);
        let initial_rms = component_constraint_rms(&initial, &constraints);
        let mut no_cancel = |_phase: &str| -> std::result::Result<(), String> { Ok(()) };
        let solve = solve_component_corrections(components.len(), &constraints, &mut no_cancel)
            .unwrap()
            .unwrap();
        eprintln!(
            "384 bridge replay: components={} bridges={} iterations={} step={:.3e} gradient={:.3e} cost={:.9e}->{:.9e} rms={:.6e}->{:.6e} pcgIterations={} maxPcgResidual={:.3e}",
            components.len(),
            constraints.len(),
            solve.iterations,
            solve.final_max_step_radians,
            solve.final_gradient_norm,
            initial_cost,
            solve.final_objective,
            initial_rms,
            component_constraint_rms(&solve.corrections, &constraints),
            solve.pcg_iterations,
            solve.max_pcg_relative_residual
        );
        assert!(
            solve.converged,
            "384 replay solver: reason={} iter={} step={:.3e} objective={:.9e} gradient={:.3e} pcg={:.3e}/{}",
            solve.termination_reason,
            solve.iterations,
            solve.final_max_step_radians,
            solve.final_objective,
            solve.final_gradient_norm,
            solve.max_pcg_relative_residual,
            solve.pcg_iterations
        );
        assert!(solve.iterations <= MAX_GRID_COMPONENT_POSE_ITERATIONS);
        assert!(solve.pcg_failed_attempts == 0);
        assert!(solve.max_pcg_relative_residual <= 1e-8);
        assert!(solve.final_objective < initial_cost);
        assert!(component_constraint_rms(&solve.corrections, &constraints) < initial_rms);
        let mut refined_poses = poses.clone();
        let report = refine_grid_component_poses(
            &mut refined_poses,
            &replay_visual_constraints,
            &replay_grid_constraints,
            &mut no_cancel,
        )
        .unwrap();
        assert_eq!(report["applied"], true, "{report}");
        assert_eq!(report["converged"], true, "{report}");
        assert_eq!(report["componentCount"], 132);
        assert_eq!(report["bridgeConstraintCount"], 270);
        if let Ok(output_path) = std::env::var("LUMIA_GRID_COMPONENT_REPLAY_OUTPUT") {
            let mut candidate = layout.clone();
            for tile_index in 0..tiles.len() {
                let component = component_by_tile[tile_index];
                let ordered = ordered_component[component];
                let adjusted_pose =
                    normalize_rotation(mul(solve.corrections[ordered], poses[tile_index])).unwrap();
                candidate["tiles"][tile_index]["cameraToWorld"] = json!(adjusted_pose);
            }
            candidate["diagnosticComponentReplay"] = json!({
                "diagnosticOnly":true,
                "productionLayoutEmitted":false,
                "sourceLayoutPath":path,
                "approximateBridgeStepRecovery":"row/column robust medians of accepted neighboring camera pose deltas; old report does not include exact per-edge bridge rotations",
                "componentCount":components.len(),
                "bridgeCount":constraints.len(),
                "iterations":solve.iterations,
                "converged":solve.converged,
                "terminationReason":solve.termination_reason,
                "finalMaxStepRadians":solve.final_max_step_radians,
                "finalGradientNorm":solve.final_gradient_norm,
                "initialHuberObjective":initial_cost,
                "finalHuberObjective":solve.final_objective,
                "beforeBridgeRmsRadians":initial_rms,
                "afterBridgeRmsRadians":component_constraint_rms(&solve.corrections,&constraints),
                "pcgIterations":solve.pcg_iterations,
                "maxPcgRelativeResidual":solve.max_pcg_relative_residual
            });
            std::fs::write(output_path, serde_json::to_vec_pretty(&candidate).unwrap()).unwrap();
        }
    }

    #[test]
    fn component_bridge_refinement_observes_cancellation_during_iterations() {
        let poses = [ID, ry(0.04), ry(0.08), ry(0.12)];
        let grid = constraints_for_grid_poses(2, 2, &poses);
        let mut perturbed = poses
            .iter()
            .enumerate()
            .map(|(index, pose)| mul(ry(index as f64 * 0.003), *pose))
            .collect::<Vec<_>>();
        let mut checkpoints = 0;
        let mut cancel = |_phase: &str| -> std::result::Result<(), String> {
            checkpoints += 1;
            if checkpoints > 3 {
                Err("cancelled".to_owned())
            } else {
                Ok(())
            }
        };
        assert!(matches!(
            refine_grid_component_poses(&mut perturbed, &[], &grid, &mut cancel),
            Err(Error::Cancelled)
        ));
    }

    #[test]
    fn four_neighbor_solver_matches_uniform_grid_pose_construction() {
        let (rows, columns) = (3, 4);
        let horizontal = ry(0.12);
        let vertical = exp_rotation([0.09, 0.0, 0.0]);
        let mut expected = Vec::with_capacity(rows * columns);
        let mut row_rotation = ID;
        for _ in 0..rows {
            let mut column_rotation = ID;
            for _ in 0..columns {
                expected.push(mul(column_rotation, row_rotation));
                column_rotation = mul(column_rotation, horizontal);
            }
            row_rotation = mul(row_rotation, vertical);
        }
        let constraints = constraints_for_grid_poses(rows, columns, &expected);
        assert_eq!(
            constraints.len(),
            rows * (columns - 1) + columns * (rows - 1)
        );
        let actual = solve_orientations(expected.len(), &constraints).unwrap();
        for (actual, expected) in actual.iter().zip(expected) {
            for i in 0..9 {
                assert!((actual[i] - expected[i]).abs() < 1e-7);
            }
        }
    }

    #[test]
    fn four_neighbor_solver_preserves_nonuniform_local_steps_and_grid_connectivity() {
        let (rows, columns) = (3, 3);
        let mut expected = Vec::with_capacity(rows * columns);
        for row in 0..rows {
            for column in 0..columns {
                let horizontal = 0.10 * column as f64 + 0.012 * row as f64 * column as f64;
                let vertical = 0.09 * row as f64 + 0.004 * row as f64 * column as f64;
                expected.push(mul(ry(horizontal), exp_rotation([vertical, 0.0, 0.0])));
            }
        }
        let constraints = constraints_for_grid_poses(rows, columns, &expected);
        assert_eq!(connected_tiles(expected.len(), &constraints), vec![true; 9]);
        let actual = solve_orientations(expected.len(), &constraints).unwrap();
        for (actual, expected) in actual.iter().zip(expected) {
            for i in 0..9 {
                assert!((actual[i] - expected[i]).abs() < 1e-7);
            }
        }
        let top_step = mul(transpose(actual[0]), actual[1]);
        let middle_step = mul(transpose(actual[3]), actual[4]);
        assert!((log_rotation(top_step)[1] - log_rotation(middle_step)[1]).abs() > 0.01);
    }

    #[test]
    fn isolated_reference_and_larger_visual_component_have_distinct_provenance() {
        let constraints = (1..8)
            .map(|from| Constraint {
                from,
                to: from + 1,
                rotation: ry(0.01),
                weight: 1.0,
            })
            .collect::<Vec<_>>();
        let components = visual_components(9, &constraints);
        assert_eq!(components[0], vec![0]);
        assert_eq!(components[1], (1..=8).collect::<Vec<_>>());
        assert_eq!(
            connected_tiles(9, &constraints),
            vec![true, false, false, false, false, false, false, false, false]
        );
        assert_eq!(
            root_anchored_visual_tiles(9, &constraints),
            vec![false; 9],
            "an isolated reference tile has no visual anchor"
        );
        let mut directly_supported = vec![false; 9];
        for edge in &constraints {
            directly_supported[edge.from] = true;
            directly_supported[edge.to] = true;
        }
        assert_eq!(
            directly_supported
                .iter()
                .filter(|supported| **supported)
                .count(),
            8
        );
        assert!(!directly_supported[0]);
    }
    #[test]
    fn rotation_log_exp_round_trip_covers_mixed_and_single_axes() {
        for axis_angle in [[0.13, -0.09, 0.2], [0.0, 0.0, 0.31], [-0.22, 0.0, 0.0]] {
            let recovered = log_rotation(exp_rotation(axis_angle));
            for i in 0..3 {
                assert!((recovered[i] - axis_angle[i]).abs() < 1e-9);
            }
        }
        let known = ry(0.23);
        let recovered = exp_rotation(log_rotation(known));
        for i in 0..9 {
            assert!((known[i] - recovered[i]).abs() < 1e-9);
        }
    }
    #[test]
    fn left_rotation_jacobian_matches_finite_difference() {
        let v = [0.2, -0.4, 0.9];
        let jacobian = left_rotation_jacobian(v);
        let epsilon = 1e-7;
        for axis in 0..3 {
            let mut plus = [0.; 3];
            let mut minus = [0.; 3];
            plus[axis] = epsilon;
            minus[axis] = -epsilon;
            let rp = mul_vec(exp_rotation(plus), v);
            let rm = mul_vec(exp_rotation(minus), v);
            for row in 0..3 {
                let numeric = (rp[row] - rm[row]) / (2. * epsilon);
                assert!((numeric - jacobian[row][axis]).abs() < 1e-8);
            }
        }
    }
    #[test]
    fn pixel_ray_axes_follow_shared_contract() {
        let req = Request {
            rows: 1,
            columns: 1,
            tiles: vec![],
            fx: 100.,
            fy: 100.,
            cx: 50.,
            cy: 50.,
            source_width: 100,
            source_height: 100,
            output_dir: String::new(),
            placement_mode: String::new(),
            allow_nominal_grid_fallback: false,
            auto_grid_overlap: false,
            refine_grid_neighbors: false,
            seam_blend_mode: default_seam_blend_mode(),
            grid_horizontal_overlap: None,
            grid_vertical_overlap: None,
            neighbor_mode: default_neighbor_mode(),
            workers: default_workers(),
            parallel_matching: default_parallel_matching(),
            registration_megapixels: default_registration_megapixels(),
            feature_type: default_feature_type(),
            matcher_type: default_matcher_type(),
            include_diagnostic_correspondences: false,
            local_texture_warp: true,
        };
        assert_eq!(ray_to_world(ID, 50., 50., &req), [0., 0., 1.]);
        let ray = ray_to_world(ID, 50., 0., &req);
        assert!(ray[1] > 0.);
    }

    fn reprojection_fixture_edge(points: Vec<[f64; 4]>) -> crate::pipeline::SphericalMatchEdge {
        let attempt = crate::pipeline::SphericalMatchAttempt {
            from_features: points.len(),
            to_features: points.len(),
            matches: points.len(),
            inliers: points.len(),
            inlier_ratio: 1.0,
            reason: 0,
            contrast_threshold: 0.015,
            clahe: false,
        };
        crate::pipeline::SphericalMatchEdge {
            from: 0,
            to: 1,
            from_features: points.len(),
            to_features: points.len(),
            matches: points.len(),
            inliers: points.len(),
            inlier_ratio: 1.0,
            homography_residual: 0.0,
            reason: 0,
            points,
            initial: attempt,
            retry: None,
            clahe_retry: None,
            used_retry: false,
            used_clahe_retry: false,
        }
    }

    #[test]
    fn pixel_refinement_improves_texture_alignment_without_moving_component_anchors() {
        let req = Request {
            rows: 2,
            columns: 2,
            tiles: vec![],
            fx: 500.0,
            fy: 500.0,
            cx: 500.0,
            cy: 400.0,
            source_width: 1000,
            source_height: 800,
            output_dir: String::new(),
            placement_mode: "grid-assisted".into(),
            allow_nominal_grid_fallback: true,
            auto_grid_overlap: false,
            refine_grid_neighbors: false,
            seam_blend_mode: default_seam_blend_mode(),
            grid_horizontal_overlap: None,
            grid_vertical_overlap: None,
            neighbor_mode: default_neighbor_mode(),
            workers: default_workers(),
            parallel_matching: default_parallel_matching(),
            registration_megapixels: default_registration_megapixels(),
            feature_type: default_feature_type(),
            matcher_type: default_matcher_type(),
            include_diagnostic_correspondences: false,
            local_texture_warp: true,
        };
        let true_relative = ry(0.08);
        let source_points = [
            (180.0, 150.0),
            (310.0, 210.0),
            (420.0, 330.0),
            (560.0, 130.0),
            (680.0, 240.0),
            (820.0, 370.0),
            (250.0, 560.0),
            (390.0, 660.0),
            (620.0, 540.0),
            (790.0, 620.0),
            (470.0, 470.0),
            (730.0, 460.0),
        ];
        let make_edge = |from: usize, to: usize| {
            let points = source_points
                .iter()
                .map(|&(x, y)| {
                    let source_ray = camera_ray(x, y, &req);
                    let target_ray = mul_vec(transpose(true_relative), source_ray);
                    let target = project_camera_ray(target_ray, &req).unwrap();
                    [x, y, target.0, target.1]
                })
                .collect();
            let mut edge = reprojection_fixture_edge(points);
            edge.from = from;
            edge.to = to;
            edge
        };
        let mut edges = vec![make_edge(0, 1), make_edge(2, 3)];
        let mut rejected_edge = make_edge(0, 3);
        for point in &mut rejected_edge.points {
            point[2] += 75.0;
        }
        edges.push(rejected_edge);
        let constraints = vec![
            Constraint {
                from: 0,
                to: 1,
                rotation: true_relative,
                weight: 1.0,
            },
            Constraint {
                from: 2,
                to: 3,
                rotation: true_relative,
                weight: 1.0,
            },
        ];
        let component_2_anchor = ry(-0.31);
        let mut poses = vec![
            ID,
            ry(0.083),
            component_2_anchor,
            mul(component_2_anchor, ry(0.077)),
        ];
        let anchor_before = poses[0];
        let disconnected_anchor_before = poses[2];
        let initial_poses = poses.clone();
        let valid_edges = [&edges[0], &edges[1]];
        let before = incident_pixel_cost(&poses, 1, &valid_edges, &req)
            + incident_pixel_cost(&poses, 3, &valid_edges, &req);

        let mut checkpoint = |_: &str| -> std::result::Result<(), String> { Ok(()) };
        let (reinitialized_count, refined_count, _, _, sweeps, converged, ..) =
            refine_visual_component_pixels(&mut poses, &constraints, &edges, &req, &mut checkpoint)
                .unwrap();
        let after = incident_pixel_cost(&poses, 1, &valid_edges, &req)
            + incident_pixel_cost(&poses, 3, &valid_edges, &req);

        assert_eq!(refined_count, 2);
        assert_eq!(reinitialized_count, 2);
        assert!(sweeps <= MAX_PIXEL_REFINEMENT_ITERATIONS);
        assert!(converged);
        assert!(after < before * 0.01, "pixel cost {before} -> {after}");
        assert_eq!(poses[0], anchor_before);
        assert_eq!(poses[2], disconnected_anchor_before);
        let truth_relative = mul(transpose(poses[2]), poses[3]);
        let truth_error = log_rotation(mul(transpose(true_relative), truth_relative));
        assert!(
            truth_error
                .iter()
                .map(|value| value * value)
                .sum::<f64>()
                .sqrt()
                < 1e-5
        );
        let mut cancel_poses = initial_poses;
        let mut cancel_at_camera = |stage: &str| {
            if stage == "pixel-refinement-camera" {
                Err("cancel at camera checkpoint".to_owned())
            } else {
                Ok(())
            }
        };
        assert!(matches!(
            refine_visual_component_pixels(
                &mut cancel_poses,
                &constraints,
                &edges,
                &req,
                &mut cancel_at_camera,
            ),
            Err(Error::Cancelled)
        ));
    }

    #[test]
    fn pixel_bundle_keeps_peers_stable_when_a_loop_conflict_is_downweighted() {
        let mut req = grid_request(2, 2);
        req.fx = 500.0;
        req.fy = 480.0;
        req.cx = 200.0;
        req.cy = 150.0;
        req.source_width = 400;
        req.source_height = 300;
        let truth = [
            ID,
            mul(rx(0.04), ry(0.1)),
            rz(-0.08),
            mul(ry(0.12), rz(0.03)),
        ];
        let pairs = [(0, 1), (1, 3), (2, 3), (0, 2)];
        let corners = [
            (30.0, 30.0),
            (360.0, 30.0),
            (30.0, 270.0),
            (360.0, 270.0),
            (100.0, 80.0),
            (300.0, 220.0),
            (190.0, 40.0),
            (210.0, 260.0),
        ];
        let mut edges = pairs
            .iter()
            .map(|&(from, to)| {
                let points = corners
                    .iter()
                    .map(|&(x, y)| {
                        let world_ray = mul_vec(truth[from], camera_ray(x, y, &req));
                        let target_ray = mul_vec(transpose(truth[to]), world_ray);
                        let (tx, ty) = project_camera_ray(target_ray, &req).unwrap();
                        [x, y, tx, ty]
                    })
                    .collect::<Vec<_>>();
                let mut edge = reprojection_fixture_edge(points);
                edge.from = from;
                edge.to = to;
                edge
            })
            .collect::<Vec<_>>();
        for point in &mut edges[0].points {
            point[2] += 35.0;
        }
        let constraints = pairs
            .iter()
            .map(|&(from, to)| Constraint {
                from,
                to,
                rotation: mul(transpose(truth[from]), truth[to]),
                weight: 1.0,
            })
            .collect::<Vec<_>>();
        let mut unweighted = truth;
        let mut weighted = truth;
        let mut no_cancel = |_: &str| -> std::result::Result<(), String> { Ok(()) };
        refine_visual_component_pixels_mode(
            &mut unweighted,
            &constraints,
            &edges,
            &req,
            &mut no_cancel,
            true,
        )
        .unwrap();
        let scales = std::collections::HashMap::from([((0, 1), 0.001)]);
        refine_visual_component_pixels_with_reliability(
            &mut weighted,
            &constraints,
            &edges,
            &req,
            &mut no_cancel,
            true,
            &scales,
        )
        .unwrap();
        let pose_error = |poses: &[Mat]| {
            poses
                .iter()
                .zip(truth)
                .skip(1)
                .map(|(pose, expected)| {
                    log_rotation(mul(transpose(expected), *pose))
                        .iter()
                        .map(|value| value * value)
                        .sum::<f64>()
                        .sqrt()
                })
                .sum::<f64>()
        };
        let unweighted_error = pose_error(&unweighted);
        let weighted_error = pose_error(&weighted);
        assert!(
            weighted_error < unweighted_error * 0.5,
            "weighted pixel optimization should protect the peer backbone: {weighted_error} vs {unweighted_error}"
        );
    }

    #[test]
    fn pixel_refinement_converges_on_a_long_visual_loop_with_monotonic_cost() {
        let req = Request {
            rows: 1,
            columns: 9,
            tiles: vec![],
            fx: 500.0,
            fy: 500.0,
            cx: 500.0,
            cy: 400.0,
            source_width: 1000,
            source_height: 800,
            output_dir: String::new(),
            placement_mode: "grid-assisted".into(),
            allow_nominal_grid_fallback: true,
            auto_grid_overlap: false,
            refine_grid_neighbors: false,
            seam_blend_mode: default_seam_blend_mode(),
            grid_horizontal_overlap: None,
            grid_vertical_overlap: None,
            neighbor_mode: default_neighbor_mode(),
            workers: default_workers(),
            parallel_matching: default_parallel_matching(),
            registration_megapixels: default_registration_megapixels(),
            feature_type: default_feature_type(),
            matcher_type: default_matcher_type(),
            include_diagnostic_correspondences: false,
            local_texture_warp: true,
        };
        let truth = (0..9)
            .map(|index| ry(index as f64 * 0.04))
            .collect::<Vec<_>>();
        let source_points = [
            (180.0, 150.0),
            (310.0, 210.0),
            (420.0, 330.0),
            (560.0, 130.0),
            (680.0, 240.0),
            (820.0, 370.0),
            (250.0, 560.0),
            (390.0, 660.0),
            (620.0, 540.0),
            (790.0, 620.0),
            (470.0, 470.0),
            (730.0, 460.0),
        ];
        let pairs = (0..8)
            .map(|index| (index, index + 1))
            .chain(std::iter::once((8, 0)))
            .collect::<Vec<_>>();
        let mut edges = Vec::new();
        let mut constraints = Vec::new();
        for (edge_index, (from, to)) in pairs.into_iter().enumerate() {
            let rotation = mul(transpose(truth[to]), truth[from]);
            let points = source_points
                .iter()
                .map(|&(x, y)| {
                    let source_ray = camera_ray(x, y, &req);
                    let target_ray = mul_vec(transpose(rotation), source_ray);
                    let target = project_camera_ray(target_ray, &req).unwrap();
                    [x, y, target.0, target.1]
                })
                .collect();
            let mut edge = reprojection_fixture_edge(points);
            edge.from = from;
            edge.to = to;
            edges.push(edge);
            constraints.push(Constraint {
                from,
                to,
                // Perturb graph initialization independently from the exact
                // feature correspondences so this test exercises pixel BA.
                rotation: mul(rotation, ry((edge_index as f64 - 4.0) * 0.001)),
                weight: 1.0,
            });
        }
        let mut poses = (0..9)
            .map(|index| {
                if index == 0 {
                    ID
                } else {
                    ry(index as f64 * 0.04 + index as f64 * 0.0015)
                }
            })
            .collect::<Vec<_>>();
        let anchor_before = poses[0];
        let mut checkpoint = |_: &str| -> std::result::Result<(), String> { Ok(()) };
        let (reinitialized, optimized, before, after, sweeps, converged, ..) =
            refine_visual_component_pixels(&mut poses, &constraints, &edges, &req, &mut checkpoint)
                .unwrap();

        assert_eq!(reinitialized, 8);
        assert_eq!(optimized, 8);
        assert!(
            after < before * 0.05,
            "symmetric L2 norm {before} -> {after}"
        );
        assert!(sweeps > 0 && converged);
        assert_eq!(poses[0], anchor_before);
    }

    #[test]
    fn joint_pixel_bundle_converges_on_a_noisy_four_by_six_grid_loop() {
        let mut req = grid_request(4, 6);
        req.fx = 500.0;
        req.fy = 500.0;
        req.cx = 500.0;
        req.cy = 400.0;
        req.source_width = 1000;
        req.source_height = 800;
        let truth = (0..4)
            .flat_map(|row| {
                (0..6).map(move |column| {
                    mul(
                        ry(column as f64 * 0.045),
                        exp_rotation([row as f64 * 0.035, 0.0, 0.0]),
                    )
                })
            })
            .collect::<Vec<_>>();
        let source_points = [
            (180.0, 150.0),
            (310.0, 210.0),
            (420.0, 330.0),
            (560.0, 130.0),
            (680.0, 240.0),
            (820.0, 370.0),
            (250.0, 560.0),
            (390.0, 660.0),
            (620.0, 540.0),
            (790.0, 620.0),
            (470.0, 470.0),
            (730.0, 460.0),
        ];
        let mut pairs = Vec::new();
        for row in 0..4 {
            for column in 0..6 {
                let from = row * 6 + column;
                if column + 1 < 6 {
                    pairs.push((from, from + 1));
                }
                if row + 1 < 4 {
                    pairs.push((from, from + 6));
                }
            }
        }
        let mut edges = Vec::new();
        let mut constraints = Vec::new();
        for (edge_index, (from, to)) in pairs.into_iter().enumerate() {
            let rotation = mul(transpose(truth[to]), truth[from]);
            let points = source_points
                .iter()
                .map(|&(x, y)| {
                    let source_ray = camera_ray(x, y, &req);
                    let target_ray = mul_vec(transpose(rotation), source_ray);
                    let target = project_camera_ray(target_ray, &req).unwrap();
                    [x, y, target.0, target.1]
                })
                .collect();
            let mut edge = reprojection_fixture_edge(points);
            edge.from = from;
            edge.to = to;
            edges.push(edge);
            constraints.push(Constraint {
                from,
                to,
                rotation: mul(
                    rotation,
                    exp_rotation([0.0, (edge_index as f64 % 7.0 - 3.0) * 0.0015, 0.0]),
                ),
                weight: 1.0,
            });
        }
        let mut poses = truth
            .iter()
            .enumerate()
            .map(|(index, pose)| {
                if index == 0 {
                    *pose
                } else {
                    mul(
                        exp_rotation([
                            0.0,
                            (index as f64 % 5.0 - 2.0) * 0.003,
                            (index as f64 % 3.0 - 1.0) * 0.002,
                        ]),
                        *pose,
                    )
                }
            })
            .collect::<Vec<_>>();
        let anchor = poses[0];
        let valid_edges = edges.iter().collect::<Vec<_>>();
        let before = visual_pixel_huber_cost(&poses, &valid_edges, &req);
        let mut checkpoint = |_: &str| -> std::result::Result<(), String> { Ok(()) };
        let (reinitialized, optimized, before_l2, after_l2, iterations, converged, ..) =
            refine_visual_component_pixels(&mut poses, &constraints, &edges, &req, &mut checkpoint)
                .unwrap();
        let after = visual_pixel_huber_cost(&poses, &valid_edges, &req);
        assert_eq!(reinitialized, 23);
        assert_eq!(optimized, 23);
        assert!(
            converged,
            "joint bundle did not converge in {iterations} iterations"
        );
        assert!(iterations > 0 && iterations <= MAX_PIXEL_REFINEMENT_ITERATIONS);
        assert!(
            after < before * 0.01,
            "Huber cost {before} -> {after}; L2 {before_l2} -> {after_l2}"
        );
        assert_eq!(poses[0], anchor);
    }

    #[test]
    fn joint_pixel_bundle_converges_on_full_size_low_fov_384_grid() {
        let (rows, columns) = (16usize, 24usize);
        let mut req = grid_request(rows, columns);
        req.fx = 75_000.0;
        req.fy = 75_000.0;
        req.cx = 1919.5;
        req.cy = 1079.5;
        req.source_width = 3840;
        req.source_height = 2160;
        let truth = (0..rows)
            .flat_map(|row| {
                (0..columns).map(move |column| {
                    mul(
                        ry(column as f64 * 0.00048),
                        exp_rotation([row as f64 * 0.00031, 0.0, 0.0]),
                    )
                })
            })
            .collect::<Vec<_>>();
        let source_points = [
            (260.0, 240.0),
            (720.0, 360.0),
            (1260.0, 520.0),
            (1900.0, 300.0),
            (2580.0, 680.0),
            (3400.0, 940.0),
            (480.0, 1460.0),
            (1180.0, 1840.0),
        ];
        let mut edges = Vec::new();
        let mut constraints = Vec::new();
        for row in 0..rows {
            for column in 0..columns {
                let from = row * columns + column;
                for to in [
                    (column + 1 < columns).then_some(from + 1),
                    (row + 1 < rows).then_some(from + columns),
                ]
                .into_iter()
                .flatten()
                {
                    let rotation = mul(transpose(truth[to]), truth[from]);
                    let points = source_points
                        .iter()
                        .map(|&(x, y)| {
                            let source = camera_ray(x, y, &req);
                            let target_ray = mul_vec(transpose(rotation), source);
                            let target = project_camera_ray(target_ray, &req).unwrap();
                            [x, y, target.0, target.1]
                        })
                        .collect();
                    let mut edge = reprojection_fixture_edge(points);
                    edge.from = from;
                    edge.to = to;
                    edges.push(edge);
                    let perturb = exp_rotation([
                        ((from % 7) as f64 - 3.0) * 0.000006,
                        ((to % 5) as f64 - 2.0) * 0.000004,
                        ((from % 3) as f64 - 1.0) * 0.000003,
                    ]);
                    constraints.push(Constraint {
                        from,
                        to,
                        rotation: mul(rotation, perturb),
                        weight: 1.0,
                    });
                }
            }
        }
        assert_eq!(edges.len(), rows * (columns - 1) + columns * (rows - 1));
        let mut poses = truth
            .iter()
            .enumerate()
            .map(|(index, pose)| {
                if index == 0 {
                    *pose
                } else {
                    mul(
                        exp_rotation([0.00001, ((index % 5) as f64 - 2.0) * 0.000008, 0.000006]),
                        *pose,
                    )
                }
            })
            .collect::<Vec<_>>();
        let anchor = poses[0];
        let valid_edges = edges.iter().collect::<Vec<_>>();
        let before = visual_pixel_huber_cost(&poses, &valid_edges, &req);
        let mut checkpoint = |_: &str| -> std::result::Result<(), String> { Ok(()) };
        let (
            reinitialized,
            optimized,
            before_l2,
            after_l2,
            iterations,
            converged,
            pcg_max_iterations,
            pcg_max_residual,
            pcg_all_converged,
            pcg_failures,
            dense_fallbacks,
            accepted_linear_residual,
        ) = refine_visual_component_pixels(&mut poses, &constraints, &edges, &req, &mut checkpoint)
            .unwrap();
        let after = visual_pixel_huber_cost(&poses, &valid_edges, &req);
        assert_eq!(edges.len(), 728);
        assert_eq!(reinitialized, 383);
        assert_eq!(optimized, 383);
        assert!(
            converged,
            "384 grid failed to converge after {iterations} iterations; PCG {pcg_max_iterations}, relres {pcg_max_residual:e}, failures {pcg_failures}"
        );
        assert!(iterations > 0 && iterations <= MAX_PIXEL_REFINEMENT_ITERATIONS);
        assert!(
            pcg_all_converged,
            "PCG max relative residual {pcg_max_residual:e}"
        );
        assert!(dense_fallbacks < iterations.max(1));
        assert!(accepted_linear_residual <= 1e-3);
        assert!(
            after < before,
            "Huber cost {before} -> {after}, symmetric L2 {before_l2} -> {after_l2}"
        );
        assert_eq!(poses[0], anchor);
    }

    #[test]
    fn global_pixel_reprojection_does_not_overpenalize_optical_axis_roll() {
        let req = Request {
            rows: 1,
            columns: 2,
            tiles: vec![],
            fx: 75_000.,
            fy: 75_000.,
            cx: 1919.5,
            cy: 1079.5,
            source_width: 3840,
            source_height: 2160,
            output_dir: String::new(),
            placement_mode: String::new(),
            allow_nominal_grid_fallback: false,
            auto_grid_overlap: false,
            refine_grid_neighbors: false,
            seam_blend_mode: default_seam_blend_mode(),
            grid_horizontal_overlap: None,
            grid_vertical_overlap: None,
            neighbor_mode: default_neighbor_mode(),
            workers: default_workers(),
            parallel_matching: default_parallel_matching(),
            registration_megapixels: default_registration_megapixels(),
            feature_type: default_feature_type(),
            matcher_type: default_matcher_type(),
            include_diagnostic_correspondences: false,
            local_texture_warp: true,
        };
        let angle = 0.000659;
        let corners = [
            (0., 0.),
            (3839., 0.),
            (0., 2159.),
            (3839., 2159.),
            (960., 540.),
            (2880., 540.),
            (960., 1620.),
            (2880., 1620.),
        ];
        let points = corners
            .into_iter()
            .map(|(x, y)| [x, y, x, y])
            .collect::<Vec<_>>();
        let edge = reprojection_fixture_edge(points);
        let constraints = [Constraint {
            from: 0,
            to: 1,
            rotation: ID,
            weight: 1.0,
        }];
        let (rms, _, max, count, per_edge, complete) =
            global_reprojection_metrics(&[ID, rz(angle)], &constraints, &[edge], &req);
        let geodesic_focal_equivalent = angle * req.fx;
        assert!(geodesic_focal_equivalent > 12.0);
        assert!(complete);
        assert_eq!(count, 8);
        assert_eq!(per_edge.len(), 1);
        assert!(rms < 2.0, "pixel RMS {rms:.4}px, max {max:.4}px");
        assert!(max < 2.0, "pixel RMS {rms:.4}px, max {max:.4}px");
    }

    #[test]
    fn global_pixel_reprojection_fails_closed_for_behind_camera_points() {
        let req = Request {
            rows: 1,
            columns: 2,
            tiles: vec![],
            fx: 100.,
            fy: 100.,
            cx: 50.,
            cy: 50.,
            source_width: 100,
            source_height: 100,
            output_dir: String::new(),
            placement_mode: String::new(),
            allow_nominal_grid_fallback: false,
            auto_grid_overlap: false,
            refine_grid_neighbors: false,
            seam_blend_mode: default_seam_blend_mode(),
            grid_horizontal_overlap: None,
            grid_vertical_overlap: None,
            neighbor_mode: default_neighbor_mode(),
            workers: default_workers(),
            parallel_matching: default_parallel_matching(),
            registration_megapixels: default_registration_megapixels(),
            feature_type: default_feature_type(),
            matcher_type: default_matcher_type(),
            include_diagnostic_correspondences: false,
            local_texture_warp: true,
        };
        let points = (0..8).map(|_| [50., 50., 50., 50.]).collect();
        let edge = reprojection_fixture_edge(points);
        let constraints = [Constraint {
            from: 0,
            to: 1,
            rotation: ID,
            weight: 1.0,
        }];
        let (rms, _, _, count, _, complete) = global_reprojection_metrics(
            &[ID, ry(std::f64::consts::PI)],
            &constraints,
            &[edge],
            &req,
        );
        assert!(!complete);
        assert_eq!(count, 0);
        assert!(!rms.is_finite());
    }

    #[test]
    fn synthetic_spherical_scene_recovers_nine_camera_poses_from_rays() {
        let k = [120., 0., 100., 0., 118., 80., 0., 0., 1.];
        let mut truth = Vec::new();
        for row in 0..3 {
            for column in 0..3 {
                // Nine rectilinear cameras view one deterministic textured sphere.
                truth.push(mul(
                    ry((column as f64 - 1.) * 0.19),
                    rz((row as f64 - 1.) * 0.07),
                ));
            }
        }
        let mut edges = Vec::new();
        for row in 0..3 {
            for column in 0..3 {
                let from = row * 3 + column;
                for to in [
                    if column < 2 { Some(from + 1) } else { None },
                    if row < 2 { Some(from + 3) } else { None },
                ]
                .into_iter()
                .flatten()
                {
                    let h = homography(truth[from], truth[to], k);
                    let recovered = calibrated_rotation(h, 120., 118., 100., 80.).unwrap();
                    // Deterministic sphere texture rays must map to the same world direction.
                    for (yaw, pitch) in [(-0.1_f64, -0.05_f64), (0., 0.), (0.13, 0.08)] {
                        let direction = [
                            yaw.sin() * pitch.cos(),
                            pitch.sin(),
                            yaw.cos() * pitch.cos(),
                        ];
                        let a = project_pixel(truth[from], direction, k).unwrap();
                        let b = project_pixel(truth[to], direction, k).unwrap();
                        let q = mul_vec(recovered, [(a.0 - k[2]) / k[0], -(a.1 - k[5]) / k[4], 1.]);
                        assert!((q[0] / q[2] - (b.0 - k[2]) / k[0]).abs() < 1e-8);
                        assert!((q[1] / q[2] + (b.1 - k[5]) / k[4]).abs() < 1e-8);
                    }
                    edges.push(Constraint {
                        from,
                        to,
                        rotation: transpose(recovered),
                        weight: 1.,
                    });
                }
            }
        }
        let got = solve_orientations(9, &edges).unwrap();
        for i in 0..9 {
            let relative = mul(transpose(got[0]), got[i]);
            let expected = mul(transpose(truth[0]), truth[i]);
            let error = log_rotation(mul(transpose(expected), relative));
            assert!(error.iter().map(|v| v * v).sum::<f64>().sqrt() < 1e-5);
        }
    }
}
