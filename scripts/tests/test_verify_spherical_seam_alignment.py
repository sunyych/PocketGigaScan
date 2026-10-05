"""Small deterministic contract tests for the independent seam checker."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np


SCRIPT = Path(__file__).parents[1] / 'verify-spherical-seam-alignment.py'
SPEC = importlib.util.spec_from_file_location('seam_validator', SCRIPT)
seam = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(seam)


class RenderSpaceTests(unittest.TestCase):
    def test_source_warp_is_forward_original_plus_offset(self):
        tile = {'width': 101, 'height': 81,
                'sourcePlaneWarp': {'columns': 3, 'rows': 3,
                                    'offsets': [[5., -2.]] * 9}}
        points = np.array([[0., 0.], [50., 40.], [100., 80.]])
        np.testing.assert_allclose(seam.corrected_source_points(tile, points),
                                   points + [5., -2.])

    def test_source_warp_interpolation_uses_row_major_and_pixel_center_bounds(self):
        tile = {'width': 101, 'height': 81,
                'sourcePlaneWarp': {'columns': 3, 'rows': 3,
                                    'offsets': [[float(x), float(y)]
                                                for y in range(3) for x in range(3)]}}
        points = np.array([[25., 20.], [50., 40.], [100., 80.]])
        np.testing.assert_allclose(seam.corrected_source_points(tile, points),
                                   points + [[.5, .5], [1., 1.], [2., 2.]])

    def test_absent_and_zero_warp_preserve_projection(self):
        tile = {'width': 101, 'height': 81, 'cx': 50., 'cy': 40.,
                'fx': 100., 'fy': 100.,
                'cameraToWorld': [1., 0., 0., 0., 1., 0., 0., 0., 1.]}
        points = np.array([[25., 20.], [100., 80.]])
        before = seam.rays(tile, points)
        tile['sourcePlaneWarp'] = {'columns': 3, 'rows': 3,
                                  'offsets': [[0., 0.]] * 9}
        np.testing.assert_array_equal(seam.rays(tile, points), before)

    def test_invalid_source_warp_rejected(self):
        tile = {'width': 101, 'height': 81,
                'sourcePlaneWarp': {'columns': 3, 'rows': 3,
                                    'offsets': [[float('nan'), 0.]] * 9}}
        with self.assertRaises(ValueError):
            seam.corrected_source_points(tile, np.array([[50., 40.]]))

    def test_fine_grid_uses_its_own_row_major_cells_and_pixel_bounds(self):
        points = np.array([[12.5, 10.], [62.5, 50.], [100., 80.]])
        for size in (5, 9):
            offsets = [[float(column), -float(row)]
                       for row in range(size) for column in range(size)]
            tile = {'width': 101, 'height': 81,
                    'sourcePlaneWarp': {'columns': size, 'rows': size,
                                        'offsets': offsets}}
            expected = points + points / [100., 80.] * [size - 1, -(size - 1)]
            np.testing.assert_allclose(seam.corrected_source_points(tile, points),
                                       expected, atol=1e-12)

    def test_unsupported_or_mismatched_grid_dimensions_are_rejected(self):
        for columns, rows in ((4, 4), (3, 5), (9, 5)):
            tile = {'width': 101, 'height': 81,
                    'sourcePlaneWarp': {'columns': columns, 'rows': rows,
                                        'offsets': [[0., 0.]] * (columns * rows)}}
            with self.assertRaises(ValueError):
                seam.corrected_source_points(tile, np.array([[50., 40.]]))

    def test_warp_reduces_known_correspondence_disagreement_in_render_space(self):
        tile = {'width': 101, 'height': 81, 'cx': 50., 'cy': 40.,
                'fx': 100., 'fy': 100.,
                'cameraToWorld': [1., 0., 0., 0., 1., 0., 0., 0., 1.]}
        layout = {'width': 2000, 'height': 1000,
                  'yawMinRad': -1., 'yawMaxRad': 1.,
                  'pitchMinRad': -.5, 'pitchMaxRad': .5}
        points = np.array([[25., 20.], [50., 40.], [75., 60.]])
        target = seam.render_xy(layout, tile, points + [5., -2.])
        uncorrected = seam.render_xy(layout, tile, points)
        self.assertGreater(np.linalg.norm(uncorrected - target, axis=1).min(), 40.)
        warped = dict(tile, sourcePlaneWarp={'columns': 3, 'rows': 3,
                                           'offsets': [[5., -2.]] * 9})
        np.testing.assert_array_equal(seam.render_xy(layout, warped, points), target)

    def test_identical_pose_projects_correspondence_to_same_render_pixel(self):
        layout = {'width': 2000, 'height': 1000,
                  'yawMinRad': -1., 'yawMaxRad': 1.,
                  'pitchMinRad': -.5, 'pitchMaxRad': .5}
        tile = {'cx': 50., 'cy': 40., 'fx': 100., 'fy': 100.,
                'cameraToWorld': [1., 0., 0., 0., 1., 0., 0., 0., 1.]}
        source_points = np.array([[50., 40.], [70., 30.]])
        output = seam.render_xy(layout, tile, source_points)
        np.testing.assert_allclose(output[0], [1000., 500.], atol=1e-7)
        np.testing.assert_allclose(output[1], [1197.39555985, 402.25442027], atol=1e-7)

    def test_summary_reports_rms_and_percentiles(self):
        result = seam.stats(np.array([3., 4.]))
        self.assertEqual(result['count'], 2)
        self.assertEqual(result['rmsPx'], 3.5355339059327378)
        self.assertEqual(result['p50Px'], 3.5)
        self.assertEqual(result['p95Px'], 3.95)

    def test_holdout_is_separate_and_repeatable(self):
        x, y = np.meshgrid(np.arange(8) * 10., np.arange(8) * 10.)
        p1 = np.column_stack((x.ravel(), y.ravel()))
        p2 = p1 + np.array([5., -2.])
        first = seam.robust_train_holdout(p1, p2)
        second = seam.robust_train_holdout(p1, p2)
        np.testing.assert_array_equal(first[0], second[0])
        np.testing.assert_array_equal(first[1], second[1])
        self.assertFalse(np.any(first[0] & first[1]))
        self.assertTrue(np.all(first[0] | first[1]))
        self.assertGreater(np.count_nonzero(first[1]), 8)
        np.testing.assert_allclose(first[2][1], np.ones(np.count_nonzero(first[1])))

    def test_same_angular_roi_maps_to_different_canvas_dimensions(self):
        before = {'width': 1000, 'height': 500,
                  'yawMinRad': -1., 'yawMaxRad': 1.,
                  'pitchMinRad': -.5, 'pitchMaxRad': .5}
        after = {'width': 2000, 'height': 1000,
                 'yawMinRad': -2., 'yawMaxRad': 2.,
                 'pitchMinRad': -1., 'pitchMaxRad': 1.}
        bounds = seam.roi_angles(before, 250, 100, 200, 150)
        before_pixels = seam.roi_pixels_for_layout(before, bounds)
        after_pixels = seam.roi_pixels_for_layout(after, bounds)
        np.testing.assert_allclose(before_pixels, [350., 175., 200., 150.])
        np.testing.assert_allclose(after_pixels, [850., 425., 200., 150.])

    def test_failed_training_homography_returns_empty_holdout_acceptance(self):
        points = np.column_stack((np.arange(40.), np.arange(40.) ** 2))
        with patch.object(seam.cv2, 'findHomography', return_value=(None, None)):
            train, holdout, masks, count = seam.robust_train_holdout(points, points)
        self.assertEqual(count, 0)
        self.assertFalse(np.any(train & holdout))
        self.assertEqual(len(masks[1]), np.count_nonzero(holdout))
        self.assertFalse(np.any(masks[1]))

    def test_partial_yaw_canvas_does_not_wrap_longitude(self):
        left = np.array([[0., 10.]])
        right = np.array([[999., 10.]])
        partial = {'width': 1000, 'yawMinRad': -.5, 'yawMaxRad': .5}
        full = {'width': 1000, 'yawMinRad': -np.pi, 'yawMaxRad': np.pi}
        self.assertAlmostEqual(seam.render_disagreement(left, right, partial)[0, 0], -999.)
        self.assertAlmostEqual(seam.render_disagreement(left, right, full)[0, 0], 1.)

    def test_correspondence_cache_replaces_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'cache.json'
            seam.persist_cache(path, {'generation': 1})
            seam.persist_cache(path, {'generation': 2})
            self.assertEqual(path.read_text(encoding='utf-8'), '{"generation": 2}')
            self.assertFalse(path.with_name(path.name + '.tmp').exists())


if __name__ == '__main__':
    unittest.main()
