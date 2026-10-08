//! Small, bounded spatial regularizer for source ownership in tiled renders.
//!
//! The field is anchored in output pixel coordinates and solved once for the
//! panorama. Its adaptive spacing and hard cell cap bound memory regardless
//! of output resolution; tiles only read the immutable result.

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct OwnershipCandidate {
    pub source: usize,
    pub unary_cost: f32,
    pub color: [u8; 3],
    pub texture: u8,
    pub sharpness: u8,
    pub obstruction: u8,
}

pub(crate) fn adjust_candidates_for_content(
    candidates: &mut [OwnershipCandidate],
    blur_peer_texture: u8,
    blur_peer_sharpness: u8,
    blur_relative_max: f32,
) -> f32 {
    if candidates.len() < 2 {
        return 0.0;
    }
    let mut delta = 0.0f32;
    for left in 0..candidates.len() {
        for right in left + 1..candidates.len() {
            delta = delta.max(content_disagreement(
                candidates[left].color,
                candidates[right].color,
            ));
        }
    }
    let best_sharpness = candidates
        .iter()
        .map(|value| value.sharpness)
        .max()
        .unwrap_or(0);
    let best_texture = candidates
        .iter()
        .map(|value| value.texture)
        .max()
        .unwrap_or(0);
    for candidate in candidates.iter_mut() {
        if best_texture >= blur_peer_texture
            && best_sharpness >= blur_peer_sharpness
            && f32::from(candidate.sharpness) <= f32::from(best_sharpness) * blur_relative_max
        {
            candidate.unary_cost += 0.10;
        }
    }
    delta
}

pub(crate) fn content_disagreement(left: [u8; 3], right: [u8; 3]) -> f32 {
    left.iter()
        .zip(right.iter())
        .map(|(left, right)| f32::from(left.abs_diff(*right)).powi(2))
        .sum::<f32>()
        .sqrt()
        / 441.7
}

#[derive(Clone, Debug)]
pub(crate) struct CoarseOwnershipMap {
    pub width: usize,
    pub height: usize,
    pub stride: usize,
    pub owners: Vec<Option<usize>>,
    pub confidence: Vec<f32>,
    pub prepass_micros: u64,
    pub decoded_sources: u64,
    pub scratch_bytes_reserved: u64,
}

pub(crate) fn coarse_cell_count(width: u32, height: u32, cell_cap: usize) -> usize {
    let stride = coarse_stride(width, height, cell_cap);
    (width as usize).div_ceil(stride) * (height as usize).div_ceil(stride)
}

pub(crate) fn coarse_stride(width: u32, height: u32, cell_cap: usize) -> usize {
    if width == 0 || height == 0 {
        return 1;
    }
    let area = u64::from(width) * u64::from(height);
    let cap = cell_cap.max(1);
    let estimate = ((area as f64 / cap as f64).sqrt().ceil() as usize).max(16);
    if (width as usize).div_ceil(estimate) * (height as usize).div_ceil(estimate) <= cap {
        return estimate;
    }
    let mut low = estimate + 1;
    let mut high = (width.max(height) as usize).max(low);
    while low < high {
        let middle = low + (high - low) / 2;
        let cells = (width as usize).div_ceil(middle) * (height as usize).div_ceil(middle);
        if cells <= cap {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    low
}

impl CoarseOwnershipMap {
    pub fn owner_at(&self, x: u32, y: u32) -> Option<usize> {
        if self.width == 0 || self.height == 0 || self.stride == 0 {
            return None;
        }
        let cell_x = (x as usize / self.stride).min(self.width - 1);
        let cell_y = (y as usize / self.stride).min(self.height - 1);
        self.owners[cell_y * self.width + cell_x]
    }

    /// Return a narrow, output-pixel transition probability for a source at a
    /// coarse-label boundary. Away from a boundary this is exactly one-hot.
    pub fn source_probability(&self, source: usize, x: u32, y: u32, radius: u32) -> f32 {
        if self.width == 0 || self.height == 0 || self.stride == 0 {
            return 1.0;
        }
        let grid_x = x as f32 / self.stride as f32 - 0.5;
        let grid_y = y as f32 / self.stride as f32 - 0.5;
        let base_x = grid_x.floor() as isize;
        let base_y = grid_y.floor() as isize;
        let frac_x = grid_x - base_x as f32;
        let frac_y = grid_y - base_y as f32;
        let mut vote = 0.0f32;
        let mut coverage = 0.0f32;
        for (dx, wx) in [(0, 1.0 - frac_x), (1, frac_x)] {
            for (dy, wy) in [(0, 1.0 - frac_y), (1, frac_y)] {
                let cx = (base_x + dx).clamp(0, self.width as isize - 1) as usize;
                let cy = (base_y + dy).clamp(0, self.height as isize - 1) as usize;
                let weight = wx * wy;
                if let Some(owner) = self.owners[cy * self.width + cx] {
                    coverage += weight;
                    if owner == source {
                        vote += weight;
                    }
                }
            }
        }
        if coverage <= f32::EPSILON {
            return 1.0;
        }
        let probability = vote / coverage;
        let half_band = (radius as f32 / self.stride as f32).clamp(0.001, 0.49);
        ((probability - (0.5 - half_band)) / (2.0 * half_band)).clamp(0.0, 1.0)
    }

    pub fn confidence_at(&self, x: u32, y: u32) -> f32 {
        if self.width == 0 || self.height == 0 || self.stride == 0 {
            return 0.0;
        }
        let grid_x = x as f32 / self.stride as f32 - 0.5;
        let grid_y = y as f32 / self.stride as f32 - 0.5;
        let base_x = grid_x.floor() as isize;
        let base_y = grid_y.floor() as isize;
        let frac_x = grid_x - base_x as f32;
        let frac_y = grid_y - base_y as f32;
        let mut confidence = 0.0f32;
        for (dx, wx) in [(0, 1.0 - frac_x), (1, frac_x)] {
            for (dy, wy) in [(0, 1.0 - frac_y), (1, frac_y)] {
                let cx = (base_x + dx).clamp(0, self.width as isize - 1) as usize;
                let cy = (base_y + dy).clamp(0, self.height as isize - 1) as usize;
                confidence += self.confidence[cy * self.width + cx] * wx * wy;
            }
        }
        confidence.clamp(0.0, 1.0)
    }
}

/// Refine coarse per-cell owners with a deterministic Potts prior. Strong
/// unary evidence is retained; weak geometric wedges are made spatially
/// coherent. The caller supplies stable source ordering for tie breaking.
pub(crate) fn regularize_owners(
    width: usize,
    height: usize,
    candidates: &[Vec<OwnershipCandidate>],
    pairwise_cost: f32,
    iterations: usize,
    mut checkpoint: impl FnMut() -> bool,
) -> Option<Vec<Option<usize>>> {
    assert_eq!(candidates.len(), width.saturating_mul(height));
    let mut owners: Vec<Option<usize>> = candidates
        .iter()
        .map(|cell| {
            cell.iter()
                .min_by(|a, b| {
                    a.unary_cost
                        .total_cmp(&b.unary_cost)
                        .then_with(|| a.source.cmp(&b.source))
                })
                .map(|candidate| candidate.source)
        })
        .collect();
    let pairwise_cost = if pairwise_cost.is_finite() {
        pairwise_cost.max(0.0)
    } else {
        0.0
    };
    for _ in 0..iterations {
        let mut changed = false;
        for y in 0..height {
            if !checkpoint() {
                return None;
            }
            for x in 0..width {
                let index = y * width + x;
                let cell = &candidates[index];
                if cell.len() < 2 {
                    continue;
                }
                let mut best = None;
                let mut best_cost = f32::INFINITY;
                for candidate in cell {
                    let mut cost = candidate.unary_cost;
                    if x > 0 && owners[index - 1].is_some_and(|v| v != candidate.source) {
                        cost += pairwise_cost;
                    }
                    if x + 1 < width && owners[index + 1].is_some_and(|v| v != candidate.source) {
                        cost += pairwise_cost;
                    }
                    if y > 0 && owners[index - width].is_some_and(|v| v != candidate.source) {
                        cost += pairwise_cost;
                    }
                    if y + 1 < height
                        && owners[index + width].is_some_and(|v| v != candidate.source)
                    {
                        cost += pairwise_cost;
                    }
                    if cost < best_cost || (cost == best_cost && Some(candidate.source) < best) {
                        best = Some(candidate.source);
                        best_cost = cost;
                    }
                }
                if best != owners[index] {
                    owners[index] = best;
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }
    Some(owners)
}

#[cfg(test)]
mod tests {
    use super::{
        adjust_candidates_for_content, coarse_cell_count, coarse_stride, content_disagreement,
        regularize_owners, OwnershipCandidate,
    };

    fn candidate(source: usize, cost: f32) -> OwnershipCandidate {
        OwnershipCandidate {
            source,
            unary_cost: cost,
            color: [128; 3],
            texture: 0,
            sharpness: 0,
            obstruction: 0,
        }
    }

    #[test]
    fn weak_isolated_geometric_wedge_is_removed_but_strong_evidence_survives() {
        let mut cells = Vec::new();
        for _ in 0..25 {
            cells.push(vec![candidate(0, 0.0), candidate(1, 0.15)]);
        }
        cells[12] = vec![candidate(0, 0.04), candidate(1, 0.0)];
        let owners = regularize_owners(5, 5, &cells, 0.3, 5, || true).unwrap();
        assert!(owners.iter().all(|owner| *owner == Some(0)));

        cells[12] = vec![candidate(0, 2.0), candidate(1, 0.0)];
        let owners = regularize_owners(5, 5, &cells, 0.3, 5, || true).unwrap();
        assert_eq!(owners[12], Some(1));
    }

    #[test]
    fn deterministic_tie_break_does_not_depend_on_candidate_order() {
        let first = vec![candidate(7, 0.0), candidate(2, 0.0)];
        let second = vec![candidate(2, 0.0), candidate(7, 0.0)];
        assert_eq!(
            regularize_owners(1, 1, &[first], 0.2, 3, || true),
            Some(vec![Some(2)])
        );
        assert_eq!(
            regularize_owners(1, 1, &[second], 0.2, 3, || true),
            Some(vec![Some(2)])
        );
    }

    #[test]
    fn coarse_map_respects_cell_cap_for_skinny_and_large_frames() {
        assert!(coarse_cell_count(4_000_000_000, 1, 1) <= 1);
        assert!(coarse_cell_count(65_536, 65_536, 65_536) <= 65_536);
        assert_eq!(coarse_stride(0, 100, 1), 1);
    }

    #[test]
    fn narrow_transition_is_one_hot_away_from_shared_labels() {
        let map = super::CoarseOwnershipMap {
            width: 2,
            height: 1,
            stride: 16,
            owners: vec![Some(0), Some(1)],
            confidence: vec![1.0, 1.0],
            prepass_micros: 0,
            decoded_sources: 0,
            scratch_bytes_reserved: 0,
        };
        assert_eq!(map.source_probability(0, 4, 4, 4), 1.0);
        assert_eq!(map.source_probability(0, 16, 4, 4), 0.5);
        assert_eq!(map.source_probability(1, 16, 4, 4), 0.5);
    }

    #[test]
    fn moving_content_prefers_coherent_source_and_blurred_candidate_is_penalized() {
        let mut candidates = [candidate(0, 0.0), candidate(1, 0.02)];
        candidates[0].color = [240, 30, 20];
        candidates[1].color = [20, 220, 30];
        candidates[0].texture = 90;
        candidates[0].sharpness = 20;
        candidates[1].texture = 20;
        candidates[1].sharpness = 80;
        let disagreement = adjust_candidates_for_content(&mut candidates, 12, 18, 0.7);
        assert!(disagreement > 0.5);
        assert!(candidates[0].unary_cost >= 0.10);
        assert!(candidates[0].unary_cost > candidates[1].unary_cost);
        assert!(content_disagreement([0, 0, 0], [0, 0, 0]) < f32::EPSILON);
    }
}
