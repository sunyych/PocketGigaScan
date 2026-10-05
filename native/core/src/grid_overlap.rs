//! Bounded SIFT/BF overlap calibration from a normalized central grid cross.
use crate::{
    pipeline::{spherical_overlap_matches, GridOverlapMatch},
    Error,
};
use serde_json::{json, Value};
use std::path::PathBuf;

const MAX_AXIS_PAIRS: usize = 12;
const MIN_INLIERS: usize = 12;
const MIN_INLIER_RATIO: f64 = 0.25;
const MAX_RESIDUAL_PX: f64 = 3.0;
const MIN_OVERLAP: f64 = 0.05;
const MAX_OVERLAP: f64 = 0.95;

#[derive(Clone, Debug)]
pub(crate) struct Estimate {
    pub horizontal_overlap: f64,
    pub vertical_overlap: f64,
    pub horizontal_step_px: f64,
    pub vertical_step_px: f64,
    pub horizontal_step_rad: f64,
    pub vertical_step_rad: f64,
    pub sampled_feature_count: usize,
    pub sampled_tile_count: usize,
    pub sample_total_ms: u64,
    pub report: Value,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum EstimateError {
    Cancelled,
    Failed,
}

fn central_pairs(
    rows: usize,
    columns: usize,
    forced: &[bool],
) -> (Vec<(usize, usize)>, Vec<Value>) {
    let mut pairs = Vec::new();
    let mut skipped = Vec::new();
    let push = |pair: (usize, usize), pairs: &mut Vec<(usize, usize)>, skipped: &mut Vec<Value>| {
        if pairs.contains(&pair)
            || skipped
                .iter()
                .any(|v| v["from"] == pair.0 && v["to"] == pair.1)
        {
            return;
        }
        if forced.get(pair.0).copied().unwrap_or(false)
            || forced.get(pair.1).copied().unwrap_or(false)
        {
            skipped.push(json!({"from":pair.0,"to":pair.1,"status":"skipped-force-grid-source"}));
        } else {
            pairs.push(pair);
        }
    };
    // Keep the 16x24 capture's known central cross in the first four samples;
    // smaller grids use their normalized center cell as the anchor.
    let row_anchor = 10.min(rows.saturating_sub(3));
    let column_anchor = 10.min(columns.saturating_sub(3));
    if rows > 1 && columns > 2 {
        push(
            (
                row_anchor * columns + column_anchor,
                row_anchor * columns + column_anchor + 1,
            ),
            &mut pairs,
            &mut skipped,
        );
        push(
            (
                row_anchor * columns + column_anchor + 1,
                row_anchor * columns + column_anchor + 2,
            ),
            &mut pairs,
            &mut skipped,
        );
    }
    if rows > 2 && columns > 1 {
        push(
            (
                row_anchor * columns + column_anchor,
                (row_anchor + 1) * columns + column_anchor,
            ),
            &mut pairs,
            &mut skipped,
        );
        push(
            (
                (row_anchor + 1) * columns + column_anchor,
                (row_anchor + 2) * columns + column_anchor,
            ),
            &mut pairs,
            &mut skipped,
        );
    }
    let center_row = (rows.saturating_sub(1)) as f64 * 0.5;
    let center_column = (columns.saturating_sub(1)) as f64 * 0.5;
    let mut horizontal = (0..rows)
        .flat_map(|row| {
            (0..columns.saturating_sub(1)).map(move |column| {
                (
                    (row, column),
                    (row * columns + column, row * columns + column + 1),
                    ((row as f64 - center_row) / rows.max(1) as f64).powi(2)
                        + ((column as f64 + 0.5 - center_column) / columns.max(1) as f64).powi(2),
                )
            })
        })
        .collect::<Vec<_>>();
    horizontal.sort_by(|a, b| a.2.total_cmp(&b.2));
    let mut vertical = (0..rows.saturating_sub(1))
        .flat_map(|row| {
            (0..columns).map(move |column| {
                (
                    (row, column),
                    (row * columns + column, (row + 1) * columns + column),
                    ((row as f64 + 0.5 - center_row) / rows.max(1) as f64).powi(2)
                        + ((column as f64 - center_column) / columns.max(1) as f64).powi(2),
                )
            })
        })
        .collect::<Vec<_>>();
    vertical.sort_by(|a, b| a.2.total_cmp(&b.2));
    for (_, pair, _) in horizontal {
        let before = pairs
            .iter()
            .filter(|(a, b)| *a / columns == *b / columns)
            .count();
        if before >= MAX_AXIS_PAIRS {
            break;
        }
        push(pair, &mut pairs, &mut skipped);
    }
    for (_, pair, _) in vertical {
        let before = pairs
            .iter()
            .filter(|(a, b)| *a % columns == *b % columns)
            .count();
        if before >= MAX_AXIS_PAIRS {
            break;
        }
        push(pair, &mut pairs, &mut skipped);
    }
    (pairs, skipped)
}

fn median(mut values: Vec<f64>) -> Option<f64> {
    if values.is_empty() || values.iter().any(|v| !v.is_finite()) {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let n = values.len();
    Some(if n % 2 == 0 {
        (values[n / 2 - 1] + values[n / 2]) * 0.5
    } else {
        values[n / 2]
    })
}

fn summarize_axis(
    name: &str,
    samples: &[((usize, usize), GridOverlapMatch)],
    columns: usize,
    source_dimension: f64,
) -> (Option<(f64, f64)>, Value) {
    let mut accepted_steps = Vec::new();
    let mut diagnostics = Vec::with_capacity(samples.len());
    for &((row, column), ref m) in samples {
        let (axis_step, cross_step) = if name == "horizontal" {
            (m.step_x_px, m.step_y_px)
        } else {
            (m.step_y_px, m.step_x_px)
        };
        let displacement = axis_step.abs();
        let overlap = 1.0 - displacement / source_dimension;
        let cross_ok = cross_step.abs() <= displacement * 0.15 + 2.0;
        // Canonical row-major scan order advances right and down; matched
        // content therefore moves left/up in the source frame. Keep the
        // signed measurement and fail closed if a grid arrives reversed.
        let direction_ok = axis_step < 0.0;
        let accepted = m.reason == 0
            && m.inliers >= MIN_INLIERS
            && m.inlier_ratio >= MIN_INLIER_RATIO
            && m.residual_px.is_finite()
            && m.residual_px <= MAX_RESIDUAL_PX
            && displacement.is_finite()
            && direction_ok
            && (MIN_OVERLAP..=MAX_OVERLAP).contains(&overlap)
            && cross_ok;
        if accepted {
            accepted_steps.push(axis_step);
        }
        let from = row * columns + column;
        let to = if name == "horizontal" {
            from + 1
        } else {
            from + columns
        };
        diagnostics.push(json!({
            "row":row,"column":column,"from":from,"to":to,
            "matches":m.matches,"inliers":m.inliers,"inlierRatio":m.inlier_ratio,
            "residualPx":m.residual_px,"stepXPx":m.step_x_px,"stepYPx":m.step_y_px,
            "overlap":if overlap.is_finite() { json!(overlap) } else { Value::Null },
            "reason":m.reason,"sourceFeatures":m.source_features,"targetFeatures":m.target_features,
            "status":if accepted { "accepted" } else if !cross_ok { "rejected-cross-axis-motion" }
                else if !direction_ok { "rejected-grid-direction" }
                else if overlap < MIN_OVERLAP || overlap > MAX_OVERLAP { "rejected-overlap-range" }
                else if m.residual_px > MAX_RESIDUAL_PX { "rejected-reprojection-residual" }
                else if m.inliers < MIN_INLIERS || m.inlier_ratio < MIN_INLIER_RATIO { "rejected-insufficient-inliers" }
                else { "rejected-homography" }
        }));
    }
    let mut step = median(accepted_steps.clone());
    if let Some(center) = step {
        let mut deviations = accepted_steps
            .iter()
            .map(|v| (v - center).abs())
            .collect::<Vec<_>>();
        let mad = median(std::mem::take(&mut deviations)).unwrap_or(f64::INFINITY);
        let spread_limit = (center.abs() * 0.10).max(3.0);
        let consistent = accepted_steps.len() >= 2
            && mad <= spread_limit
            && accepted_steps
                .iter()
                .all(|v| (v - center).abs() <= spread_limit && v.signum() == center.signum());
        if !consistent {
            step = None;
        }
    }
    let summary = step.map(|value| json!({"overlap":1.0-value.abs()/source_dimension,"stepPixels":value,"acceptedPairCount":accepted_steps.len()}));
    (
        step.map(|value| (value, 1.0 - value.abs() / source_dimension)),
        json!({"acceptedPairCount":accepted_steps.len(),"stepPixels":step,"summary":summary,"pairs":diagnostics}),
    )
}

pub(crate) fn estimate(
    rows: usize,
    columns: usize,
    paths: &[PathBuf],
    forced: &[bool],
    width: u32,
    height: u32,
    fx: f64,
    fy: f64,
    maximum_pixels: usize,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> std::result::Result<Estimate, (EstimateError, Value)> {
    let (pairs, skipped) = central_pairs(rows, columns, forced);
    if pairs.is_empty() {
        return Err((
            EstimateError::Failed,
            json!({"method":"central-sift-bf-ransac-v1","pairs":[],"skippedPairs":skipped,"failure":"no eligible central adjacent samples"}),
        ));
    }
    let sample_started = std::time::Instant::now();
    let matches =
        spherical_overlap_matches(paths, &pairs, maximum_pixels, width, height, checkpoint)
            .map_err(|e| {
                if matches!(e, Error::Cancelled) {
                    (EstimateError::Cancelled, Value::Null)
                } else {
                    (EstimateError::Failed, json!({"failure":e.to_string()}))
                }
            })?;
    let mut feature_counts = std::collections::BTreeMap::new();
    let mut horizontal = Vec::new();
    let mut vertical = Vec::new();
    for (pair, sample) in pairs.iter().copied().zip(matches) {
        feature_counts.insert(pair.0, sample.source_features);
        feature_counts.insert(pair.1, sample.target_features);
        let row = pair.0 / columns;
        let column = pair.0 % columns;
        if pair.1 == pair.0 + 1 && pair.0 / columns == pair.1 / columns {
            horizontal.push(((row, column), sample));
        } else {
            vertical.push(((row, column), sample));
        }
    }
    let h = if columns > 1 {
        summarize_axis("horizontal", &horizontal, columns, f64::from(width))
    } else {
        (None, json!({"status":"not-needed"}))
    };
    let v = if rows > 1 {
        summarize_axis("vertical", &vertical, columns, f64::from(height))
    } else {
        (None, json!({"status":"not-needed"}))
    };
    let h_report = h.1;
    let v_report = v.1;
    if (columns > 1 && h.0.is_none()) || (rows > 1 && v.0.is_none()) {
        let report = json!({"method":"central-sift-bf-ransac-v1","horizontal":h_report,"vertical":v_report,"skippedPairs":skipped,"failure":"each required axis needs two or more consistent accepted central homographies"});
        return Err((EstimateError::Failed, report));
    }
    let (h_step, h_overlap) = h.0.unwrap_or((0.0, 0.0));
    let (v_step, v_overlap) = v.0.unwrap_or((0.0, 0.0));
    let sampled_feature_count = feature_counts.values().sum::<usize>();
    let sampled_tile_count = feature_counts.len();
    let sample_total_ms = sample_started.elapsed().as_millis() as u64;
    Ok(Estimate {
        horizontal_overlap: h_overlap,
        vertical_overlap: v_overlap,
        horizontal_step_px: h_step,
        vertical_step_px: v_step,
        horizontal_step_rad: (h_step.abs() / fx).atan(),
        vertical_step_rad: (v_step.abs() / fy).atan(),
        sampled_feature_count,
        sampled_tile_count,
        sample_total_ms,
        report: json!({
            "method":"central-sift-bf-ransac-v1","confidence":"measured-central-samples-needs-visual-review",
            "provenance":"central-adjacent-image-homographies; caller-supplied fx/fy used only for spherical angle conversion",
            "horizontalOverlap":if columns > 1 { json!(h_overlap) } else { Value::Null },"verticalOverlap":if rows > 1 { json!(v_overlap) } else { Value::Null },
            "horizontalStepPixels":h_step,"verticalStepPixels":v_step,
            "horizontal":h_report,"vertical":v_report,"skippedPairs":skipped,
            "sourceDimensions":{"width":width,"height":height},"fx":fx,"fy":fy,
            "sampledFeatureCount":sampled_feature_count,"sampledTileCount":sampled_tile_count,"sampleOverlapMs":sample_total_ms,
            "featureMethod":"SIFT","matcher":"BF","ransac":true
        }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{GrayImage, Luma};

    #[test]
    fn sixteen_by_twenty_four_prioritizes_requested_cross() {
        let (pairs, _) = central_pairs(16, 24, &vec![false; 384]);
        assert_eq!(
            &pairs[..4],
            &[(250, 251), (251, 252), (250, 274), (274, 298)]
        );
        assert!(pairs.len() <= 24);
        assert!(pairs.iter().all(|(a, b)| *b == *a + 1 || *b == *a + 24));
    }

    #[test]
    fn forced_tiles_are_skipped_without_losing_later_candidates() {
        let mut forced = vec![false; 384];
        forced[250] = true;
        let (pairs, skipped) = central_pairs(16, 24, &forced);
        assert!(!pairs.iter().any(|(a, b)| *a == 250 || *b == 250));
        assert!(skipped.iter().any(|pair| pair["from"] == 250));
        assert!(pairs.len() <= 24);
    }

    fn fixture_dir(label: &str) -> PathBuf {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "grid-overlap-{label}-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn texture(x: u32, y: u32) -> u8 {
        let mut value = x.wrapping_mul(0x9e37_79b9) ^ y.wrapping_mul(0x85eb_ca6b);
        value ^= value >> 16;
        value = value.wrapping_mul(0x7feb_352d);
        value ^= value >> 15;
        (value & 0xff) as u8
    }

    fn crop_fixture(blank: bool) -> (PathBuf, Vec<PathBuf>) {
        let dir = fixture_dir(if blank { "blank" } else { "crops" });
        let canvas = GrayImage::from_fn(660, 660, |x, y| {
            Luma([if blank { 128 } else { texture(x, y) }])
        });
        let mut paths = Vec::new();
        for row in 0..3 {
            for column in 0..3 {
                let image = GrayImage::from_fn(420, 420, |x, y| {
                    *canvas.get_pixel(column * 120 + x, row * 120 + y)
                });
                let path = dir.join(format!("{row}-{column}.png"));
                image.save(&path).unwrap();
                paths.push(path);
            }
        }
        (dir, paths)
    }

    #[test]
    fn synthetic_two_axis_crops_estimate_overlap_and_retain_every_grid_cell() {
        let (dir, paths) = crop_fixture(false);
        let estimate = estimate(
            3,
            3,
            &paths,
            &vec![false; 9],
            420,
            420,
            500.0,
            500.0,
            420 * 420,
            &mut |_| Ok(()),
        )
        .unwrap();
        assert!(
            (estimate.horizontal_overlap - (1.0 - 120.0 / 420.0)).abs() < 0.08,
            "{}",
            estimate.report
        );
        assert!(
            (estimate.vertical_overlap - (1.0 - 120.0 / 420.0)).abs() < 0.08,
            "{}",
            estimate.report
        );
        let request = json!({"rows":3,"columns":3,"tiles":paths.iter().enumerate().map(|(i,path)| json!({"row":i/3,"column":i%3,"path":path,"forceGrid":false})).collect::<Vec<_>>(),"fx":500,"fy":500,"cx":210,"cy":210,"sourceWidth":420,"sourceHeight":420,"autoGridOverlap":true,"registrationMegapixels":0.2});
        let layout = crate::spherical::align_json_detailed(&request.to_string()).unwrap();
        assert_eq!(layout["tiles"].as_array().unwrap().len(), 9);
        assert!(layout["tiles"]
            .as_array()
            .unwrap()
            .iter()
            .all(|tile| tile["positionSource"] == "gridEstimated"));
        assert_eq!(layout["report"]["visualTileCount"], 0);
        assert_eq!(layout["report"]["gridEstimatedTileCount"], 9);
        assert!(
            layout["report"]["gridOverlapEstimate"]["horizontal"]["pairs"]
                .as_array()
                .unwrap()
                .iter()
                .any(|p| p["status"] == "accepted")
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn blank_crops_fail_with_axis_evidence_and_samples_honor_cancellation() {
        let (dir, paths) = crop_fixture(true);
        let failure = estimate(
            3,
            3,
            &paths,
            &vec![false; 9],
            420,
            420,
            500.0,
            500.0,
            420 * 420,
            &mut |_| Ok(()),
        )
        .unwrap_err();
        assert_eq!(failure.0, EstimateError::Failed);
        assert!(failure.1["horizontal"]["pairs"].is_array());
        let cancelled = estimate(
            3,
            3,
            &paths,
            &vec![false; 9],
            420,
            420,
            500.0,
            500.0,
            420 * 420,
            &mut |_| Err("cancel".into()),
        )
        .unwrap_err();
        assert_eq!(cancelled.0, EstimateError::Cancelled);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn one_row_requires_only_horizontal_overlap() {
        let (dir, paths) = crop_fixture(false);
        let estimate = estimate(
            1,
            3,
            &paths[..3],
            &vec![false; 3],
            420,
            420,
            500.0,
            500.0,
            420 * 420,
            &mut |_| Ok(()),
        )
        .unwrap();
        assert!(estimate.horizontal_overlap > 0.05);
        assert_eq!(estimate.report["vertical"], json!({"status":"not-needed"}));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn one_column_requires_only_vertical_overlap() {
        let (dir, paths) = crop_fixture(false);
        let vertical = vec![paths[0].clone(), paths[3].clone(), paths[6].clone()];
        let estimate = estimate(
            3,
            1,
            &vertical,
            &vec![false; 3],
            420,
            420,
            500.0,
            500.0,
            420 * 420,
            &mut |_| Ok(()),
        )
        .unwrap();
        assert!(estimate.vertical_overlap > 0.05);
        assert_eq!(
            estimate.report["horizontal"],
            json!({"status":"not-needed"})
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn axis_consistency_gate_rejects_a_displacement_outlier() {
        let sample = |step| GridOverlapMatch {
            matches: 80,
            inliers: 60,
            inlier_ratio: 0.75,
            residual_px: 0.5,
            step_x_px: step,
            step_y_px: 0.0,
            reason: 0,
            source_features: 100,
            target_features: 100,
        };
        let samples = vec![
            ((1, 0), sample(-100.0)),
            ((1, 1), sample(-102.0)),
            ((1, 2), sample(-400.0)),
        ];
        let (estimate, _) = summarize_axis("horizontal", &samples, 4, 500.0);
        assert!(estimate.is_none());
    }

    #[test]
    fn positive_image_displacement_fails_canonical_grid_direction_gate() {
        let sample = GridOverlapMatch {
            matches: 80,
            inliers: 60,
            inlier_ratio: 0.75,
            residual_px: 0.5,
            step_x_px: 100.0,
            step_y_px: 0.0,
            reason: 0,
            source_features: 100,
            target_features: 100,
        };
        let samples = vec![((1, 0), sample.clone()), ((1, 1), sample)];
        let (estimate, report) = summarize_axis("horizontal", &samples, 4, 500.0);
        assert!(estimate.is_none());
        assert!(report["pairs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|p| p["status"] == "rejected-grid-direction"));
    }
}
