//! Bounded source-image-plane displacement fields for correcting local
//! parallax after global spherical camera alignment.
use serde::{Deserialize, Serialize};

pub const SOURCE_WARP_COLUMNS: usize = 3;
pub const SOURCE_WARP_ROWS: usize = 3;
pub const SOURCE_WARP_MAX_DISPLACEMENT_PX: f64 = 64.0;
pub const SOURCE_WARP_MAX_LOCAL_STRAIN: f64 = 0.10;
pub const SOURCE_WARP_INVERSE_ITERATIONS: usize = 8;
pub const SOURCE_WARP_SMOOTHNESS_WEIGHT: f64 = 0.025;
pub const SOURCE_WARP_GRID_LEVELS: &[(usize, usize)] = &[(3, 3), (5, 5), (9, 9)];
const INVERSE_TOLERANCE_PX: f64 = 0.02;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SourcePlaneWarp {
    pub columns: usize,
    pub rows: usize,
    /// Row-major `(dx, dy)` displacements in original source pixels.
    pub offsets: Vec<[f64; 2]>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SourceWarpPadding {
    pub left: u32,
    pub top: u32,
    pub right: u32,
    pub bottom: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct SourceWarpSample {
    pub x: f64,
    pub y: f64,
    pub dx: f64,
    pub dy: f64,
    pub weight: f64,
}

#[derive(Clone, Debug, Default)]
pub struct SourceWarpFitDiagnostics {
    pub support_count: usize,
    pub occupied_cells: usize,
    pub supported_control_knots: usize,
    pub sample_rms_before_px: Option<f64>,
    pub sample_rms_after_px: Option<f64>,
    pub max_offset_px: f64,
    pub max_strain: f64,
    pub supported: bool,
    /// This level's field is present in the final coarse-to-fine result.
    pub accepted: bool,
}

impl SourcePlaneWarp {
    pub fn zero() -> Self {
        Self {
            columns: SOURCE_WARP_COLUMNS,
            rows: SOURCE_WARP_ROWS,
            offsets: vec![[0.0; 2]; SOURCE_WARP_COLUMNS * SOURCE_WARP_ROWS],
        }
    }

    pub fn is_zero(&self) -> bool {
        self.offsets
            .iter()
            .all(|offset| offset[0] == 0.0 && offset[1] == 0.0)
    }
}

pub fn validate_source_plane_warp(
    warp: &SourcePlaneWarp,
    width: u32,
    height: u32,
) -> Result<(), String> {
    if !matches!((warp.columns, warp.rows), (3, 3) | (5, 5) | (9, 9))
        || warp.offsets.len() != warp.columns * warp.rows
    {
        return Err(
            "sourcePlaneWarp must be a 3x3, 5x5, or 9x9 row-major displacement grid".into(),
        );
    }
    if width < 2 || height < 2 {
        return Err("sourcePlaneWarp requires source dimensions of at least 2x2".into());
    }
    for (index, offset) in warp.offsets.iter().enumerate() {
        if !offset.iter().all(|value| value.is_finite()) {
            return Err(format!("sourcePlaneWarp offset {index} is not finite"));
        }
        if offset[0].hypot(offset[1]) > SOURCE_WARP_MAX_DISPLACEMENT_PX + 1e-9 {
            return Err(format!(
                "sourcePlaneWarp offset {index} exceeds {:.1}px Euclidean magnitude",
                SOURCE_WARP_MAX_DISPLACEMENT_PX
            ));
        }
    }
    let dx = f64::from(width - 1) / (warp.columns - 1) as f64;
    let dy = f64::from(height - 1) / (warp.rows - 1) as f64;
    for row in 0..warp.rows - 1 {
        for column in 0..warp.columns - 1 {
            for (u, v) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                let jacobian = offset_jacobian(warp, dx, dy, column, row, u, v);
                let norm = spectral_norm_2x2(jacobian);
                if !norm.is_finite() || norm > SOURCE_WARP_MAX_LOCAL_STRAIN + 1e-9 {
                    return Err(format!(
                        "sourcePlaneWarp local strain {:.4} exceeds {:.3}",
                        norm, SOURCE_WARP_MAX_LOCAL_STRAIN
                    ));
                }
            }
        }
    }
    Ok(())
}

pub fn source_to_corrected(
    warp: &SourcePlaneWarp,
    width: u32,
    height: u32,
    x: f64,
    y: f64,
) -> Option<(f64, f64)> {
    if !inside(width, height, x, y) || !has_supported_grid(warp, width, height) {
        return None;
    }
    let (dx, dy) = interpolate_offset(warp, width, height, x, y)?;
    Some((x + dx, y + dy))
}

/// Invert the forward source-pixel map using the renderer's bounded fixed-point
/// solve: `original = idealCorrected - offset(original)`.
pub fn corrected_to_source(
    warp: &SourcePlaneWarp,
    width: u32,
    height: u32,
    corrected_x: f64,
    corrected_y: f64,
) -> Option<(f64, f64)> {
    if !corrected_x.is_finite()
        || !corrected_y.is_finite()
        || !has_supported_grid(warp, width, height)
    {
        return None;
    }
    // Corrected boundary coordinates may lie outside the source image. Seed
    // from the nearest source border, then solve and reject only if the source
    // coordinate falls outside the padded image's actual source domain.
    let mut x = corrected_x.clamp(0.0, f64::from(width - 1));
    let mut y = corrected_y.clamp(0.0, f64::from(height - 1));
    for _ in 0..SOURCE_WARP_INVERSE_ITERATIONS {
        let lookup_x = x.clamp(0.0, f64::from(width - 1));
        let lookup_y = y.clamp(0.0, f64::from(height - 1));
        let (dx, dy) = interpolate_offset(warp, width, height, lookup_x, lookup_y)?;
        let next_x = corrected_x - dx;
        let next_y = corrected_y - dy;
        let change = (next_x - x).hypot(next_y - y);
        x = next_x;
        y = next_y;
        if change <= 0.002 {
            break;
        }
    }
    if !inside(width, height, x, y) {
        return None;
    }
    let (round_trip_x, round_trip_y) = source_to_corrected(warp, width, height, x, y)?;
    ((round_trip_x - corrected_x).hypot(round_trip_y - corrected_y) <= INVERSE_TOLERANCE_PX)
        .then_some((x, y))
}

fn has_supported_grid(warp: &SourcePlaneWarp, width: u32, height: u32) -> bool {
    width >= 2
        && height >= 2
        && matches!((warp.columns, warp.rows), (3, 3) | (5, 5) | (9, 9))
        && warp.offsets.len() == warp.columns * warp.rows
}

pub fn source_warp_padding(warp: Option<&SourcePlaneWarp>) -> SourceWarpPadding {
    let Some(warp) = warp else {
        return SourceWarpPadding::default();
    };
    if warp
        .offsets
        .iter()
        .flatten()
        .any(|value| !value.is_finite())
    {
        return SourceWarpPadding::default();
    }
    let min_x = warp
        .offsets
        .iter()
        .map(|offset| offset[0])
        .fold(0.0, f64::min);
    let max_x = warp
        .offsets
        .iter()
        .map(|offset| offset[0])
        .fold(0.0, f64::max);
    let min_y = warp
        .offsets
        .iter()
        .map(|offset| offset[1])
        .fold(0.0, f64::min);
    let max_y = warp
        .offsets
        .iter()
        .map(|offset| offset[1])
        .fold(0.0, f64::max);
    SourceWarpPadding {
        left: (-min_x).max(0.0).ceil() as u32,
        top: (-min_y).max(0.0).ceil() as u32,
        right: max_x.max(0.0).ceil() as u32,
        bottom: max_y.max(0.0).ceil() as u32,
    }
}

/// Robustly fit one 3x3 displacement field to already pose-compensated
/// source-pixel offsets. A component anchor is represented by an exact zero
/// field; weakly supported tiles return `None` and remain unwarped.
pub fn fit_source_plane_warp(
    width: u32,
    height: u32,
    samples: &[SourceWarpSample],
    anchor: bool,
) -> (Option<SourcePlaneWarp>, SourceWarpFitDiagnostics) {
    fit_source_plane_warp_with_smoothness(
        width,
        height,
        samples,
        anchor,
        SOURCE_WARP_SMOOTHNESS_WEIGHT,
    )
}

pub fn fit_source_plane_warp_with_smoothness(
    width: u32,
    height: u32,
    samples: &[SourceWarpSample],
    anchor: bool,
    smoothness_weight: f64,
) -> (Option<SourcePlaneWarp>, SourceWarpFitDiagnostics) {
    if !smoothness_weight.is_finite() || smoothness_weight < 0.0 {
        return (None, SourceWarpFitDiagnostics::default());
    }
    let mut diagnostics = SourceWarpFitDiagnostics {
        support_count: samples.len(),
        ..Default::default()
    };
    if width < 2 || height < 2 {
        return (None, diagnostics);
    }
    if anchor {
        diagnostics.supported = true;
        diagnostics.accepted = true;
        return (Some(SourcePlaneWarp::zero()), diagnostics);
    }
    let samples = samples
        .iter()
        .copied()
        .filter(|sample| {
            sample.x.is_finite()
                && sample.y.is_finite()
                && sample.dx.is_finite()
                && sample.dy.is_finite()
                && sample.weight.is_finite()
                && sample.weight > 0.0
                && sample.x >= 0.0
                && sample.y >= 0.0
                && sample.x <= f64::from(width - 1)
                && sample.y <= f64::from(height - 1)
        })
        .collect::<Vec<_>>();
    if samples.len() < 32 {
        diagnostics.support_count = samples.len();
        return (None, diagnostics);
    }
    let occupied = samples
        .iter()
        .map(|sample| {
            let col = (sample.x / f64::from(width - 1) * 2.0).floor().min(1.0) as usize;
            let row = (sample.y / f64::from(height - 1) * 2.0).floor().min(1.0) as usize;
            row * 2 + col
        })
        .collect::<std::collections::HashSet<_>>();
    diagnostics.occupied_cells = occupied.len();
    if occupied.len() < 2 {
        diagnostics.support_count = samples.len();
        return (None, diagnostics);
    }
    let mut knot_support = (0..SOURCE_WARP_COLUMNS * SOURCE_WARP_ROWS)
        .map(|_| std::collections::HashSet::<(i32, i32)>::new())
        .collect::<Vec<_>>();
    for sample in &samples {
        let (indices, weights) = interpolation_weights(sample.x, sample.y, width, height);
        for index in 0..4 {
            if weights[index] > 0.05 {
                knot_support[indices[index]]
                    .insert((sample.x.round() as i32, sample.y.round() as i32));
            }
        }
    }
    let supported_knots = std::array::from_fn(|index| knot_support[index].len() >= 4);
    diagnostics.supported_control_knots = supported_knots.iter().filter(|&&value| value).count();
    if diagnostics.supported_control_knots < 4 {
        return (None, diagnostics);
    }
    diagnostics.sample_rms_before_px = Some(
        (samples
            .iter()
            .map(|sample| sample.weight * (sample.dx * sample.dx + sample.dy * sample.dy))
            .sum::<f64>()
            / samples.iter().map(|sample| sample.weight).sum::<f64>())
        .sqrt(),
    );
    let mut offsets = [[0.0; 2]; SOURCE_WARP_COLUMNS * SOURCE_WARP_ROWS];
    for _ in 0..5 {
        let (normal, rhs_x, rhs_y) = assemble_tile_normal(
            &samples,
            width,
            height,
            &offsets,
            &supported_knots,
            smoothness_weight,
        );
        let Some(solution_x) = solve_small_spd(&normal, &rhs_x) else {
            return (None, diagnostics);
        };
        let Some(solution_y) = solve_small_spd(&normal, &rhs_y) else {
            return (None, diagnostics);
        };
        for knot in 0..offsets.len() {
            offsets[knot] = if supported_knots[knot] {
                [solution_x[knot], solution_y[knot]]
            } else {
                [0.0, 0.0]
            };
        }
    }
    let mut warp = SourcePlaneWarp {
        columns: SOURCE_WARP_COLUMNS,
        rows: SOURCE_WARP_ROWS,
        offsets: offsets.to_vec(),
    };
    let (max_offset, max_strain) = warp_limits(&warp, width, height);
    let scale = (SOURCE_WARP_MAX_DISPLACEMENT_PX / max_offset.max(1e-12))
        .min(SOURCE_WARP_MAX_LOCAL_STRAIN / max_strain.max(1e-12))
        .min(1.0);
    if scale < 1.0 {
        for offset in &mut warp.offsets {
            offset[0] *= scale;
            offset[1] *= scale;
        }
    }
    if validate_source_plane_warp(&warp, width, height).is_err() {
        return (None, diagnostics);
    }
    let total_weight = samples.iter().map(|sample| sample.weight).sum::<f64>();
    diagnostics.sample_rms_after_px = Some(
        (samples
            .iter()
            .map(|sample| {
                let (dx, dy) = interpolate_offset(&warp, width, height, sample.x, sample.y)
                    .unwrap_or((0.0, 0.0));
                let rx = dx - sample.dx;
                let ry = dy - sample.dy;
                sample.weight * (rx * rx + ry * ry)
            })
            .sum::<f64>()
            / total_weight)
            .sqrt(),
    );
    let (max_offset, max_strain) = warp_limits(&warp, width, height);
    diagnostics.max_offset_px = max_offset;
    diagnostics.max_strain = max_strain;
    diagnostics.supported = true;
    diagnostics.accepted = true;
    (Some(warp), diagnostics)
}

/// Fit a coarse field first, then add supported residual fields on finer grids.
/// A finer level is retained only when it lowers weighted error on the same
/// correspondence set and the combined field satisfies displacement/strain limits.
pub fn fit_source_plane_warp_multilevel(
    width: u32,
    height: u32,
    samples: &[SourceWarpSample],
    anchor: bool,
    smoothness_weight: f64,
) -> (Option<SourcePlaneWarp>, Vec<SourceWarpFitDiagnostics>) {
    let (base_warp, base_diag) =
        fit_source_plane_warp_with_smoothness(width, height, samples, anchor, smoothness_weight);
    let Some(mut combined) = base_warp else {
        return (None, vec![base_diag]);
    };
    let mut diagnostics = vec![base_diag];
    if anchor {
        return (Some(combined), diagnostics);
    }
    let mut best_cost = weighted_sample_cost(&combined, width, height, samples);
    for &(columns, rows) in &SOURCE_WARP_GRID_LEVELS[1..] {
        let residuals = samples
            .iter()
            .filter_map(|sample| {
                let (base_x, base_y) =
                    interpolate_offset(&combined, width, height, sample.x, sample.y)?;
                Some(SourceWarpSample {
                    dx: sample.dx - base_x,
                    dy: sample.dy - base_y,
                    ..*sample
                })
            })
            .collect::<Vec<_>>();
        let (Some(increment), mut level_diag) =
            fit_residual_grid(width, height, &residuals, columns, rows, smoothness_weight)
        else {
            diagnostics.push(SourceWarpFitDiagnostics {
                support_count: residuals.len(),
                ..Default::default()
            });
            continue;
        };
        let candidate = combine_grid_fields(&combined, &increment, width, height);
        if validate_source_plane_warp(&candidate, width, height).is_err() {
            diagnostics.push(level_diag);
            continue;
        }
        let candidate_cost = weighted_sample_cost(&candidate, width, height, samples);
        if candidate_cost + 1e-6 < best_cost {
            let (max_offset_px, max_strain) = warp_limits(&candidate, width, height);
            level_diag.max_offset_px = max_offset_px;
            level_diag.max_strain = max_strain;
            level_diag.sample_rms_before_px = Some(best_cost.sqrt());
            level_diag.sample_rms_after_px = Some(candidate_cost.sqrt());
            level_diag.accepted = true;
            combined = candidate;
            best_cost = candidate_cost;
        }
        diagnostics.push(level_diag);
    }
    (Some(combined), diagnostics)
}

fn weighted_sample_cost(
    warp: &SourcePlaneWarp,
    width: u32,
    height: u32,
    samples: &[SourceWarpSample],
) -> f64 {
    let (sum, weight) = samples.iter().fold((0.0, 0.0), |(sum, total), sample| {
        let Some((dx, dy)) = interpolate_offset(warp, width, height, sample.x, sample.y) else {
            return (sum, total);
        };
        (
            sum + sample.weight * ((dx - sample.dx).powi(2) + (dy - sample.dy).powi(2)),
            total + sample.weight,
        )
    });
    if weight > 0.0 {
        sum / weight
    } else {
        f64::INFINITY
    }
}

fn combine_grid_fields(
    coarse: &SourcePlaneWarp,
    increment: &SourcePlaneWarp,
    width: u32,
    height: u32,
) -> SourcePlaneWarp {
    let offsets = (0..increment.rows)
        .flat_map(|row| {
            (0..increment.columns).map(move |column| {
                let x = column as f64 / (increment.columns - 1) as f64 * f64::from(width - 1);
                let y = row as f64 / (increment.rows - 1) as f64 * f64::from(height - 1);
                let base = interpolate_offset(coarse, width, height, x, y).unwrap_or((0.0, 0.0));
                let add = increment.offsets[row * increment.columns + column];
                [base.0 + add[0], base.1 + add[1]]
            })
        })
        .collect();
    SourcePlaneWarp {
        columns: increment.columns,
        rows: increment.rows,
        offsets,
    }
}

pub fn resample_source_plane_warp(
    warp: &SourcePlaneWarp,
    width: u32,
    height: u32,
    columns: usize,
    rows: usize,
) -> SourcePlaneWarp {
    let offsets = (0..rows)
        .flat_map(|row| {
            (0..columns).map(move |column| {
                let x = column as f64 / (columns - 1) as f64 * f64::from(width - 1);
                let y = row as f64 / (rows - 1) as f64 * f64::from(height - 1);
                let (dx, dy) = interpolate_offset(warp, width, height, x, y).unwrap_or((0.0, 0.0));
                [dx, dy]
            })
        })
        .collect();
    SourcePlaneWarp {
        columns,
        rows,
        offsets,
    }
}

fn fit_residual_grid(
    width: u32,
    height: u32,
    samples: &[SourceWarpSample],
    columns: usize,
    rows: usize,
    smoothness_weight: f64,
) -> (Option<SourcePlaneWarp>, SourceWarpFitDiagnostics) {
    let mut diag = SourceWarpFitDiagnostics {
        support_count: samples.len(),
        ..Default::default()
    };
    if samples.len() < 32 || !smoothness_weight.is_finite() || smoothness_weight < 0.0 {
        return (None, diag);
    }
    let mut support = vec![std::collections::HashSet::<(i32, i32)>::new(); columns * rows];
    let mut quadrants = std::collections::HashSet::new();
    for sample in samples {
        let (indices, basis) = grid_basis(sample.x, sample.y, width, height, columns, rows);
        let qx = (sample.x / f64::from(width - 1) * 2.0).floor().min(1.0) as usize;
        let qy = (sample.y / f64::from(height - 1) * 2.0).floor().min(1.0) as usize;
        quadrants.insert(qy * 2 + qx);
        for i in 0..4 {
            if basis[i] > 0.05 {
                support[indices[i]].insert((sample.x.round() as i32, sample.y.round() as i32));
            }
        }
    }
    diag.occupied_cells = quadrants.len();
    let active = support
        .iter()
        .map(|points| points.len() >= 4)
        .collect::<Vec<_>>();
    diag.supported_control_knots = active.iter().filter(|&&v| v).count();
    if quadrants.len() < 2 || diag.supported_control_knots < 4 {
        return (None, diag);
    }
    let n = columns * rows;
    let mut offsets = vec![[0.0; 2]; n];
    for _ in 0..5 {
        let mut matrix = vec![vec![0.0; n]; n];
        let mut rhs = [vec![0.0; n], vec![0.0; n]];
        for sample in samples {
            let (indices, basis) = grid_basis(sample.x, sample.y, width, height, columns, rows);
            let predicted = [0, 1].map(|axis| {
                (0..4)
                    .map(|i| basis[i] * offsets[indices[i]][axis])
                    .sum::<f64>()
            });
            let residual = (predicted[0] - sample.dx).hypot(predicted[1] - sample.dy);
            let weight = sample.weight * if residual <= 3.0 { 1.0 } else { 3.0 / residual };
            for i in 0..4 {
                for axis in 0..2 {
                    rhs[axis][indices[i]] += weight * basis[i] * [sample.dx, sample.dy][axis];
                }
                for j in 0..4 {
                    matrix[indices[i]][indices[j]] += weight * basis[i] * basis[j];
                }
            }
        }
        for k in 0..n {
            matrix[k][k] += if active[k] { 0.025 } else { 1e9 };
        }
        for row in 0..rows {
            for col in 0..columns {
                let here = row * columns + col;
                for other in [
                    (col + 1 < columns).then_some(here + 1),
                    (row + 1 < rows).then_some(here + columns),
                ]
                .into_iter()
                .flatten()
                {
                    if active[here] && active[other] {
                        matrix[here][here] += smoothness_weight;
                        matrix[other][other] += smoothness_weight;
                        matrix[here][other] -= smoothness_weight;
                        matrix[other][here] -= smoothness_weight;
                    }
                }
            }
        }
        let Some(sx) = solve_dense_spd(matrix.clone(), &rhs[0]) else {
            return (None, diag);
        };
        let Some(sy) = solve_dense_spd(matrix, &rhs[1]) else {
            return (None, diag);
        };
        for k in 0..n {
            offsets[k] = if active[k] {
                [sx[k], sy[k]]
            } else {
                [0.0, 0.0]
            };
        }
    }
    let mut warp = SourcePlaneWarp {
        columns,
        rows,
        offsets,
    };
    let (max_offset, max_strain) = warp_limits(&warp, width, height);
    let scale = (SOURCE_WARP_MAX_DISPLACEMENT_PX / max_offset.max(1e-12))
        .min(SOURCE_WARP_MAX_LOCAL_STRAIN / max_strain.max(1e-12))
        .min(1.0);
    for offset in &mut warp.offsets {
        offset[0] *= scale;
        offset[1] *= scale;
    }
    if validate_source_plane_warp(&warp, width, height).is_err() {
        return (None, diag);
    }
    diag.max_offset_px = warp_limits(&warp, width, height).0;
    diag.max_strain = warp_limits(&warp, width, height).1;
    diag.supported = true;
    (Some(warp), diag)
}

fn grid_basis(
    x: f64,
    y: f64,
    width: u32,
    height: u32,
    columns: usize,
    rows: usize,
) -> ([usize; 4], [f64; 4]) {
    let gx = x / f64::from(width - 1) * (columns - 1) as f64;
    let gy = y / f64::from(height - 1) * (rows - 1) as f64;
    let col = (gx.floor() as usize).min(columns - 2);
    let row = (gy.floor() as usize).min(rows - 2);
    let u = (gx - col as f64).clamp(0.0, 1.0);
    let v = (gy - row as f64).clamp(0.0, 1.0);
    (
        [
            row * columns + col,
            row * columns + col + 1,
            (row + 1) * columns + col,
            (row + 1) * columns + col + 1,
        ],
        [(1.0 - u) * (1.0 - v), u * (1.0 - v), (1.0 - u) * v, u * v],
    )
}

fn solve_dense_spd(mut matrix: Vec<Vec<f64>>, rhs: &[f64]) -> Option<Vec<f64>> {
    let n = rhs.len();
    for i in 0..n {
        for j in 0..=i {
            let mut v = matrix[i][j];
            for k in 0..j {
                v -= matrix[i][k] * matrix[j][k];
            }
            if i == j {
                if !v.is_finite() || v <= 1e-12 {
                    return None;
                }
                matrix[i][j] = v.sqrt();
            } else {
                matrix[i][j] = v / matrix[j][j];
            }
        }
    }
    let mut y = vec![0.0; n];
    for i in 0..n {
        y[i] = (rhs[i] - (0..i).map(|j| matrix[i][j] * y[j]).sum::<f64>()) / matrix[i][i];
    }
    let mut x = vec![0.0; n];
    for i in (0..n).rev() {
        x[i] = (y[i] - (i + 1..n).map(|j| matrix[j][i] * x[j]).sum::<f64>()) / matrix[i][i];
    }
    x.iter().all(|v| v.is_finite()).then_some(x)
}

fn assemble_tile_normal(
    samples: &[SourceWarpSample],
    width: u32,
    height: u32,
    current: &[[f64; 2]; SOURCE_WARP_COLUMNS * SOURCE_WARP_ROWS],
    supported_knots: &[bool; SOURCE_WARP_COLUMNS * SOURCE_WARP_ROWS],
    smoothness_weight: f64,
) -> ([[f64; 9]; 9], [f64; 9], [f64; 9]) {
    let mut matrix = [[0.0; 9]; 9];
    let mut rhs_x = [0.0; 9];
    let mut rhs_y = [0.0; 9];
    for sample in samples {
        let (indices, weights) = interpolation_weights(sample.x, sample.y, width, height);
        let predicted_x = (0..4)
            .map(|i| weights[i] * current[indices[i]][0])
            .sum::<f64>();
        let predicted_y = (0..4)
            .map(|i| weights[i] * current[indices[i]][1])
            .sum::<f64>();
        let residual = (predicted_x - sample.dx).hypot(predicted_y - sample.dy);
        let robust_weight = if residual <= 3.0 { 1.0 } else { 3.0 / residual };
        let weight = sample.weight * robust_weight;
        for i in 0..4 {
            rhs_x[indices[i]] += weight * weights[i] * sample.dx;
            rhs_y[indices[i]] += weight * weights[i] * sample.dy;
            for j in 0..4 {
                matrix[indices[i]][indices[j]] += weight * weights[i] * weights[j];
            }
        }
    }
    // A weak zero prior controls poorly sampled knots; edge-difference terms
    // suppress unsupported high-frequency deformation without forcing a plane.
    for knot in 0..9 {
        matrix[knot][knot] += if supported_knots[knot] { 0.025 } else { 1e9 };
    }
    for row in 0..3 {
        for column in 0..3 {
            let here = row * 3 + column;
            for other in [
                (column + 1 < 3).then_some(here + 1),
                (row + 1 < 3).then_some(here + 3),
            ]
            .into_iter()
            .flatten()
            {
                matrix[here][here] += smoothness_weight;
                matrix[other][other] += smoothness_weight;
                matrix[here][other] -= smoothness_weight;
                matrix[other][here] -= smoothness_weight;
            }
        }
    }
    (matrix, rhs_x, rhs_y)
}

fn interpolation_weights(x: f64, y: f64, width: u32, height: u32) -> ([usize; 4], [f64; 4]) {
    let gx = x / f64::from(width - 1) * 2.0;
    let gy = y / f64::from(height - 1) * 2.0;
    let column = (gx.floor() as usize).min(1);
    let row = (gy.floor() as usize).min(1);
    let u = (gx - column as f64).clamp(0.0, 1.0);
    let v = (gy - row as f64).clamp(0.0, 1.0);
    let indices = [
        row * 3 + column,
        row * 3 + column + 1,
        (row + 1) * 3 + column,
        (row + 1) * 3 + column + 1,
    ];
    let weights = [(1.0 - u) * (1.0 - v), u * (1.0 - v), (1.0 - u) * v, u * v];
    (indices, weights)
}

fn solve_small_spd(matrix: &[[f64; 9]; 9], rhs: &[f64; 9]) -> Option<[f64; 9]> {
    let mut lower = [[0.0; 9]; 9];
    for row in 0..9 {
        for col in 0..=row {
            let mut value = matrix[row][col];
            for k in 0..col {
                value -= lower[row][k] * lower[col][k];
            }
            if row == col {
                if !value.is_finite() || value <= 1e-12 {
                    return None;
                }
                lower[row][col] = value.sqrt();
            } else {
                lower[row][col] = value / lower[col][col];
            }
        }
    }
    let mut y = [0.0; 9];
    for row in 0..9 {
        y[row] = (rhs[row] - (0..row).map(|col| lower[row][col] * y[col]).sum::<f64>())
            / lower[row][row];
    }
    let mut x = [0.0; 9];
    for row in (0..9).rev() {
        x[row] = (y[row]
            - (row + 1..9)
                .map(|col| lower[col][row] * x[col])
                .sum::<f64>())
            / lower[row][row];
    }
    x.iter().all(|value| value.is_finite()).then_some(x)
}

fn warp_limits(warp: &SourcePlaneWarp, width: u32, height: u32) -> (f64, f64) {
    let max_offset = warp
        .offsets
        .iter()
        .map(|offset| offset[0].hypot(offset[1]))
        .fold(0.0_f64, f64::max);
    let dx = f64::from(width - 1) / (warp.columns - 1) as f64;
    let dy = f64::from(height - 1) / (warp.rows - 1) as f64;
    let max_strain = (0..warp.rows - 1)
        .flat_map(|row| (0..warp.columns - 1).map(move |column| (row, column)))
        .flat_map(|(row, column)| {
            [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)].map(move |(u, v)| (row, column, u, v))
        })
        .map(|(row, column, u, v)| {
            spectral_norm_2x2(offset_jacobian(warp, dx, dy, column, row, u, v))
        })
        .fold(0.0_f64, f64::max);
    (max_offset, max_strain)
}

pub fn source_plane_warp_limits(warp: &SourcePlaneWarp, width: u32, height: u32) -> (f64, f64) {
    warp_limits(warp, width, height)
}

fn inside(width: u32, height: u32, x: f64, y: f64) -> bool {
    x.is_finite()
        && y.is_finite()
        && x >= 0.0
        && y >= 0.0
        && x <= f64::from(width.saturating_sub(1))
        && y <= f64::from(height.saturating_sub(1))
}

fn interpolate_offset(
    warp: &SourcePlaneWarp,
    width: u32,
    height: u32,
    x: f64,
    y: f64,
) -> Option<(f64, f64)> {
    if !inside(width, height, x, y)
        || warp.columns < 2
        || warp.rows < 2
        || warp.offsets.len() != warp.columns * warp.rows
    {
        return None;
    }
    let gx = x / f64::from(width - 1) * (warp.columns - 1) as f64;
    let gy = y / f64::from(height - 1) * (warp.rows - 1) as f64;
    let column = (gx.floor() as usize).min(warp.columns - 2);
    let row = (gy.floor() as usize).min(warp.rows - 2);
    let u = (gx - column as f64).clamp(0.0, 1.0);
    let v = (gy - row as f64).clamp(0.0, 1.0);
    let a = warp.offsets[row * warp.columns + column];
    let b = warp.offsets[row * warp.columns + column + 1];
    let c = warp.offsets[(row + 1) * warp.columns + column];
    let d = warp.offsets[(row + 1) * warp.columns + column + 1];
    let mut result = [0.0; 2];
    for axis in 0..2 {
        result[axis] = (1.0 - v) * ((1.0 - u) * a[axis] + u * b[axis])
            + v * ((1.0 - u) * c[axis] + u * d[axis]);
    }
    Some((result[0], result[1]))
}

fn offset_jacobian(
    warp: &SourcePlaneWarp,
    dx: f64,
    dy: f64,
    column: usize,
    row: usize,
    u: f64,
    v: f64,
) -> [f64; 4] {
    let a = warp.offsets[row * warp.columns + column];
    let b = warp.offsets[row * warp.columns + column + 1];
    let c = warp.offsets[(row + 1) * warp.columns + column];
    let d = warp.offsets[(row + 1) * warp.columns + column + 1];
    let du_x = ((1.0 - v) * (b[0] - a[0]) + v * (d[0] - c[0])) / dx;
    let dv_x = ((1.0 - u) * (c[0] - a[0]) + u * (d[0] - b[0])) / dy;
    let du_y = ((1.0 - v) * (b[1] - a[1]) + v * (d[1] - c[1])) / dx;
    let dv_y = ((1.0 - u) * (c[1] - a[1]) + u * (d[1] - b[1])) / dy;
    [du_x, dv_x, du_y, dv_y]
}

fn spectral_norm_2x2([a, b, c, d]: [f64; 4]) -> f64 {
    let trace = a * a + b * b + c * c + d * d;
    let determinant = (a * d - b * c).powi(2);
    let discriminant = (trace * trace - 4.0 * determinant).max(0.0).sqrt();
    ((trace + discriminant) * 0.5).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_field_is_legacy_equivalent_and_has_no_padding() {
        let warp = SourcePlaneWarp::zero();
        validate_source_plane_warp(&warp, 3840, 2160).unwrap();
        assert_eq!(
            source_to_corrected(&warp, 3840, 2160, 17.0, 203.0),
            Some((17.0, 203.0))
        );
        assert_eq!(
            corrected_to_source(&warp, 3840, 2160, 17.0, 203.0),
            Some((17.0, 203.0))
        );
        assert_eq!(
            source_warp_padding(Some(&warp)),
            SourceWarpPadding::default()
        );
    }

    #[test]
    fn bounded_translation_round_trips_and_computes_canvas_padding() {
        let warp = SourcePlaneWarp {
            columns: 3,
            rows: 3,
            offsets: vec![[4.0, -3.0]; 9],
        };
        validate_source_plane_warp(&warp, 1000, 800).unwrap();
        assert_eq!(
            source_warp_padding(Some(&warp)),
            SourceWarpPadding {
                left: 0,
                top: 3,
                right: 4,
                bottom: 0
            }
        );
        let corrected = source_to_corrected(&warp, 1000, 800, 100.0, 120.0).unwrap();
        assert_eq!(corrected, (104.0, 117.0));
        let source = corrected_to_source(&warp, 1000, 800, corrected.0, corrected.1).unwrap();
        assert!((source.0 - 100.0).abs() < INVERSE_TOLERANCE_PX);
        assert!((source.1 - 120.0).abs() < INVERSE_TOLERANCE_PX);
    }

    #[test]
    fn inverse_allows_temporary_iterate_outside_near_warped_border() {
        let warp = SourcePlaneWarp {
            columns: 3,
            rows: 3,
            offsets: vec![
                [1.0, 0.0],
                [3.5, 0.0],
                [6.0, 0.0],
                [1.0, 0.0],
                [3.5, 0.0],
                [6.0, 0.0],
                [1.0, 0.0],
                [3.5, 0.0],
                [6.0, 0.0],
            ],
        };
        validate_source_plane_warp(&warp, 101, 81).unwrap();
        let ideal = source_to_corrected(&warp, 101, 81, 0.01, 10.0).unwrap();
        assert!(ideal.0 > 1.0);
        let recovered = corrected_to_source(&warp, 101, 81, ideal.0, ideal.1)
            .expect("a temporary out-of-bounds iterate is not a failed inverse");
        assert!((recovered.0 - 0.01).abs() < INVERSE_TOLERANCE_PX);
        assert!((recovered.1 - 10.0).abs() < INVERSE_TOLERANCE_PX);
    }

    #[test]
    fn rejects_displacement_or_jacobian_that_could_fold_the_map() {
        let mut too_far = SourcePlaneWarp::zero();
        too_far.offsets[4] = [64.1, 0.0];
        assert!(validate_source_plane_warp(&too_far, 1000, 800)
            .unwrap_err()
            .contains("magnitude"));
        let mut too_steep = SourcePlaneWarp::zero();
        too_steep.offsets[1] = [60.0, 0.0];
        assert!(validate_source_plane_warp(&too_steep, 1000, 800)
            .unwrap_err()
            .contains("strain"));
    }

    #[test]
    fn fit_requires_support_preserves_anchor_and_recovers_supported_translation() {
        let samples = (0..9)
            .flat_map(|row| {
                (0..9).map(move |column| SourceWarpSample {
                    x: column as f64 * 99.0,
                    y: row as f64 * 99.0,
                    dx: 8.0,
                    dy: -4.0,
                    weight: 1.0,
                })
            })
            .collect::<Vec<_>>();
        let (warp, diagnostics) = fit_source_plane_warp(793, 793, &samples, false);
        let warp = warp.expect("well-supported tile should be fitted");
        assert!(diagnostics.supported);
        assert_eq!(diagnostics.occupied_cells, 4);
        assert!((warp.offsets[4][0] - 8.0).abs() < 0.2);
        assert!((warp.offsets[4][1] + 4.0).abs() < 0.2);
        validate_source_plane_warp(&warp, 793, 793).unwrap();

        let (anchor, anchor_diagnostics) = fit_source_plane_warp(793, 793, &samples, true);
        assert!(anchor_diagnostics.supported);
        assert!(anchor.unwrap().is_zero());
        let (unsupported, unsupported_diagnostics) =
            fit_source_plane_warp(793, 793, &samples[..20], false);
        assert!(unsupported.is_none());
        assert!(!unsupported_diagnostics.supported);
    }

    #[test]
    fn partial_two_quadrant_support_fits_supported_knots_and_pins_unsupported_edge() {
        let samples = (0..16)
            .flat_map(|index| {
                let x = 15.0;
                let y = 5.0 + index as f64 * 2.5;
                [
                    SourceWarpSample {
                        x,
                        y,
                        dx: 3.0,
                        dy: -2.0,
                        weight: 1.0,
                    },
                    SourceWarpSample {
                        x: 85.0,
                        y,
                        dx: 3.0,
                        dy: -2.0,
                        weight: 1.0,
                    },
                ]
            })
            .collect::<Vec<_>>();
        let (warp, diagnostics) = fit_source_plane_warp(101, 101, &samples, false);
        let warp = warp.unwrap_or_else(|| panic!("partial support fit rejected: {diagnostics:?}"));
        assert!(diagnostics.supported);
        assert_eq!(diagnostics.occupied_cells, 2);
        assert!(diagnostics.supported_control_knots >= 4);
        for index in 6..9 {
            assert_eq!(warp.offsets[index], [0.0, 0.0]);
        }
        validate_source_plane_warp(&warp, 101, 101).unwrap();

        let one_quadrant = (0..32)
            .map(|index| SourceWarpSample {
                x: 10.0 + (index % 2) as f64 * 20.0,
                y: 5.0 + (index / 2) as f64 * 2.5,
                dx: 3.0,
                dy: -2.0,
                weight: 1.0,
            })
            .collect::<Vec<_>>();
        let (none, diagnostics) = fit_source_plane_warp(101, 101, &one_quadrant, false);
        assert!(none.is_none());
        assert!(!diagnostics.supported);
    }

    #[test]
    fn fitted_field_is_limited_before_serialization() {
        let samples = (0..13)
            .flat_map(|row| {
                (0..13).map(move |column| {
                    let x = column as f64 * 99.0;
                    let y = row as f64 * 99.0;
                    SourceWarpSample {
                        x,
                        y,
                        dx: (x / 792.0 - 0.5) * 400.0,
                        dy: (y / 792.0 - 0.5) * 300.0,
                        weight: 1.0,
                    }
                })
            })
            .collect::<Vec<_>>();
        let (warp, diagnostics) = fit_source_plane_warp(793, 793, &samples, false);
        let warp = warp.expect("spatially distributed observations should remain usable");
        assert!(diagnostics.max_offset_px <= SOURCE_WARP_MAX_DISPLACEMENT_PX + 1e-8);
        assert!(diagnostics.max_strain <= SOURCE_WARP_MAX_LOCAL_STRAIN + 1e-8);
        validate_source_plane_warp(&warp, 793, 793).unwrap();
    }

    #[test]
    fn multilevel_fit_keeps_coarse_field_and_only_accepts_bounded_residual_levels() {
        let mut samples = Vec::new();
        for yi in 0..=20 {
            for xi in 0..=20 {
                let x = xi as f64 * 5.0;
                let y = yi as f64 * 5.0;
                // Smooth nonlinear displacement that benefits from finer knots.
                let dx = 5.0 + 0.00015 * (x - 50.0).powi(2) - 0.00015 * (y - 50.0).powi(2);
                let dy = 2.0 + 0.00008 * (x - 50.0) * (y - 50.0);
                samples.push(SourceWarpSample {
                    x,
                    y,
                    dx,
                    dy,
                    weight: 1.0,
                });
            }
        }
        let (warp, levels) = fit_source_plane_warp_multilevel(101, 101, &samples, false, 0.25);
        let warp = warp.expect("supported coarse field should remain available");
        assert!(matches!(
            (warp.columns, warp.rows),
            (3, 3) | (5, 5) | (9, 9)
        ));
        assert!(
            warp.columns > 3,
            "nonlinear synthetic support should accept a finer level"
        );
        validate_source_plane_warp(&warp, 101, 101).unwrap();
        assert_eq!(levels.len(), 3);
        assert!(levels[0].supported);
        assert!(levels.iter().skip(1).any(|level| level.supported));
        assert!(levels.iter().skip(1).all(|level| {
            !level.supported
                || (level.max_offset_px <= SOURCE_WARP_MAX_DISPLACEMENT_PX + 1e-8
                    && level.max_strain <= SOURCE_WARP_MAX_LOCAL_STRAIN + 1e-8)
        }));
        let final_cost = weighted_sample_cost(&warp, 101, 101, &samples);
        let (coarse, _) = fit_source_plane_warp_with_smoothness(101, 101, &samples, false, 0.25);
        assert!(final_cost <= weighted_sample_cost(&coarse.unwrap(), 101, 101, &samples) + 1e-8);
    }

    #[test]
    fn generalized_grid_validation_and_bilinear_sampling_cover_5_and_9_knots() {
        for side in [5, 9] {
            let warp = SourcePlaneWarp {
                columns: side,
                rows: side,
                offsets: vec![[2.0, -1.0]; side * side],
            };
            validate_source_plane_warp(&warp, 101, 81).unwrap();
            assert_eq!(
                source_to_corrected(&warp, 101, 81, 50.0, 40.0),
                Some((52.0, 39.0))
            );
        }
        let invalid = SourcePlaneWarp {
            columns: 4,
            rows: 4,
            offsets: vec![[0.0; 2]; 16],
        };
        assert!(validate_source_plane_warp(&invalid, 101, 81).is_err());
    }

    #[test]
    fn fine_grid_strain_checks_every_cell_using_fine_cell_spacing() {
        let mut warp = SourcePlaneWarp {
            columns: 9,
            rows: 9,
            offsets: vec![[0.0; 2]; 81],
        };
        warp.offsets[80] = [0.5, 0.5];
        let (_, measured) = warp_limits(&warp, 101, 101);
        assert!((measured - 0.5 / 12.5 * 2.0).abs() < 1e-9);
        validate_source_plane_warp(&warp, 101, 101).unwrap();
    }
}
