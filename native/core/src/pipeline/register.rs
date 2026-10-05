use crate::{
    metadata::{CaptureGeometry, CaptureTile, StitchEdgeReport, StitchOptions, StitchReport},
    Error, Result,
};
use std::{
    collections::{HashMap, VecDeque},
    ffi::{c_char, c_void, CString},
    path::{Path, PathBuf},
};

extern "C" {
    fn lg_sift_batch_begin() -> *mut c_void;
    fn lg_sift_batch_end(guard: *mut c_void);
    fn lg_sift_features_create_batch(
        path: *const c_char,
        feature_count: *mut i32,
        maximum_pixels: usize,
        contrast_threshold: f64,
        guard: *mut c_void,
        use_orb: i32,
    ) -> *mut c_void;
    fn lg_sift_features_create(path: *const c_char, feature_count: *mut i32) -> *mut c_void;
    fn lg_sift_features_create_bounded(
        path: *const c_char,
        feature_count: *mut i32,
        maximum_pixels: usize,
        thread_limit: i32,
    ) -> *mut c_void;
    fn lg_sift_features_create_bounded_contrast(
        path: *const c_char,
        feature_count: *mut i32,
        maximum_pixels: usize,
        thread_limit: i32,
        contrast_threshold: f64,
        use_orb: i32,
    ) -> *mut c_void;
    fn lg_sift_features_create_bounded_clahe(
        path: *const c_char,
        feature_count: *mut i32,
        maximum_pixels: usize,
        thread_limit: i32,
        contrast_threshold: f64,
        use_orb: i32,
    ) -> *mut c_void;
    fn lg_sift_features_destroy(frame: *mut c_void);
    fn lg_sift_features_count(frame: *const c_void) -> i32;
    fn lg_sift_match(
        from: *const c_void,
        to: *const c_void,
        expected_dx: f64,
        expected_dy: f64,
        width: f64,
        height: f64,
        homography: *mut f64,
        dx: *mut f64,
        dy: *mut f64,
        ratio: *mut f64,
        residual: *mut f64,
        matches: *mut i32,
        inliers: *mut i32,
        reason: *mut i32,
    ) -> i32;
    fn lg_sift_match_points(
        from: *const c_void,
        to: *const c_void,
        source_xy: *mut f64,
        target_xy: *mut f64,
        capacity: i32,
        matches: *mut i32,
        inliers: *mut i32,
        ratio: *mut f64,
        residual: *mut f64,
        reason: *mut i32,
        use_flann: i32,
        guard: *mut c_void,
    ) -> i32;
}

#[derive(Clone)]
pub(crate) struct SphericalMatchEdge {
    pub from: usize,
    pub to: usize,
    pub from_features: usize,
    pub to_features: usize,
    pub matches: usize,
    pub inliers: usize,
    pub inlier_ratio: f64,
    pub homography_residual: f64,
    pub reason: i32,
    pub points: Vec<[f64; 4]>,
    pub initial: SphericalMatchAttempt,
    pub retry: Option<SphericalMatchAttempt>,
    pub clahe_retry: Option<SphericalMatchAttempt>,
    pub used_retry: bool,
    pub used_clahe_retry: bool,
}

#[derive(Clone)]
pub(crate) struct SphericalMatchAttempt {
    pub from_features: usize,
    pub to_features: usize,
    pub matches: usize,
    pub inliers: usize,
    pub inlier_ratio: f64,
    pub reason: i32,
    pub contrast_threshold: f64,
    pub clahe: bool,
}

#[derive(Clone, Debug)]
pub(crate) struct GridOverlapMatch {
    pub matches: usize,
    pub inliers: usize,
    pub inlier_ratio: f64,
    pub residual_px: f64,
    pub step_x_px: f64,
    pub step_y_px: f64,
    pub reason: i32,
    pub source_features: usize,
    pub target_features: usize,
}

/// Match only the requested central-grid pairs with SIFT/BF/RANSAC. A tile's
/// feature frame is decoded once even when it participates in two samples.
pub(crate) fn spherical_overlap_matches(
    paths: &[PathBuf],
    pairs: &[(usize, usize)],
    maximum_pixels: usize,
    source_width: u32,
    source_height: u32,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> Result<Vec<GridOverlapMatch>> {
    let mut used = pairs.iter().flat_map(|&(a, b)| [a, b]).collect::<Vec<_>>();
    used.sort_unstable();
    used.dedup();
    if pairs.is_empty() || used.iter().any(|index| *index >= paths.len()) {
        return Err(Error::Invalid(
            "invalid central overlap sample pairs".into(),
        ));
    }
    let guard = FeatureBatchGuard::begin()?;
    let mut frames = HashMap::with_capacity(used.len());
    for (n, index) in used.iter().copied().enumerate() {
        checkpoint("grid-overlap-feature-extraction").map_err(|_| Error::Cancelled)?;
        let frame =
            NativeFeatures::from_path_in_batch(&paths[index], maximum_pixels, &guard, false);
        frames.insert(index, frame);
        if n % 4 == 3 {
            checkpoint("grid-overlap-feature-extraction").map_err(|_| Error::Cancelled)?;
        }
    }
    // Feature extraction's native batch guard is exclusive; matching takes a
    // shared OpenCV lock, so release the guard before invoking the matcher.
    drop(guard);
    let mut output = Vec::with_capacity(pairs.len());
    for &(from, to) in pairs {
        checkpoint("grid-overlap-pair-matching").map_err(|_| Error::Cancelled)?;
        let a = &frames[&from];
        let b = &frames[&to];
        let (mut homography, mut dx, mut dy, mut ratio, mut residual) =
            ([0.0; 9], 0.0, 0.0, 0.0, 0.0);
        let (mut matches, mut inliers, mut reason) = (0, 0, 0);
        let ok = unsafe {
            lg_sift_match(
                a.ptr,
                b.ptr,
                0.0,
                0.0,
                0.0,
                0.0,
                homography.as_mut_ptr(),
                &mut dx,
                &mut dy,
                &mut ratio,
                &mut residual,
                &mut matches,
                &mut inliers,
                &mut reason,
            ) != 0
        };
        let center_x = f64::from(source_width) * 0.5;
        let center_y = f64::from(source_height) * 0.5;
        let denominator = homography[6] * center_x + homography[7] * center_y + homography[8];
        let center_projection_valid = denominator.is_finite() && denominator.abs() > 1e-10;
        let (step_x_px, step_y_px) = if ok && center_projection_valid {
            (
                (homography[0] * center_x + homography[1] * center_y + homography[2]) / denominator
                    - center_x,
                (homography[3] * center_x + homography[4] * center_y + homography[5]) / denominator
                    - center_y,
            )
        } else {
            if ok {
                reason = 3;
            }
            (0.0, 0.0)
        };
        output.push(GridOverlapMatch {
            matches: matches.max(0) as usize,
            inliers: inliers.max(0) as usize,
            inlier_ratio: ratio,
            residual_px: residual,
            step_x_px,
            step_y_px,
            reason,
            source_features: a.count,
            target_features: b.count,
        });
    }
    checkpoint("grid-overlap-complete").map_err(|_| Error::Cancelled)?;
    Ok(output)
}

/// Stable row-major cell-index pairs; callers map cells to tile indices before matching.
pub(crate) fn spherical_neighbor_pairs(
    rows: usize,
    columns: usize,
    eight: bool,
) -> Vec<(usize, usize)> {
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
            if eight && row + 1 < rows && column + 1 < columns {
                pairs.push((from, from + columns + 1));
            }
            if eight && row + 1 < rows && column > 0 {
                pairs.push((from, from + columns - 1));
            }
        }
    }
    pairs
}

fn match_spherical_pair(
    from: usize,
    to: usize,
    source_frame: &NativeFeatures,
    target_frame: &NativeFeatures,
    contrast_threshold: f64,
    clahe: bool,
    use_flann: bool,
    guard_token: usize,
) -> SphericalMatchEdge {
    let mut source = vec![0.0; 2500 * 2];
    let mut target = vec![0.0; 2500 * 2];
    let (mut matches, mut inliers, mut ratio, mut residual, mut reason) = (0, 0, 0.0, 0.0, 0);
    let ok = unsafe {
        lg_sift_match_points(
            source_frame.ptr,
            target_frame.ptr,
            source.as_mut_ptr(),
            target.as_mut_ptr(),
            2500,
            &mut matches,
            &mut inliers,
            &mut ratio,
            &mut residual,
            &mut reason,
            i32::from(use_flann),
            guard_token as *mut c_void,
        ) != 0
    };
    let count = if ok {
        (inliers.max(0) as usize).min(2500)
    } else {
        0
    };
    let points = (0..count)
        .map(|i| {
            [
                source[2 * i],
                source[2 * i + 1],
                target[2 * i],
                target[2 * i + 1],
            ]
        })
        .collect();
    let attempt = SphericalMatchAttempt {
        from_features: source_frame.count,
        to_features: target_frame.count,
        matches: matches.max(0) as usize,
        inliers: count,
        inlier_ratio: ratio,
        reason,
        contrast_threshold,
        clahe,
    };
    SphericalMatchEdge {
        from,
        to,
        from_features: attempt.from_features,
        to_features: attempt.to_features,
        matches: attempt.matches,
        inliers: attempt.inliers,
        inlier_ratio: attempt.inlier_ratio,
        homography_residual: residual,
        reason: attempt.reason,
        points,
        initial: attempt,
        retry: None,
        clahe_retry: None,
        used_retry: false,
        used_clahe_retry: false,
    }
}

pub(crate) fn spherical_match_edges(
    rows: usize,
    columns: usize,
    tiles: &[CaptureTile],
    frames: Vec<NativeFeatures>,
    maximum_pixels: usize,
    thread_limit: i32,
    retry_contrast_threshold: f64,
    neighbor_mode: &str,
    matching_workers: usize,
    feature_type: &str,
    matcher_type: &str,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> Result<(
    Vec<SphericalMatchEdge>,
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
)> {
    if rows == 0 || columns == 0 || rows.checked_mul(columns) != Some(tiles.len()) {
        return Err(Error::Invalid("invalid spherical registration grid".into()));
    }
    let mut cells = HashMap::new();
    for (index, tile) in tiles.iter().enumerate() {
        if tile.row >= rows
            || tile.column >= columns
            || cells.insert((tile.row, tile.column), index).is_some()
        {
            return Err(Error::Registration(
                "duplicate or out-of-range spherical tile cell".into(),
            ));
        }
    }
    if cells.len() != tiles.len() || frames.len() != tiles.len() {
        return Err(Error::Registration(
            "incomplete spherical registration grid".into(),
        ));
    }
    if matching_workers == 0 || matching_workers > 32 {
        return Err(Error::Invalid(
            "matching workers must be between 1 and 32".into(),
        ));
    }
    let mut edges = Vec::new();
    let pairs = spherical_neighbor_pairs(rows, columns, neighbor_mode == "eight");
    let initial_match_started = std::time::Instant::now();
    let effective_matching_workers = matching_workers.min(pairs.len().max(1));
    let matching_guard = FeatureBatchGuard::begin()?;
    let matching_guard_token = matching_guard.token();
    for batch in pairs.chunks(effective_matching_workers) {
        checkpoint("matching-edge-batch").map_err(|_| Error::Cancelled)?;
        let results = std::thread::scope(|scope| {
            batch
                .iter()
                .map(|&(from_cell, to_cell)| {
                    let cells = &cells;
                    let frames = &frames;
                    let matcher_type = matcher_type;
                    scope.spawn(move || {
                        let from = cells[&(from_cell / columns, from_cell % columns)];
                        let to = cells[&(to_cell / columns, to_cell % columns)];
                        match_spherical_pair(
                            from,
                            to,
                            &frames[from],
                            &frames[to],
                            0.015,
                            false,
                            matcher_type == "flann",
                            matching_guard_token,
                        )
                    })
                })
                .collect::<Vec<_>>()
                .into_iter()
                .map(|handle| handle.join())
                .collect::<Vec<_>>()
        });
        for result in results {
            edges.push(result.map_err(|_| Error::Registration("matching worker panicked".into()))?);
        }
    }
    if neighbor_mode == "adaptive" {
        // Add only diagonal neighbors that join separate components of the
        // accepted cardinal graph. This keeps recovery local to unresolved
        // regions and avoids comparing unrelated tiles.
        let mut parent = (0..tiles.len()).collect::<Vec<_>>();
        fn root(parent: &mut [usize], mut index: usize) -> usize {
            while parent[index] != index {
                index = parent[index];
            }
            index
        }
        for edge in edges.iter().filter(|edge| edge.reason == 0) {
            let (a, b) = (root(&mut parent, edge.from), root(&mut parent, edge.to));
            if a != b {
                parent[b] = a;
            }
        }
        let diagonals = spherical_neighbor_pairs(rows, columns, true)
            .into_iter()
            .filter(|(a, b)| {
                (a / columns).abs_diff(b / columns) == 1 && (a % columns).abs_diff(b % columns) == 1
            })
            .filter(|(a, b)| {
                let from = cells[&(*a / columns, *a % columns)];
                let to = cells[&(*b / columns, *b % columns)];
                root(&mut parent, from) != root(&mut parent, to)
            })
            .collect::<Vec<_>>();
        for batch in diagonals.chunks(effective_matching_workers) {
            checkpoint("adaptive-diagonal-matching").map_err(|_| Error::Cancelled)?;
            let results = std::thread::scope(|scope| {
                batch
                    .iter()
                    .map(|&(a, b)| {
                        let cells = &cells;
                        let frames = &frames;
                        let matcher_type = matcher_type;
                        scope.spawn(move || {
                            let from = cells[&(a / columns, a % columns)];
                            let to = cells[&(b / columns, b % columns)];
                            match_spherical_pair(
                                from,
                                to,
                                &frames[from],
                                &frames[to],
                                0.015,
                                false,
                                matcher_type == "flann",
                                matching_guard_token,
                            )
                        })
                    })
                    .collect::<Vec<_>>()
                    .into_iter()
                    .map(|handle| handle.join())
                    .collect::<Vec<_>>()
            });
            for result in results {
                edges.push(
                    result.map_err(|_| Error::Registration("matching worker panicked".into()))?,
                );
            }
        }
    }
    drop(matching_guard);
    checkpoint("initial-matching-complete").map_err(|_| Error::Cancelled)?;
    let initial_matching_ms = initial_match_started.elapsed().as_millis() as u64;
    let primary_feature_count = frames.iter().map(feature_count).sum::<usize>();
    drop(frames);

    // Re-extract only endpoints of failed visual edges. Original successful
    // matches remain untouched; retries still pass the same matcher and later
    // RANSAC, calibrated-ray, and global-rotation acceptance gates.
    let failed_edge_indices = edges
        .iter()
        .enumerate()
        .filter_map(|(index, edge)| (edge.reason != 0).then_some(index))
        .collect::<Vec<_>>();
    let mut endpoint_last_use = vec![None; tiles.len()];
    for (use_index, edge_index) in failed_edge_indices.iter().enumerate() {
        endpoint_last_use[edges[*edge_index].from] = Some(use_index);
        endpoint_last_use[edges[*edge_index].to] = Some(use_index);
    }
    let mut retry_frames = (0..tiles.len())
        .map(|_| None)
        .collect::<Vec<Option<NativeFeatures>>>();
    let mut retry_feature_count = 0usize;
    let mut active_retry_features = 0usize;
    let mut peak_retry_features = 0usize;
    let mut active_retry_frames = 0usize;
    let mut peak_retry_frames = 0usize;
    let retry_started = std::time::Instant::now();
    for (use_index, edge_index) in failed_edge_indices.into_iter().enumerate() {
        checkpoint("retry-matching").map_err(|_| Error::Cancelled)?;
        let (edge_from, edge_to) = (edges[edge_index].from, edges[edge_index].to);
        for index in [edge_from, edge_to] {
            if retry_frames[index].is_none() {
                checkpoint("retry-feature-extraction").map_err(|_| Error::Cancelled)?;
                let frame = NativeFeatures::from_path_with_contrast(
                    &tiles[index].path,
                    maximum_pixels,
                    thread_limit,
                    retry_contrast_threshold,
                    feature_type == "orb",
                );
                let count = feature_count(&frame);
                retry_feature_count += count;
                active_retry_features += count;
                active_retry_frames += 1;
                peak_retry_features = peak_retry_features.max(active_retry_features);
                peak_retry_frames = peak_retry_frames.max(active_retry_frames);
                retry_frames[index] = Some(frame);
            }
        }
        let (Some(from), Some(to)) = (
            retry_frames[edge_from].as_ref(),
            retry_frames[edge_to].as_ref(),
        ) else {
            continue;
        };
        let retry_guard = FeatureBatchGuard::begin()?;
        let retry = match_spherical_pair(
            edge_from,
            edge_to,
            from,
            to,
            retry_contrast_threshold,
            false,
            matcher_type == "flann",
            retry_guard.token(),
        );
        drop(retry_guard);
        let edge = &mut edges[edge_index];
        edge.retry = Some(SphericalMatchAttempt {
            from_features: retry.from_features,
            to_features: retry.to_features,
            matches: retry.matches,
            inliers: retry.inliers,
            inlier_ratio: retry.inlier_ratio,
            reason: retry.reason,
            contrast_threshold: retry_contrast_threshold,
            clahe: false,
        });
        if retry.reason == 0 {
            edge.from_features = retry.from_features;
            edge.to_features = retry.to_features;
            edge.matches = retry.matches;
            edge.inliers = retry.inliers;
            edge.inlier_ratio = retry.inlier_ratio;
            edge.homography_residual = retry.homography_residual;
            edge.reason = retry.reason;
            edge.points = retry.points;
            edge.used_retry = true;
        }
        for index in [edge_from, edge_to] {
            if endpoint_last_use[index] == Some(use_index) {
                if let Some(frame) = retry_frames[index].take() {
                    active_retry_features -= feature_count(&frame);
                    active_retry_frames -= 1;
                }
            }
        }
    }
    let retry_endpoint_count = endpoint_last_use
        .iter()
        .filter(|last| last.is_some())
        .count();
    let low_contrast_retry_ms = retry_started.elapsed().as_millis() as u64;
    drop(retry_frames);

    // CLAHE is a final feature-only recovery attempt. Reuse enhanced features
    // across failed neighboring edges and release each frame at its last use.
    let failed_pairs = edges
        .iter()
        .enumerate()
        .filter_map(|(index, edge)| (edge.reason != 0).then_some(index))
        .collect::<Vec<_>>();
    let mut clahe_retry_feature_count = 0usize;
    let mut last_clahe_use = vec![None; tiles.len()];
    for (use_index, edge_index) in failed_pairs.iter().enumerate() {
        last_clahe_use[edges[*edge_index].from] = Some(use_index);
        last_clahe_use[edges[*edge_index].to] = Some(use_index);
    }
    let mut clahe_frames = (0..tiles.len())
        .map(|_| None)
        .collect::<Vec<Option<NativeFeatures>>>();
    let mut active_clahe_features = 0usize;
    let mut peak_clahe_features = 0usize;
    let mut active_clahe_frames = 0usize;
    let mut peak_clahe_frames = 0usize;
    let clahe_started = std::time::Instant::now();
    for (use_index, edge_index) in failed_pairs.into_iter().enumerate() {
        checkpoint("clahe-retry").map_err(|_| Error::Cancelled)?;
        let (from_index, to_index) = (edges[edge_index].from, edges[edge_index].to);
        for index in [from_index, to_index] {
            if clahe_frames[index].is_none() {
                let frame = NativeFeatures::from_path_with_clahe(
                    &tiles[index].path,
                    maximum_pixels,
                    thread_limit,
                    retry_contrast_threshold,
                    feature_type == "orb",
                );
                active_clahe_features += feature_count(&frame);
                active_clahe_frames += 1;
                peak_clahe_features = peak_clahe_features.max(active_clahe_features);
                peak_clahe_frames = peak_clahe_frames.max(active_clahe_frames);
                clahe_frames[index] = Some(frame);
            }
        }
        let (Some(from), Some(to)) = (
            clahe_frames[from_index].as_ref(),
            clahe_frames[to_index].as_ref(),
        ) else {
            continue;
        };
        let edge = &mut edges[edge_index];
        clahe_retry_feature_count += from.count + to.count;
        let clahe_guard = FeatureBatchGuard::begin()?;
        let clahe = match_spherical_pair(
            edge.from,
            edge.to,
            &from,
            &to,
            retry_contrast_threshold,
            true,
            matcher_type == "flann",
            clahe_guard.token(),
        );
        drop(clahe_guard);
        edge.clahe_retry = Some(SphericalMatchAttempt {
            from_features: clahe.from_features,
            to_features: clahe.to_features,
            matches: clahe.matches,
            inliers: clahe.inliers,
            inlier_ratio: clahe.inlier_ratio,
            reason: clahe.reason,
            contrast_threshold: retry_contrast_threshold,
            clahe: true,
        });
        if clahe.reason == 0 {
            edge.from_features = clahe.from_features;
            edge.to_features = clahe.to_features;
            edge.matches = clahe.matches;
            edge.inliers = clahe.inliers;
            edge.inlier_ratio = clahe.inlier_ratio;
            edge.homography_residual = clahe.homography_residual;
            edge.reason = clahe.reason;
            edge.points = clahe.points;
            edge.used_clahe_retry = true;
            edge.used_retry = false;
        }
        for index in [from_index, to_index] {
            if last_clahe_use[index] == Some(use_index) {
                if let Some(frame) = clahe_frames[index].take() {
                    active_clahe_features -= feature_count(&frame);
                    active_clahe_frames -= 1;
                }
            }
        }
    }
    let clahe_retry_ms = clahe_started.elapsed().as_millis() as u64;
    Ok((
        edges,
        primary_feature_count,
        retry_feature_count,
        retry_endpoint_count,
        peak_retry_features,
        peak_retry_frames,
        clahe_retry_feature_count,
        peak_clahe_features,
        peak_clahe_frames,
        initial_matching_ms,
        low_contrast_retry_ms,
        clahe_retry_ms,
    ))
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Offset {
    pub x: i32,
    pub y: i32,
}

/// Row-major projective transform from tile-local pixels to global panorama
/// coordinates. Homogeneous scale is normalized when possible.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProjectiveTransform {
    pub matrix: [f64; 9],
}

impl ProjectiveTransform {
    pub const IDENTITY: Self = Self {
        matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    };

    pub fn translation(x: f64, y: f64) -> Self {
        Self {
            matrix: [1.0, 0.0, x, 0.0, 1.0, y, 0.0, 0.0, 1.0],
        }
    }

    pub fn multiply(self, rhs: Self) -> Self {
        let mut matrix = [0.0; 9];
        for row in 0..3 {
            for column in 0..3 {
                matrix[row * 3 + column] = (0..3)
                    .map(|k| self.matrix[row * 3 + k] * rhs.matrix[k * 3 + column])
                    .sum();
            }
        }
        Self { matrix }.normalized()
    }

    pub fn inverse(self) -> Option<Self> {
        let m = self.matrix;
        let determinant = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6])
            + m[2] * (m[3] * m[7] - m[4] * m[6]);
        if !determinant.is_finite() || determinant.abs() < 1e-12 {
            return None;
        }
        let inverse = [
            (m[4] * m[8] - m[5] * m[7]) / determinant,
            (m[2] * m[7] - m[1] * m[8]) / determinant,
            (m[1] * m[5] - m[2] * m[4]) / determinant,
            (m[5] * m[6] - m[3] * m[8]) / determinant,
            (m[0] * m[8] - m[2] * m[6]) / determinant,
            (m[2] * m[3] - m[0] * m[5]) / determinant,
            (m[3] * m[7] - m[4] * m[6]) / determinant,
            (m[1] * m[6] - m[0] * m[7]) / determinant,
            (m[0] * m[4] - m[1] * m[3]) / determinant,
        ];
        inverse
            .iter()
            .all(|value| value.is_finite())
            .then(|| Self { matrix: inverse }.normalized())
    }

    pub fn transform_point(self, x: f64, y: f64) -> Option<(f64, f64)> {
        let m = self.matrix;
        let denominator = m[6] * x + m[7] * y + m[8];
        if !denominator.is_finite() || denominator.abs() < 1e-12 {
            return None;
        }
        let output = (
            (m[0] * x + m[1] * y + m[2]) / denominator,
            (m[3] * x + m[4] * y + m[5]) / denominator,
        );
        (output.0.is_finite() && output.1.is_finite()).then_some(output)
    }

    fn normalized(mut self) -> Self {
        let scale = self.matrix[8];
        if scale.is_finite() && scale.abs() >= 1e-12 {
            for value in &mut self.matrix {
                *value /= scale;
            }
        }
        self
    }

    fn approximates_translation(
        self,
        dx: f64,
        dy: f64,
        width: f64,
        height: f64,
        tolerance: f64,
    ) -> bool {
        [(0.0, 0.0), (width, 0.0), (0.0, height), (width, height)]
            .into_iter()
            .all(|(x, y)| {
                self.transform_point(x, y).is_some_and(|point| {
                    (point.0 - (x + dx)).abs() <= tolerance
                        && (point.1 - (y + dy)).abs() <= tolerance
                })
            })
    }
}

pub(crate) struct NativeFeatures {
    ptr: *mut c_void,
    count: usize,
}
pub(crate) struct FeatureBatchGuard(*mut c_void);
impl FeatureBatchGuard {
    pub(crate) fn begin() -> Result<Self> {
        let ptr = unsafe { lg_sift_batch_begin() };
        if ptr.is_null() {
            Err(Error::Registration(
                "could not initialize bounded OpenCV feature batch".into(),
            ))
        } else {
            Ok(Self(ptr))
        }
    }
    fn token(&self) -> usize {
        self.0 as usize
    }
}
impl Drop for FeatureBatchGuard {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { lg_sift_batch_end(self.0) };
            self.0 = std::ptr::null_mut();
        }
    }
}
// SAFETY: the opaque native guard remains immutable while scoped worker threads
// use it; its lock is acquired/released only by the creating thread, after all
// workers join. Workers merely pass the token to the native batch extractor.
unsafe impl Sync for FeatureBatchGuard {}

impl NativeFeatures {
    pub(crate) fn from_path_in_batch(
        path: &Path,
        maximum_pixels: usize,
        guard: &FeatureBatchGuard,
        use_orb: bool,
    ) -> Self {
        let Ok(path) = CString::new(path.to_string_lossy().as_bytes()) else {
            return Self {
                ptr: std::ptr::null_mut(),
                count: 0,
            };
        };
        let mut count = 0;
        let ptr = unsafe {
            lg_sift_features_create_batch(
                path.as_ptr(),
                &mut count,
                maximum_pixels,
                0.015,
                guard.0,
                i32::from(use_orb),
            )
        };
        Self {
            ptr,
            count: count.max(0) as usize,
        }
    }

    pub(crate) fn from_path_with_clahe(
        path: &Path,
        maximum_pixels: usize,
        thread_limit: i32,
        contrast_threshold: f64,
        use_orb: bool,
    ) -> Self {
        let Ok(path) = CString::new(path.to_string_lossy().as_bytes()) else {
            return Self {
                ptr: std::ptr::null_mut(),
                count: 0,
            };
        };
        let mut count = 0;
        let ptr = unsafe {
            lg_sift_features_create_bounded_clahe(
                path.as_ptr(),
                &mut count,
                maximum_pixels,
                thread_limit,
                contrast_threshold,
                i32::from(use_orb),
            )
        };
        Self {
            ptr,
            count: count.max(0) as usize,
        }
    }

    pub(crate) fn from_path_with_contrast(
        path: &Path,
        maximum_pixels: usize,
        thread_limit: i32,
        contrast_threshold: f64,
        use_orb: bool,
    ) -> Self {
        let Ok(path) = CString::new(path.to_string_lossy().as_bytes()) else {
            return Self {
                ptr: std::ptr::null_mut(),
                count: 0,
            };
        };
        let mut count = 0;
        let ptr = unsafe {
            lg_sift_features_create_bounded_contrast(
                path.as_ptr(),
                &mut count,
                maximum_pixels,
                thread_limit,
                contrast_threshold,
                i32::from(use_orb),
            )
        };
        Self {
            ptr,
            count: count.max(0) as usize,
        }
    }

    pub(crate) fn from_path_with_settings(
        path: &Path,
        maximum_pixels: usize,
        thread_limit: i32,
    ) -> Self {
        let Ok(path) = CString::new(path.to_string_lossy().as_bytes()) else {
            return Self {
                ptr: std::ptr::null_mut(),
                count: 0,
            };
        };
        let mut count = 0;
        let ptr = unsafe {
            if maximum_pixels == 120_000 && thread_limit == 0 {
                lg_sift_features_create(path.as_ptr(), &mut count)
            } else {
                lg_sift_features_create_bounded(
                    path.as_ptr(),
                    &mut count,
                    maximum_pixels,
                    thread_limit,
                )
            }
        };
        Self {
            ptr,
            count: count.max(0) as usize,
        }
    }
    pub(crate) fn is_valid(&self) -> bool {
        !self.ptr.is_null()
    }
}
impl Drop for NativeFeatures {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { lg_sift_features_destroy(self.ptr) };
            self.ptr = std::ptr::null_mut();
        }
    }
}
unsafe impl Send for NativeFeatures {}
// SAFETY: native frames are immutable after construction; the shared native
// mutex prevents matching from overlapping extraction or global thread edits.
unsafe impl Sync for NativeFeatures {}

#[derive(Clone, Debug)]
struct Edge {
    from: usize,
    to: usize,
    expected_x: f64,
    expected_y: f64,
    dx: f64,
    dy: f64,
    homography: ProjectiveTransform,
    inliers: usize,
    matches: usize,
    ratio: f64,
    residual: f64,
    visual: bool,
    accepted: bool,
    horizontal: bool,
    reason: &'static str,
}

pub struct Registration {
    pub offsets: Vec<Offset>,
    pub transforms: Vec<ProjectiveTransform>,
    pub report: StitchReport,
}

pub(crate) fn feature_count(frame: &NativeFeatures) -> usize {
    if frame.is_valid() {
        unsafe { lg_sift_features_count(frame.ptr) }.max(0) as usize
    } else {
        frame.count
    }
}

pub(crate) fn spherical_extract_features_parallel(
    paths: &[PathBuf],
    maximum_pixels: usize,
    workers: usize,
    feature_type: &str,
    checkpoint: &mut dyn FnMut(&str) -> std::result::Result<(), String>,
) -> Result<Vec<NativeFeatures>> {
    if workers == 0 || workers > 32 {
        return Err(Error::Invalid(
            "feature workers must be between 1 and 32".into(),
        ));
    }
    let effective_workers = workers.min(paths.len().max(1));
    let guard = FeatureBatchGuard::begin()?;
    let mut features = Vec::with_capacity(paths.len());
    for batch in paths.chunks(effective_workers) {
        checkpoint("feature-extraction-batch").map_err(|_| Error::Cancelled)?;
        let mut results = std::thread::scope(|scope| {
            let handles = batch
                .iter()
                .map(|path| {
                    let guard = &guard;
                    scope.spawn(move || {
                        NativeFeatures::from_path_in_batch(
                            path,
                            maximum_pixels,
                            guard,
                            feature_type == "orb",
                        )
                    })
                })
                .collect::<Vec<_>>();
            handles
                .into_iter()
                .map(|handle| handle.join())
                .collect::<Vec<_>>()
        });
        for result in results.drain(..) {
            let frame =
                result.map_err(|_| Error::Registration("feature worker panicked".into()))?;
            if !frame.is_valid() {
                return Err(Error::Registration(
                    "native feature extraction failed for spherical tile".into(),
                ));
            }
            features.push(frame);
        }
    }
    checkpoint("feature-extraction-complete").map_err(|_| Error::Cancelled)?;
    drop(guard);
    Ok(features)
}

fn expected_shift(
    a: &CaptureGeometry,
    b: &CaptureGeometry,
    horizontal: bool,
    pixels: f64,
    _overlap: f32,
) -> Option<(f64, f64)> {
    let (angle_a, angle_b, fov_a, fov_b) = if horizontal {
        (a.pan_deg?, b.pan_deg?, a.fov_x_deg?, b.fov_x_deg?)
    } else {
        (a.tilt_deg?, b.tilt_deg?, a.fov_y_deg?, b.fov_y_deg?)
    };
    if fov_a <= 0.0 || fov_b <= 0.0 {
        return None;
    }
    let step = (angle_b - angle_a).abs() / ((fov_a + fov_b) * 0.5) * pixels;
    if !step.is_finite() || step <= 0.0 {
        return None;
    }
    // Grid neighbors are composed in image coordinates. The Dart engine's
    // capture ordering defines the target frame shift as negative along the
    // traversed axis; commanded angle direction is metadata for scale only.
    if horizontal {
        Some((-step, 0.0))
    } else {
        Some((0.0, -step))
    }
}

fn nominal_shift(
    a: &CaptureTile,
    b: &CaptureTile,
    horizontal: bool,
    width: f64,
    height: f64,
    opts: &StitchOptions,
) -> (f64, f64) {
    let measured = match (&a.geometry, &b.geometry) {
        (Some(ga), Some(gb)) => expected_shift(
            ga,
            gb,
            horizontal,
            if horizontal { width } else { height },
            if horizontal {
                opts.overlap_x
            } else {
                opts.overlap_y
            },
        ),
        _ => None,
    };
    measured.unwrap_or_else(|| {
        if horizontal {
            (-(width * (1.0 - opts.overlap_x as f64)), 0.0)
        } else {
            (0.0, -(height * (1.0 - opts.overlap_y as f64)))
        }
    })
}

fn reason(reason: i32, matches: usize, inliers: usize) -> &'static str {
    match reason {
        1 => "NO_DESCRIPTORS",
        2 => "TOO_FEW_MUTUAL_RATIO_MATCHES",
        3 => "RANSAC_FAILED",
        _ if matches > 0 && inliers < 10 => "LOW_INLIER_SUPPORT",
        _ => "REGISTRATION_FAILED",
    }
}

fn visual_accept(edge: &Edge, width: f64, height: f64, min_features: usize) -> bool {
    // Real 20-tile scans exposed geometrically extreme homographies backed by
    // only 12–15 repeated-texture inliers. Keep the caller threshold, but
    // never promote a full projective model from fewer than 16 correspondences.
    let minimum_inliers = min_features.max(16);
    let minimum_matches = minimum_inliers;
    if !edge.visual
        || edge.matches < minimum_matches
        || edge.inliers < minimum_inliers
        || edge.ratio < 0.25
    {
        return false;
    }
    let prior_consistent = (edge.dx - edge.expected_x).abs() <= 24.0_f64.max(width * 0.40)
        && (edge.dy - edge.expected_y).abs() <= 18.0_f64.max(height * 0.35);
    let along = if edge.horizontal { edge.dx } else { edge.dy };
    let across = if edge.horizontal { edge.dy } else { edge.dx };
    let extent = if edge.horizontal { width } else { height };
    let cross_extent = if edge.horizontal { height } else { width };
    let expected_along = if edge.horizontal {
        edge.expected_x
    } else {
        edge.expected_y
    };
    let neighbor_like = along.abs() >= 8.0
        && along.abs() <= extent * 0.95
        && across.abs() <= 18.0_f64.max(cross_extent * 0.45)
        && (expected_along.abs() < 1e-6 || along.signum() == expected_along.signum());
    prior_consistent || neighbor_like
}

fn transform_is_safe(transform: ProjectiveTransform, width: f64, height: f64) -> bool {
    if transform.inverse().is_none() {
        return false;
    }
    let Some(points) = [
        transform.transform_point(0.0, 0.0),
        transform.transform_point(width, 0.0),
        transform.transform_point(width, height),
        transform.transform_point(0.0, height),
    ]
    .into_iter()
    .collect::<Option<Vec<_>>>() else {
        return false;
    };
    let signed_area = points
        .iter()
        .zip(points.iter().cycle().skip(1))
        .take(4)
        .map(|(a, b)| a.0 * b.1 - b.0 * a.1)
        .sum::<f64>()
        * 0.5;
    if !signed_area.is_finite() || signed_area <= 1e-6 {
        return false;
    }
    let source_lengths = [width, height, width, height];
    points
        .iter()
        .zip(points.iter().cycle().skip(1))
        .take(4)
        .zip(source_lengths)
        .all(|((a, b), source_length)| {
            let scale = (b.0 - a.0).hypot(b.1 - a.1) / source_length.max(1.0);
            scale.is_finite() && (0.1..=10.0).contains(&scale)
        })
}

/// Translation solving supplies legacy offsets and explicit unsafe-transform fallback.
/// Valid visual transforms retain the spanning tree's complete projective mapping.
fn place_edges(
    edges: &[Edge],
    tile_count: usize,
    width: f64,
    height: f64,
    report: &mut StitchReport,
) -> (Vec<Offset>, Vec<ProjectiveTransform>) {
    let mut positions = vec![Offset::default(); tile_count];
    let mut x = vec![0.0f64; tile_count];
    let mut y = vec![0.0f64; tile_count];
    let mut placed = vec![false; tile_count];
    placed[0] = true;
    let mut pending = VecDeque::from([0usize]);
    while let Some(current) = pending.pop_front() {
        for edge in edges {
            if !edge.accepted {
                continue;
            }
            if edge.from == current && !placed[edge.to] {
                x[edge.to] = x[current] - edge.dx;
                y[edge.to] = y[current] - edge.dy;
                placed[edge.to] = true;
                pending.push_back(edge.to);
            } else if edge.to == current && !placed[edge.from] {
                x[edge.from] = x[current] + edge.dx;
                y[edge.from] = y[current] + edge.dy;
                placed[edge.from] = true;
                pending.push_back(edge.from);
            }
        }
    }
    let constraints = edges.iter().filter(|e| e.accepted).collect::<Vec<_>>();
    for _ in 0..80 {
        let mut sx = vec![0.0; tile_count];
        let mut sy = vec![0.0; tile_count];
        let mut sw = vec![0.0; tile_count];
        for e in &constraints {
            let w = (e.inliers.max(1) as f64).sqrt();
            sx[e.to] += (x[e.from] - e.dx) * w;
            sy[e.to] += (y[e.from] - e.dy) * w;
            sw[e.to] += w;
            sx[e.from] += (x[e.to] + e.dx) * w;
            sy[e.from] += (y[e.to] + e.dy) * w;
            sw[e.from] += w;
        }
        for i in 1..tile_count {
            if sw[i] > 0.0 {
                x[i] = x[i] * 0.35 + sx[i] / sw[i] * 0.65;
                y[i] = y[i] * 0.35 + sy[i] / sw[i] * 0.65;
            }
        }
    }
    for i in 0..tile_count {
        positions[i] = Offset {
            x: x[i].round() as i32,
            y: y[i].round() as i32,
        };
    }
    let mut transforms = vec![ProjectiveTransform::IDENTITY; tile_count];
    let mut transformed = vec![false; tile_count];
    transformed[0] = true;
    // Grow a maximum-confidence spanning tree. Iterating row-major made a
    // weak edge near the top-left define an entire downstream column even
    // when stronger alternate paths existed.
    while transformed.iter().any(|value| !value) {
        let best = edges
            .iter()
            .filter(|edge| edge.accepted && (transformed[edge.from] ^ transformed[edge.to]))
            .max_by(|left, right| {
                let score = |edge: &&Edge| {
                    edge.inliers as f64 * edge.ratio / (1.0 + edge.residual.max(0.0))
                };
                score(left).total_cmp(&score(right))
            });
        let Some(edge) = best else {
            break;
        };
        if transformed[edge.from] {
            let inverse = edge.homography.inverse().unwrap_or_else(|| {
                report.warnings.push(format!(
                    "edge {} -> {} homography was singular during propagation; used translation",
                    edge.from, edge.to
                ));
                ProjectiveTransform::translation(-edge.dx, -edge.dy)
            });
            transforms[edge.to] = transforms[edge.from].multiply(inverse);
            transformed[edge.to] = true;
        } else {
            transforms[edge.from] = transforms[edge.to].multiply(edge.homography);
            transformed[edge.from] = true;
        }
    }
    for i in 0..tile_count {
        // Median feature displacement is not the transformed origin for a scale,
        // rotation or perspective change. Keep the complete propagated homography.
        if !transform_is_safe(transforms[i], width, height) {
            transforms[i] = ProjectiveTransform::translation(x[i], y[i]);
            report.transform_fallback_count += 1;
            report.warnings.push(format!(
                "tile {} transform was non-finite, singular, flipped, or extreme; used translation",
                i
            ));
        }
    }
    (positions, transforms)
}

impl Registration {
    pub fn new(_opts: StitchOptions) -> Self {
        Self {
            offsets: Vec::new(),
            transforms: Vec::new(),
            report: StitchReport {
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
            },
        }
    }

    pub(crate) fn compute(
        opts: StitchOptions,
        tiles: &[CaptureTile],
        frames: &[NativeFeatures],
        cancel: &crate::CancellationToken,
    ) -> Result<Self> {
        let mut out = Self::new(opts.clone());
        out.report.feature_count = frames.iter().map(feature_count).sum();
        out.report.total_tile_count = tiles.len();
        if tiles.is_empty() {
            return Err(Error::Invalid("no tiles".into()));
        }
        let first = crate::image::load(&tiles[0].path)?;
        out.report.registration_width = first.width();
        out.report.registration_height = first.height();
        let expected = opts.rows.saturating_mul(opts.columns);
        if expected != tiles.len() {
            return Err(Error::Registration(format!(
                "incomplete grid: expected {expected} tiles, got {}",
                tiles.len()
            )));
        }
        let mut index_by_cell = HashMap::new();
        for (i, t) in tiles.iter().enumerate() {
            if t.row >= opts.rows
                || t.column >= opts.columns
                || index_by_cell.insert((t.row, t.column), i).is_some()
            {
                return Err(Error::Registration(
                    "duplicate or out-of-range tile cell".into(),
                ));
            }
        }
        if index_by_cell.len() != expected {
            return Err(Error::Registration("grid contains missing cells".into()));
        }
        let mut edges = Vec::new();
        for row in 0..opts.rows {
            for col in 0..opts.columns {
                let from = index_by_cell[&(row, col)];
                for (to_cell, horizontal) in [((row, col + 1), true), ((row + 1, col), false)] {
                    if (horizontal && col + 1 >= opts.columns)
                        || (!horizontal && row + 1 >= opts.rows)
                    {
                        continue;
                    }
                    let to = index_by_cell[&to_cell];
                    if cancel.is_cancelled() {
                        return Err(Error::Cancelled);
                    }
                    let expected_shift = nominal_shift(
                        &tiles[from],
                        &tiles[to],
                        horizontal,
                        first.width() as f64,
                        first.height() as f64,
                        &opts,
                    );
                    let mut dx = 0.0;
                    let mut dy = 0.0;
                    let mut homography = ProjectiveTransform::IDENTITY.matrix;
                    let mut ratio = 0.0;
                    let mut residual = 0.0;
                    let mut matches = 0;
                    let mut inliers = 0;
                    let mut why = 0;
                    let visual = unsafe {
                        lg_sift_match(
                            frames[from].ptr,
                            frames[to].ptr,
                            expected_shift.0,
                            expected_shift.1,
                            first.width() as f64,
                            first.height() as f64,
                            homography.as_mut_ptr(),
                            &mut dx,
                            &mut dy,
                            &mut ratio,
                            &mut residual,
                            &mut matches,
                            &mut inliers,
                            &mut why,
                        ) != 0
                    };
                    edges.push(Edge {
                        from,
                        to,
                        expected_x: expected_shift.0,
                        expected_y: expected_shift.1,
                        dx,
                        dy,
                        homography: ProjectiveTransform { matrix: homography },
                        inliers: inliers.max(0) as usize,
                        matches: matches.max(0) as usize,
                        ratio,
                        residual,
                        visual,
                        accepted: false,
                        horizontal,
                        reason: reason(why, matches.max(0) as usize, inliers.max(0) as usize),
                    });
                }
            }
        }
        let mut horizontal_ratios = Vec::new();
        let mut vertical_ratios = Vec::new();
        for edge in &mut edges {
            edge.accepted = visual_accept(
                edge,
                first.width() as f64,
                first.height() as f64,
                opts.min_features,
            );
            if edge.accepted
                && edge.homography.approximates_translation(
                    edge.dx,
                    edge.dy,
                    first.width() as f64,
                    first.height() as f64,
                    0.5,
                )
            {
                edge.homography = ProjectiveTransform::translation(edge.dx, edge.dy);
            }
            if edge.accepted {
                let prior_consistent = (edge.dx - edge.expected_x).abs()
                    <= 24.0_f64.max(first.width() as f64 * 0.40)
                    && (edge.dy - edge.expected_y).abs()
                        <= 18.0_f64.max(first.height() as f64 * 0.35);
                edge.reason = if prior_consistent {
                    "MATCHED"
                } else {
                    "MATCHED_WITHOUT_PRIOR"
                };
                let measured = if edge.horizontal { edge.dx } else { edge.dy };
                let expected = if edge.horizontal {
                    edge.expected_x
                } else {
                    edge.expected_y
                };
                if expected.abs() > 1e-6 && measured.is_finite() {
                    if edge.horizontal {
                        horizontal_ratios.push(measured.abs() / expected.abs());
                    } else {
                        vertical_ratios.push(measured.abs() / expected.abs());
                    }
                }
            }
        }
        let median = |v: &mut Vec<f64>| -> f64 {
            if v.is_empty() {
                f64::NAN
            } else {
                v.sort_by(f64::total_cmp);
                v[v.len() / 2]
            }
        };
        let hs = median(&mut horizontal_ratios);
        let vs = median(&mut vertical_ratios);
        let visual_h = horizontal_ratios.len();
        let visual_v = vertical_ratios.len();
        let mad = |values: &[f64], center: f64| -> f64 {
            if values.is_empty() || !center.is_finite() {
                return f64::NAN;
            }
            let mut deviations = values
                .iter()
                .map(|value| (value - center).abs())
                .collect::<Vec<_>>();
            median(&mut deviations)
        };
        let hmad = mad(&horizontal_ratios, hs);
        let vmad = mad(&vertical_ratios, vs);
        for edge in &mut edges {
            if edge.accepted {
                continue;
            }
            let scale = if edge.horizontal { hs } else { vs };
            let support = if edge.horizontal { visual_h } else { visual_v };
            let expected = if edge.horizontal {
                edge.expected_x
            } else {
                edge.expected_y
            };
            let spread = if edge.horizontal { hmad } else { vmad };
            if support >= 3
                && scale.is_finite()
                && scale > 0.0
                && expected.abs() > 1e-6
                && expected.abs() * scale
                    <= if edge.horizontal {
                        first.width() as f64
                    } else {
                        first.height() as f64
                    }
            {
                let step = expected.abs() * scale;
                if edge.horizontal {
                    edge.dx = if expected.signum() == 0.0 {
                        -step
                    } else {
                        expected.signum() * step
                    };
                    edge.dy = 0.0;
                } else {
                    edge.dy = if expected.signum() == 0.0 {
                        -step
                    } else {
                        expected.signum() * step
                    };
                    edge.dx = 0.0;
                }
                edge.accepted = true;
                edge.reason = "NOMINAL_PTZ_FALLBACK";
                edge.homography = ProjectiveTransform::translation(edge.dx, edge.dy);
                if spread.is_finite() && spread > scale * 0.35 {
                    out.report.warnings.push(format!(
                        "nominal fallback edge {} -> {} used relaxed directional MAD",
                        edge.from, edge.to
                    ));
                }
            } else {
                edge.reason = if support < 3 {
                    "NOMINAL_PTZ_INSUFFICIENT_VISUAL_SUPPORT"
                } else {
                    "NOMINAL_PTZ_INVALID_SCALE"
                };
            }
        }
        let mut adjacency = vec![Vec::<usize>::new(); tiles.len()];
        for edge in &edges {
            if edge.accepted {
                adjacency[edge.from].push(edge.to);
                adjacency[edge.to].push(edge.from);
            }
        }
        let mut visited = vec![false; tiles.len()];
        let mut queue = VecDeque::from([0usize]);
        while let Some(i) = queue.pop_front() {
            if visited[i] {
                continue;
            }
            visited[i] = true;
            queue.extend(adjacency[i].iter().copied().filter(|j| !visited[*j]));
        }
        let connected = visited.iter().all(|v| *v);
        out.report.matched_edges = edges
            .iter()
            .filter(|e| e.accepted && e.reason != "NOMINAL_PTZ_FALLBACK")
            .count();
        out.report.nominal_fallback_edges = edges
            .iter()
            .filter(|e| e.accepted && e.reason == "NOMINAL_PTZ_FALLBACK")
            .count();
        out.report.failed_edges = edges.iter().filter(|e| !e.accepted).count();
        let mut visual_adjacency = vec![Vec::<usize>::new(); tiles.len()];
        let mut residuals: Vec<f64> = Vec::new();
        let mut ratio_sum = 0.0;
        for edge in &edges {
            if edge.accepted && edge.visual && edge.reason != "NOMINAL_PTZ_FALLBACK" {
                visual_adjacency[edge.from].push(edge.to);
                visual_adjacency[edge.to].push(edge.from);
                ratio_sum += edge.ratio;
                if edge.residual.is_finite() {
                    residuals.push(edge.residual);
                }
            }
            out.report.edges.push(StitchEdgeReport {
                from_row: tiles[edge.from].row,
                from_column: tiles[edge.from].column,
                to_row: tiles[edge.to].row,
                to_column: tiles[edge.to].column,
                accepted: edge.accepted,
                nominal_fallback: edge.accepted && edge.reason == "NOMINAL_PTZ_FALLBACK",
                matches: edge.matches,
                inliers: edge.inliers,
                inlier_ratio: edge.ratio,
                median_dx: edge.dx,
                median_dy: edge.dy,
                homography_from_to: edge.homography.matrix,
                median_residual: edge.residual,
                reason: edge.reason.to_string(),
            });
        }
        let mut visual_seen = vec![false; tiles.len()];
        let mut visual_queue = VecDeque::from([0usize]);
        while let Some(i) = visual_queue.pop_front() {
            if visual_seen[i] {
                continue;
            }
            visual_seen[i] = true;
            visual_queue.extend(
                visual_adjacency[i]
                    .iter()
                    .copied()
                    .filter(|j| !visual_seen[*j]),
            );
        }
        residuals.sort_by(f64::total_cmp);
        out.report.connected = connected;
        out.report.connected_tile_count = visited.iter().filter(|value| **value).count();
        out.report.visual_connected = visual_seen.iter().all(|v| *v);
        out.report.average_inlier_ratio = if out.report.matched_edges == 0 {
            0.0
        } else {
            ratio_sum / out.report.matched_edges as f64
        };
        out.report.median_residual = residuals
            .get(residuals.len() / 2)
            .copied()
            .unwrap_or(f64::NAN);
        out.report.p95_residual = if residuals.is_empty() {
            f64::NAN
        } else {
            residuals[((residuals.len() - 1) * 95) / 100]
        };
        for edge in &edges {
            if !edge.accepted {
                out.report.warnings.push(format!(
                    "edge {} -> {} failed: {} (matches={}, inliers={}, ratio={:.3})",
                    edge.from, edge.to, edge.reason, edge.matches, edge.inliers, edge.ratio
                ));
            }
        }
        if !connected {
            out.report.warnings.push(format!(
                "validated registration graph disconnected: {}/{} tiles reachable",
                visited.iter().filter(|v| **v).count(),
                tiles.len()
            ));
            return Err(Error::RegistrationReport {
                message: "validated registration graph is disconnected".into(),
                report: Box::new(out.report.clone()),
            });
        }
        if out.report.failed_edges > 0 {
            out.report.warnings.push(format!(
                "{} neighbor edges were not resolved",
                out.report.failed_edges
            ));
        }
        let (positions, transforms) = place_edges(
            &edges,
            tiles.len(),
            first.width() as f64,
            first.height() as f64,
            &mut out.report,
        );
        out.offsets = positions;
        out.transforms = transforms;
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::{place_edges, Edge, ProjectiveTransform, Registration};
    use crate::metadata::StitchOptions;

    fn close(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "{a} != {b}");
    }

    #[test]
    fn inverse_and_direction_compose_from_to_into_global() {
        let h_from_to = ProjectiveTransform {
            matrix: [1.02, 0.03, -40.0, -0.01, 0.98, 7.0, 0.0002, -0.0001, 1.0],
        };
        let g_from = ProjectiveTransform::translation(12.0, 5.0);
        let g_to = g_from.multiply(h_from_to.inverse().unwrap());
        let local_from = (31.0, 17.0);
        let local_to = h_from_to
            .transform_point(local_from.0, local_from.1)
            .unwrap();
        let world_from = g_from.transform_point(local_from.0, local_from.1).unwrap();
        let world_to = g_to.transform_point(local_to.0, local_to.1).unwrap();
        close(world_from.0, world_to.0);
        close(world_from.1, world_to.1);
    }

    fn measured_edge(from: usize, to: usize, homography: ProjectiveTransform) -> Edge {
        // Model median feature flow at an off-origin scene point, as the matcher
        // reports. It differs from origin displacement for non-translations.
        let target = homography
            .transform_point(200.0, 150.0)
            .unwrap_or((170.0, 155.0));
        Edge {
            from,
            to,
            expected_x: 0.0,
            expected_y: 0.0,
            dx: target.0 - 200.0,
            dy: target.1 - 150.0,
            homography,
            inliers: 100,
            matches: 110,
            ratio: 0.9,
            residual: 0.1,
            visual: true,
            accepted: true,
            horizontal: true,
            reason: "MATCHED",
        }
    }

    fn assert_correspondences_coincide(edges: &[Edge], transforms: &[ProjectiveTransform]) {
        for edge in edges {
            for local in [(80.0, 60.0), (240.0, 180.0), (400.0, 280.0)] {
                let corresponding = edge.homography.transform_point(local.0, local.1).unwrap();
                let a = transforms[edge.from]
                    .transform_point(local.0, local.1)
                    .unwrap();
                let b = transforms[edge.to]
                    .transform_point(corresponding.0, corresponding.1)
                    .unwrap();
                assert!(
                    (a.0 - b.0).hypot(a.1 - b.1) < 1e-8,
                    "matched scene point split across tiles {} -> {}: {a:?} vs {b:?}",
                    edge.from,
                    edge.to
                );
            }
        }
    }

    #[test]
    fn two_tile_scale_rotation_preserves_scene_point_alignment() {
        let edge = measured_edge(
            0,
            1,
            ProjectiveTransform {
                matrix: [1.04, -0.06, -50.0, 0.06, 1.04, 12.0, 0.0, 0.0, 1.0],
            },
        );
        let mut report = Registration::new(StitchOptions::default()).report;
        let (offsets, transforms) = place_edges(&[edge.clone()], 2, 640.0, 480.0, &mut report);
        assert_correspondences_coincide(&[edge], &transforms);
        let origin = transforms[1].transform_point(0.0, 0.0).unwrap();
        assert!((origin.0 - offsets[1].x as f64).hypot(origin.1 - offsets[1].y as f64) > 5.0);
        assert_eq!(report.transform_fallback_count, 0);
    }

    #[test]
    fn consistent_projective_grid_aligns_all_edges_including_non_tree_edge() {
        let globals = [
            ProjectiveTransform::IDENTITY,
            ProjectiveTransform {
                matrix: [1.03, -0.04, 80.0, 0.04, 1.03, 6.0, 0.00002, 0.0, 1.0],
            },
            ProjectiveTransform {
                matrix: [0.98, 0.02, 8.0, -0.02, 0.98, 65.0, 0.0, -0.00002, 1.0],
            },
            ProjectiveTransform {
                matrix: [1.01, -0.03, 90.0, 0.03, 1.01, 70.0, 0.00001, -0.00001, 1.0],
            },
        ];
        let edges = [(0, 1), (0, 2), (1, 3), (2, 3)].map(|(from, to)| {
            measured_edge(
                from,
                to,
                globals[to].inverse().unwrap().multiply(globals[from]),
            )
        });
        let mut report = Registration::new(StitchOptions::default()).report;
        let (_, transforms) = place_edges(&edges, 4, 640.0, 480.0, &mut report);
        assert_correspondences_coincide(&edges, &transforms);
        assert_eq!(report.transform_fallback_count, 0);
    }

    #[test]
    fn pure_translation_and_explicit_fallback_keep_legacy_positions() {
        let mut report = Registration::new(StitchOptions::default()).report;
        let edge = measured_edge(0, 1, ProjectiveTransform::translation(-50.0, 7.0));
        let (offsets, transforms) = place_edges(&[edge], 2, 640.0, 480.0, &mut report);
        assert_eq!(transforms[1], ProjectiveTransform::translation(50.0, -7.0));
        assert_eq!((offsets[1].x, offsets[1].y), (50, -7));
        let flipped = measured_edge(
            0,
            1,
            ProjectiveTransform {
                matrix: [-1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
            },
        );
        let (offsets, transforms) = place_edges(&[flipped], 2, 640.0, 480.0, &mut report);
        assert_eq!(report.transform_fallback_count, 1);
        assert_eq!(
            transforms[1],
            ProjectiveTransform::translation(offsets[1].x as f64, offsets[1].y as f64)
        );
        let singular = measured_edge(0, 1, ProjectiveTransform { matrix: [0.0; 9] });
        let (_, transforms) = place_edges(&[singular], 2, 640.0, 480.0, &mut report);
        assert_eq!(transforms[1], ProjectiveTransform::translation(30.0, -5.0));
        assert!(report
            .warnings
            .iter()
            .any(|warning| warning.contains("singular during propagation")));
    }
}
