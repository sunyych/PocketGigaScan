"""Small deterministic contract tests for the independent seam checker."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from argparse import Namespace
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


class NeighborAndQualityGateTests(unittest.TestCase):
    def test_cardinal_default_and_diagonal_mode_pair_every_neighbor_once(self):
        keys = {(row, column) for row in range(3) for column in range(3)}
        cardinal = list(seam.neighbor_pairs(keys))
        eight = list(seam.neighbor_pairs(keys, include_diagonals=True))
        self.assertEqual(len(cardinal), 12)
        self.assertEqual(len(eight), 20)
        for pairs in (cardinal, eight):
            identities = [frozenset(pair) for pair in pairs]
            self.assertEqual(len(identities), len(set(identities)))
            for first, second in pairs:
                dr, dc = abs(first[0] - second[0]), abs(first[1] - second[1])
                self.assertLessEqual(dr, 1)
                self.assertLessEqual(dc, 1)
                self.assertNotEqual((dr, dc), (0, 0))

    def test_worst_edge_selection_uses_after_p95_and_keeps_representative_and_target(self):
        def candidate(first, second, p95, coverage):
            record = {'from': first, 'to': second, 'holdoutSpatialCells8x8': coverage,
                      'after': {'p95Px': p95, 'rmsPx': p95 / 2}}
            return (p95 / 3, record, np.zeros((2, 2)), np.zeros((2, 2)),
                    np.zeros((2, 2)), np.zeros((2, 2)))

        candidates = [
            candidate((8, 12), (8, 13), 1.5, 2),
            candidate((9, 13), (10, 13), 9.0, 3),
            candidate((8, 13), (9, 13), 7.0, 4),
            candidate((9, 13), (10, 14), 6.0, 5),
            candidate((4, 4), (4, 5), 4.0, 8),
        ]
        selected = seam.select_edge_samples(candidates, (9, 13))
        self.assertEqual(selected['worst'][1]['after']['p95Px'], 9.0)
        self.assertEqual(set(selected['targetEdges']), {'north', 'south', 'southeast'})
        self.assertEqual(selected['targetEdges']['south'][1]['from'], (9, 13))
        self.assertEqual(selected['representative'][1]['holdoutSpatialCells8x8'], 8)

    def test_quality_gate_rejects_empty_high_error_and_low_coverage_samples(self):
        args = Namespace(quality_gate=True, max_after_rms_px=2.0,
                         max_after_p95_px=3.0, max_edge_after_rms_px=None,
                         max_edge_after_p95_px=None, diagonal_neighbors=False,
                         min_measured_edges=1,
                         min_support_coverage=2, required_edge=[], required_cell=[])
        empty = {'after': seam.stats(np.array([], dtype=float))}
        result = seam.evaluate_quality_gate(args, empty, [], {(0, 0)})
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('no measured edge' in failure for failure in result['failures']))

        poor = {'after': seam.stats(np.array([4., 5., 6.]))}
        edge = {'status': 'measured', 'from': (0, 0), 'to': (0, 1),
                'holdoutAccepted': 5, 'holdoutSpatialCells8x8': 2}
        result = seam.evaluate_quality_gate(args, poor, [edge], {(0, 0), (0, 1)})
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('RMS' in failure for failure in result['failures']))

        low_coverage = {'after': seam.stats(np.array([1., 1.]))}
        edge['holdoutSpatialCells8x8'] = 1
        result = seam.evaluate_quality_gate(args, low_coverage, [edge], {(0, 0), (0, 1)})
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('support coverage' in failure for failure in result['failures']))

    def test_per_edge_limit_rejects_bad_edge_hidden_by_good_global_aggregate(self):
        args = Namespace(quality_gate=False, max_after_rms_px=6.0,
                         max_after_p95_px=None, max_edge_after_rms_px=2.0,
                         max_edge_after_p95_px=3.0, diagonal_neighbors=False,
                         min_measured_edges=1, min_support_coverage=1,
                         required_edge=[], required_cell=[])
        edges = [
            {'status': 'measured', 'from': (0, 0), 'to': (0, 1),
             'holdoutAccepted': 10, 'holdoutSpatialCells8x8': 3,
             'after': {'rmsPx': 1.0, 'p95Px': 1.5}},
            {'status': 'measured', 'from': (1, 0), 'to': (1, 1),
             'holdoutAccepted': 1, 'holdoutSpatialCells8x8': 2,
             'after': {'rmsPx': 10.0, 'p95Px': 10.0}},
        ]
        summary = {'after': seam.stats(np.array([1.] * 10 + [10.]))}
        result = seam.evaluate_quality_gate(args, summary, edges,
                                            {(0, 0), (0, 1), (1, 0), (1, 1)})
        self.assertLess(summary['after']['rmsPx'], args.max_after_rms_px)
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('edge (1, 0)--(1, 1)' in failure for failure in result['failures']))

    def test_quality_gate_requires_error_bound_and_every_required_cell_edge(self):
        args = Namespace(quality_gate=True, max_after_rms_px=None,
                         max_after_p95_px=None, max_edge_after_rms_px=None,
                         max_edge_after_p95_px=None, diagonal_neighbors=False,
                         min_measured_edges=1, min_support_coverage=1,
                         required_edge=[], required_cell=[(1, 1)])
        summary = {'after': seam.stats(np.array([1.]))}
        edge = {'status': 'measured', 'from': (1, 1), 'to': (0, 1),
                'holdoutAccepted': 4, 'holdoutSpatialCells8x8': 2,
                'after': {'rmsPx': 1.0, 'p95Px': 1.0}}
        cells = {(1, 1), (0, 1), (1, 0)}
        result = seam.evaluate_quality_gate(args, summary, [edge], cells)
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('no error bound' in failure for failure in result['failures']))
        self.assertTrue(any('missing supported incident edge' in failure
                            for failure in result['failures']))

    def test_quality_gate_rejects_nonfinite_bounds_and_invalid_support(self):
        args = Namespace(quality_gate=True, max_after_rms_px=float('nan'),
                         max_after_p95_px=None, max_edge_after_rms_px=None,
                         max_edge_after_p95_px=None, diagonal_neighbors=False,
                         min_measured_edges=0, min_support_coverage=-1,
                         required_edge=[], required_cell=[])
        result = seam.evaluate_quality_gate(args, {'after': seam.stats(np.array([1.]))}, [], set())
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('finite and nonnegative' in failure for failure in result['failures']))
        self.assertTrue(any('must be positive' in failure for failure in result['failures']))

    def test_cached_correspondences_invalidate_on_source_layout_or_algorithm_change(self):
        source = {'0,0': {'sha256': 'source-a', 'size': 123}}
        layouts = {'before': 'before-a', 'after': 'after-a'}
        matcher = seam.matcher_identity(2500)
        saved = {'schemaVersion': 3, 'sourceFingerprints': source,
                 'layoutFingerprints': layouts, 'matcher': matcher}
        seam.validate_correspondence_cache(saved, source, layouts, matcher)
        with self.assertRaisesRegex(ValueError, 'source'):
            seam.validate_correspondence_cache(saved, {'0,0': {'sha256': 'source-b', 'size': 123}},
                                               layouts, matcher)
        with self.assertRaisesRegex(ValueError, 'layout'):
            seam.validate_correspondence_cache(saved, source,
                                               {'before': 'before-b', 'after': 'after-a'}, matcher)
        changed_algorithm = dict(matcher, algorithmVersion=matcher['algorithmVersion'] + 1)
        with self.assertRaisesRegex(ValueError, 'matcher'):
            seam.validate_correspondence_cache(saved, source, layouts, changed_algorithm)

    def test_quality_gate_failure_returns_nonzero_and_writes_report(self):
        with tempfile.TemporaryDirectory(dir=SCRIPT.parents[1]) as directory:
            root = Path(directory)
            source = root / 'synthetic-source.bin'
            source.write_bytes(b'synthetic fixture')
            layout = {
                'width': 10, 'height': 10,
                'yawMinRad': -1., 'yawMaxRad': 1.,
                'pitchMinRad': -.5, 'pitchMaxRad': .5,
                'tiles': [{'row': 0, 'column': 0, 'path': str(source)}],
            }
            before, after = root / 'before.json', root / 'after.json'
            before.write_text(json.dumps(layout), encoding='utf-8')
            after.write_text(json.dumps(layout), encoding='utf-8')
            output = root / 'report'
            args = Namespace(
                before=before, after=after, output=output,
                pyramid_before=None, pyramid_after=None, max_features=100,
                min_holdout=8, correspondence_cache=root / 'cache.json',
                roi=None, diagonal_neighbors=False, quality_gate=True,
                max_after_rms_px=1., max_after_p95_px=1.,
                max_edge_after_rms_px=None, max_edge_after_p95_px=None,
                min_measured_edges=1,
                min_support_coverage=1, required_cell=[], required_edge=[],
                target_cell=(9, 13),
            )
            with patch.object(seam, 'edge_matches', return_value=None), \
                    patch.object(seam.cv2, 'SIFT_create', return_value=object()):
                status = seam.main(args)
            report = json.loads(
                (output / 'texture-alignment-report.json').read_text(encoding='utf-8'))
            self.assertEqual(status, 2)
            self.assertEqual(report['qualityGate']['status'], 'failed')
            self.assertIsNone(report['after']['rmsPx'])


if __name__ == '__main__':
    unittest.main()
