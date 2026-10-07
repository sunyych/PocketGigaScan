"""Independent, holdout-based adjacent texture alignment validation.

The checker compares immediate cardinal neighbors by default and can opt into
the four unique diagonal directions; it never tests all-photo pairs. RANSAC is
fit on spatially distributed training matches and reported render-space errors
use a checker-owned held-out split. That split is not unseen production-solver
evidence. Metrics describe correspondence geometry, not human seam acceptance
or foreground parallax.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

import cv2
import numpy as np


CHECKER_ALGORITHM_VERSION = 3


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pyramid-before', type=Path)
    parser.add_argument('--pyramid-after', type=Path)
    parser.add_argument('--max-features', type=int, default=2500)
    parser.add_argument('--min-holdout', type=int, default=8)
    parser.add_argument('--diagonal-neighbors', action='store_true',
                        help='also compare each unique diagonal 8-neighbor edge')
    parser.add_argument('--correspondence-cache', type=Path,
                        help='persistent local JSON cache for independent matches')
    parser.add_argument('--quality-gate', action='store_true',
                        help='fail unless measured correspondence quality meets configured requirements')
    parser.add_argument('--max-after-rms-px', type=float)
    parser.add_argument('--max-after-p95-px', type=float)
    parser.add_argument('--max-edge-after-rms-px', type=float,
                        help='maximum after RMS required for every supported measured edge')
    parser.add_argument('--max-edge-after-p95-px', type=float,
                        help='maximum after p95 required for every supported measured edge')
    parser.add_argument('--min-measured-edges', type=positive_int, default=1)
    parser.add_argument('--min-support-coverage', type=positive_int, default=1,
                        help='minimum distinct 8x8 source cells represented by accepted holdout points')
    parser.add_argument('--required-cell', type=parse_cell, action='append', default=[],
                        metavar='ROW,COLUMN')
    parser.add_argument('--required-edge', type=parse_edge, action='append', default=[],
                        metavar='R1,C1,R2,C2')
    parser.add_argument('--target-cell', type=parse_cell, default=(9, 13),
                        metavar='ROW,COLUMN',
                        help='also emit a crop for a measured edge touching this cell (default: 9,13)')
    parser.add_argument('--roi', nargs=4, type=int, metavar=('X', 'Y', 'W', 'H'),
                        help='write same-angle crop layouts and crops for a before-render ROI')
    return parser.parse_args()


def parse_cell(value):
    try:
        row, column = (int(part) for part in value.split(','))
    except (ValueError, TypeError):
        raise argparse.ArgumentTypeError('cell must be ROW,COLUMN')
    if row < 0 or column < 0:
        raise argparse.ArgumentTypeError('cell coordinates must be nonnegative')
    return row, column


def positive_int(value):
    try:
        result = int(value)
    except (ValueError, TypeError):
        raise argparse.ArgumentTypeError('value must be a positive integer')
    if result <= 0:
        raise argparse.ArgumentTypeError('value must be a positive integer')
    return result


def parse_edge(value):
    try:
        values = tuple(int(part) for part in value.split(','))
    except (ValueError, TypeError):
        raise argparse.ArgumentTypeError('edge must be R1,C1,R2,C2')
    if len(values) != 4 or min(values) < 0:
        raise argparse.ArgumentTypeError('edge must contain four nonnegative coordinates')
    return (values[0], values[1]), (values[2], values[3])


def neighbor_pairs(keys, include_diagonals=False):
    """Return every cardinal (or 8-neighbor) edge once, without orientation duplicates."""
    offsets = [(0, 1), (1, 0)]
    if include_diagonals:
        offsets.extend(((1, -1), (1, 1)))
    key_set = set(keys)
    for row, column in sorted(key_set):
        for drow, dcolumn in offsets:
            neighbor = (row + drow, column + dcolumn)
            if neighbor in key_set:
                yield (row, column), neighbor


def keyed(layout):
    return {(int(tile['row']), int(tile['column'])): tile for tile in layout['tiles']}


def layout_fingerprint(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def matcher_identity(max_features):
    return {'algorithm': 'SIFT-BF-knn-ratio', 'algorithmVersion': CHECKER_ALGORITHM_VERSION,
            'maxFeatures': max_features, 'contrastThreshold': .015, 'ratioThreshold': .75,
            'spatialSplit': '8x8-checkerboard-mod4-v1',
            'holdoutValidationThresholdSourcePx': 3.}


def validate_correspondence_cache(saved, source_fingerprints, layout_fingerprints,
                                  matcher):
    if saved.get('schemaVersion') != 3:
        raise ValueError('unsupported correspondence cache schema')
    if saved.get('sourceFingerprints') != source_fingerprints:
        raise ValueError('correspondence cache source SHA-256/size fingerprints do not match')
    if saved.get('layoutFingerprints') != layout_fingerprints:
        raise ValueError('correspondence cache layout fingerprints do not match')
    if saved.get('matcher') != matcher:
        raise ValueError('correspondence cache matcher/split parameters do not match')


def edge_identity(record):
    return frozenset(tuple(point) for point in (record['from'], record['to']))


def select_edge_samples(candidates, target_cell=(9, 13)):
    """Choose representative, worst-p95, and target-touching crops from measured edges."""
    if not candidates:
        return {}
    representative = min(candidates, key=lambda candidate: (
        -candidate[1]['holdoutSpatialCells8x8'],
        candidate[1]['after']['p95Px'] if candidate[1]['after']['p95Px'] is not None else math.inf,
        candidate[1]['after']['rmsPx'] if candidate[1]['after']['rmsPx'] is not None else math.inf))
    worst = max(candidates, key=lambda candidate: (
        candidate[1]['after']['p95Px'] if candidate[1]['after']['p95Px'] is not None else -math.inf,
        candidate[1]['after']['rmsPx'] if candidate[1]['after']['rmsPx'] is not None else -math.inf))
    selected = {'representative': representative, 'worst': worst}
    target = {}
    for candidate in candidates:
        first, second = (tuple(point) for point in
                        (candidate[1]['from'], candidate[1]['to']))
        if target_cell not in (first, second):
            continue
        neighbor = second if first == target_cell else first
        delta = (neighbor[0] - target_cell[0], neighbor[1] - target_cell[1])
        side = {
            (-1, 0): 'north', (1, 0): 'south', (0, -1): 'west', (0, 1): 'east',
            (-1, -1): 'northwest', (-1, 1): 'northeast',
            (1, -1): 'southwest', (1, 1): 'southeast',
        }.get(delta, f'neighbor-{neighbor[0]}-{neighbor[1]}')
        target[side] = candidate
    if target:
        selected['targetEdges'] = target
    return selected


def evaluate_quality_gate(args, summary, edges, cells):
    requested = (args.quality_gate or args.max_after_rms_px is not None or
                 args.max_after_p95_px is not None or
                 args.max_edge_after_rms_px is not None or
                 args.max_edge_after_p95_px is not None or
                 args.required_cell or args.required_edge)
    if not requested:
        return {'requested': False, 'status': 'notRequested', 'failures': []}
    failures = []
    bounds = [args.max_after_rms_px, args.max_after_p95_px,
              args.max_edge_after_rms_px, args.max_edge_after_p95_px]
    for name, bound in zip(('after RMS', 'after p95', 'per-edge after RMS',
                            'per-edge after p95'), bounds):
        if bound is not None and (not math.isfinite(bound) or bound < 0):
            failures.append(f'{name} bound must be finite and nonnegative')
    if args.min_measured_edges <= 0 or args.min_support_coverage <= 0:
        failures.append('minimum measured edges and support coverage must be positive')
    if not any(bound is not None for bound in bounds):
        failures.append('quality gate has no error bound; coverage alone cannot qualify quality')
    measured = [edge for edge in edges if edge.get('status') == 'measured']
    supported = [edge for edge in measured
                 if edge.get('holdoutSpatialCells8x8', 0) >= args.min_support_coverage and
                 edge.get('holdoutAccepted', 0) > 0]
    if not measured:
        failures.append('no measured edge samples; unknown/empty data cannot pass')
    if len(supported) < args.min_measured_edges:
        failures.append(f'measured edges meeting support coverage: {len(supported)} < '
                        f'{args.min_measured_edges}')
    if args.max_after_rms_px is not None:
        value = summary['after']['rmsPx']
        if value is None or not math.isfinite(value) or value > args.max_after_rms_px:
            failures.append(f'after RMS {value} exceeds or does not meet '
                            f'{args.max_after_rms_px} px')
    if args.max_after_p95_px is not None:
        value = summary['after']['p95Px']
        if value is None or not math.isfinite(value) or value > args.max_after_p95_px:
            failures.append(f'after p95 {value} exceeds or does not meet '
                            f'{args.max_after_p95_px} px')
    measured_ids = {edge_identity(edge) for edge in supported}
    for edge in supported:
        label = f"{edge['from']}--{edge['to']}"
        if args.max_edge_after_rms_px is not None:
            value = edge['after']['rmsPx']
            if value is None or not math.isfinite(value) or value > args.max_edge_after_rms_px:
                failures.append(f'edge {label} after RMS {value} exceeds or does not meet '
                                f'{args.max_edge_after_rms_px} px')
        if args.max_edge_after_p95_px is not None:
            value = edge['after']['p95Px']
            if value is None or not math.isfinite(value) or value > args.max_edge_after_p95_px:
                failures.append(f'edge {label} after p95 {value} exceeds or does not meet '
                                f'{args.max_edge_after_p95_px} px')
    for first, second in args.required_edge:
        if frozenset((first, second)) not in measured_ids:
            failures.append(f'required edge {first}--{second} lacks supported measured samples')
    for cell in args.required_cell:
        if cell not in cells:
            failures.append(f'required cell {cell} is absent from the selected layouts')
            continue
        drdc = [(0, 1), (0, -1), (1, 0), (-1, 0)]
        if args.diagonal_neighbors:
            drdc.extend(((-1, -1), (-1, 1), (1, -1), (1, 1)))
        neighbors = [(cell[0] + dr, cell[1] + dc) for dr, dc in drdc
                     if (cell[0] + dr, cell[1] + dc) in cells]
        if not neighbors:
            failures.append(f'required cell {cell} has no available immediate neighbor edges')
        for neighbor in neighbors:
            if frozenset((cell, neighbor)) not in measured_ids:
                failures.append(f'required cell {cell} is missing supported incident edge '
                                f'to {neighbor}')
    return {'requested': True, 'status': 'failed' if failures else 'passed',
            'minMeasuredEdges': args.min_measured_edges,
            'minSupportCoverageCells8x8': args.min_support_coverage,
            'perEdgeLimitsAppliedToEverySupportedMeasuredEdge': True,
            'failures': failures}


def read_features(tile, cache, sift):
    path = str(Path(tile['path']).resolve())
    if path not in cache:
        image = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
        if image is None:
            raise RuntimeError(f'cannot read source image: {path}')
        h, w = image.shape
        scale = min(1., math.sqrt(2_000_000 / (w * h)))
        resized = cv2.resize(image, (round(w * scale), round(h * scale)))
        points, descriptors = sift.detectAndCompute(resized, None)
        cache[path] = (points, descriptors,
                       np.array([resized.shape[1] / w, resized.shape[0] / h]))
    return cache[path]


def corrected_source_points(tile, points):
    """Independently evaluate the persisted source-plane bilinear warp contract."""
    warp = tile.get('sourcePlaneWarp')
    if warp is None:
        return points
    columns, rows = warp.get('columns'), warp.get('rows')
    if columns not in (3, 5, 9) or rows != columns:
        raise ValueError('sourcePlaneWarp must be a supported square control grid')
    offsets = np.asarray(warp.get('offsets'), dtype=np.float64)
    if offsets.shape != (rows * columns, 2) or not np.all(np.isfinite(offsets)):
        raise ValueError('sourcePlaneWarp must contain finite row-major xy offsets')
    width, height = float(tile['width']), float(tile['height'])
    if width <= 1 or height <= 1:
        raise ValueError('sourcePlaneWarp requires positive image dimensions')
    spans = np.array([columns - 1, rows - 1])
    uv = np.clip(points / np.array([width - 1, height - 1]) * spans, 0, spans)
    cell = np.minimum(np.floor(uv).astype(int), spans - 1)
    frac = uv - cell
    x, y = cell[:, 0], cell[:, 1]
    sx, sy = frac[:, 0, None], frac[:, 1, None]
    grid = offsets.reshape(rows, columns, 2)
    shift = ((1 - sx) * (1 - sy) * grid[y, x] +
             sx * (1 - sy) * grid[y, x + 1] +
             (1 - sx) * sy * grid[y + 1, x] +
             sx * sy * grid[y + 1, x + 1])
    return points + shift


def rays(tile, points):
    points = corrected_source_points(tile, points)
    camera = np.column_stack(((points[:, 0] - tile['cx']) / tile['fx'],
                              -(points[:, 1] - tile['cy']) / tile['fy'],
                              np.ones(len(points))))
    matrix = np.asarray(tile['cameraToWorld'], dtype=np.float64).reshape(3, 3)
    result = camera @ matrix.T
    return result / np.linalg.norm(result, axis=1)[:, None]


def render_xy(layout, tile, points):
    """Project source pixels into the persisted equirectangular render space."""
    ray = rays(tile, points)
    yaw = np.arctan2(ray[:, 0], ray[:, 2])
    yaw_min, yaw_max = float(layout['yawMinRad']), float(layout['yawMaxRad'])
    # Pick the equivalent longitude nearest this output interval's center.
    center = (yaw_min + yaw_max) * .5
    yaw += np.round((center - yaw) / (2 * np.pi)) * (2 * np.pi)
    pitch = np.arcsin(np.clip(ray[:, 1], -1., 1.))
    x = (yaw - yaw_min) * float(layout['width']) / (yaw_max - yaw_min)
    y = (float(layout['pitchMaxRad']) - pitch) * float(layout['height']) / (
        float(layout['pitchMaxRad']) - float(layout['pitchMinRad']))
    return np.column_stack((x, y))


def robust_train_holdout(points1, points2):
    """Spatial split before fitting; return all holdout, inliers and train counts."""
    # Bin over source 1's normalized bounding box. Every fifth spatial bin in a
    # deterministic checkerboard is held out; this prevents local-only holdout.
    lo = points1.min(axis=0)
    span = np.maximum(points1.max(axis=0) - lo, 1.)
    cells = np.floor((points1 - lo) / span * 8).astype(np.int32).clip(0, 7)
    holdout = ((cells[:, 0] + 2 * cells[:, 1]) % 4) == 0
    train = ~holdout
    if train.sum() < 8 or holdout.sum() < 8:
        # Deterministic fallback still separates points before RANSAC.
        indices = np.arange(len(points1))
        holdout = indices % 4 == 0
        train = ~holdout
    train_ids = np.flatnonzero(train)
    matrix, mask = cv2.findHomography(points1[train], points2[train], cv2.RANSAC, 3.)
    if matrix is None or mask is None:
        return train, holdout, (np.zeros(len(points1), dtype=bool),
                                np.zeros(int(holdout.sum()), dtype=bool)), 0
    train_inlier = np.zeros(len(points1), dtype=bool)
    train_inlier[train_ids] = mask.ravel().astype(bool)
    projected = cv2.perspectiveTransform(points1[holdout].astype(np.float32)[None, :, :],
                                         matrix)[0]
    holdout_valid = np.linalg.norm(projected - points2[holdout], axis=1) <= 3.
    return train, holdout, (train_inlier, holdout_valid), int(mask.sum())


def stats(values):
    if len(values) == 0:
        return {'count': 0, 'rmsPx': None, 'p50Px': None, 'p95Px': None}
    return {'count': int(len(values)), 'rmsPx': float(np.sqrt(np.mean(values ** 2))),
            'p50Px': float(np.percentile(values, 50)),
            'p95Px': float(np.percentile(values, 95))}


def edge_matches(key, neighbor, before_tiles, cache, sift):
    points = [read_features(before_tiles[k], cache, sift) for k in (key, neighbor)]
    kp1, d1, scale1 = points[0]
    kp2, d2, scale2 = points[1]
    if d1 is None or d2 is None:
        return None
    pairs = cv2.BFMatcher().knnMatch(d1, d2, k=2)
    good = [pair[0] for pair in pairs if len(pair) == 2 and
            pair[0].distance < .75 * pair[1].distance]
    if len(good) < 20:
        return None
    p1 = np.asarray([kp1[m.queryIdx].pt for m in good], dtype=np.float64) / scale1
    p2 = np.asarray([kp2[m.trainIdx].pt for m in good], dtype=np.float64) / scale2
    return p1, p2


def fingerprint(tile):
    path = Path(tile['path']).resolve(strict=True)
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    stat = path.stat()
    return {'sha256': digest.hexdigest(), 'size': stat.st_size}


def edge_cache_key(key, neighbor, fingerprints):
    return f'{key[0]},{key[1]}|{neighbor[0]},{neighbor[1]}|{fingerprints[key]["sha256"]}|{fingerprints[neighbor]["sha256"]}'


def persist_cache(path, saved):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(saved), encoding='utf-8')
    temporary.replace(path)


def metric_for(layout, tiles, key, neighbor, p1, p2, holdout):
    q1 = render_xy(layout, tiles[key], p1[holdout])
    q2 = render_xy(layout, tiles[neighbor], p2[holdout])
    delta = render_disagreement(q1, q2, layout)
    return np.linalg.norm(delta, axis=1), q1, q2


def render_disagreement(q1, q2, layout):
    delta = q1 - q2
    yaw_span = float(layout['yawMaxRad']) - float(layout['yawMinRad'])
    # A partial-yaw canvas has real outer boundaries and must not wrap there.
    if yaw_span >= 2 * np.pi - 1e-6:
        width = float(layout['width'])
        delta[:, 0] -= np.round(delta[:, 0] / width) * width
    return delta


def pyramid_crop(pyramid, center, size=(768, 768)):
    """Read just intersecting 512px level-0 pyramid tiles; never load full output."""
    if pyramid is None:
        return None
    cx, cy = map(float, center)
    width, height = size if isinstance(size, tuple) else (size, size)
    left, top = int(round(cx - width / 2)), int(round(cy - height / 2))
    canvas = np.zeros((height, width, 3), dtype=np.uint8)
    x0, y0 = max(0, left), max(0, top)
    x1, y1 = min(int(1e12), left + width), min(int(1e12), top + height)
    if x1 <= x0 or y1 <= y0:
        return canvas
    tx0, tx1 = x0 // 512, (x1 - 1) // 512
    ty0, ty1 = y0 // 512, (y1 - 1) // 512
    for ty in range(ty0, ty1 + 1):
        for tx in range(tx0, tx1 + 1):
            path = pyramid / f'{ty}-{tx}.png'
            if not path.is_file():
                continue
            tile = cv2.imread(str(path), cv2.IMREAD_COLOR)
            if tile is None:
                continue
            ax0, ay0 = max(x0, tx * 512), max(y0, ty * 512)
            ax1, ay1 = min(x1, tx * 512 + tile.shape[1]), min(y1, ty * 512 + tile.shape[0])
            canvas[ay0 - top:ay1 - top, ax0 - left:ax1 - left] = tile[
                ay0 - ty * 512:ay1 - ty * 512, ax0 - tx * 512:ax1 - tx * 512]
    return canvas


def roi_angles(layout, x, y, width, height):
    return {
        'yawMinRad': float(layout['yawMinRad']) + x / layout['width'] *
                     (float(layout['yawMaxRad']) - float(layout['yawMinRad'])),
        'yawMaxRad': float(layout['yawMinRad']) + (x + width) / layout['width'] *
                     (float(layout['yawMaxRad']) - float(layout['yawMinRad'])),
        'pitchMaxRad': float(layout['pitchMaxRad']) - y / layout['height'] *
                       (float(layout['pitchMaxRad']) - float(layout['pitchMinRad'])),
        'pitchMinRad': float(layout['pitchMaxRad']) - (y + height) / layout['height'] *
                       (float(layout['pitchMaxRad']) - float(layout['pitchMinRad']))}


def roi_pixels_for_layout(layout, bounds):
    yaw_span = float(bounds['yawMaxRad']) - float(bounds['yawMinRad'])
    pitch_span = float(bounds['pitchMaxRad']) - float(bounds['pitchMinRad'])
    yaw_center = (float(bounds['yawMinRad']) + float(bounds['yawMaxRad'])) / 2
    pitch_center = (float(bounds['pitchMinRad']) + float(bounds['pitchMaxRad'])) / 2
    yaw_canvas = float(layout['yawMaxRad']) - float(layout['yawMinRad'])
    pitch_canvas = float(layout['pitchMaxRad']) - float(layout['pitchMinRad'])
    center_x = (yaw_center - float(layout['yawMinRad'])) / yaw_canvas * float(layout['width'])
    center_y = (float(layout['pitchMaxRad']) - pitch_center) / pitch_canvas * float(layout['height'])
    crop_width = yaw_span / yaw_canvas * float(layout['width'])
    crop_height = pitch_span / pitch_canvas * float(layout['height'])
    return center_x, center_y, crop_width, crop_height


def main(args):
    before = json.loads(args.before.read_text(encoding='utf-8-sig'))
    after = json.loads(args.after.read_text(encoding='utf-8-sig'))
    b, a = keyed(before), keyed(after)
    if b.keys() != a.keys():
        raise ValueError('before and after layouts must contain the same row/column keys')
    cache_path = args.correspondence_cache or (args.output / 'correspondence-cache.json')
    fingerprints = {key: fingerprint(tile) for key, tile in b.items()}
    if fingerprints != {key: fingerprint(tile) for key, tile in a.items()}:
        raise ValueError('before and after source images differ; refusing stale correspondence reuse')
    source_fingerprints = {f'{k[0]},{k[1]}': v for k, v in fingerprints.items()}
    layout_fingerprints = {'before': layout_fingerprint(args.before),
                           'after': layout_fingerprint(args.after)}
    matcher = matcher_identity(args.max_features)
    saved = {}
    if cache_path.is_file():
        saved = json.loads(cache_path.read_text(encoding='utf-8'))
        validate_correspondence_cache(saved, source_fingerprints, layout_fingerprints, matcher)
    cached_edges = saved.setdefault('edges', {})
    saved.update({'schemaVersion': 3,
                  'sourceFingerprints': source_fingerprints,
                  'layoutFingerprints': layout_fingerprints,
                  'matcher': matcher,
                  'semantics': 'all SIFT ratio pairs stored; holdout accepted only when it agrees '
                               'within 3 source px with a train-only RANSAC model'})
    persist_cache(cache_path, saved)
    new_cache_edges = 0
    cv2.setNumThreads(1)
    sift = cv2.SIFT_create(nfeatures=args.max_features, contrastThreshold=.015)
    cache, edges, all_before, all_after, all_before_raw, all_after_raw = {}, [], [], [], [], []
    crop_candidates = []
    pairs = neighbor_pairs(b, include_diagonals=args.diagonal_neighbors)
    for key, neighbor in pairs:
            cache_key = edge_cache_key(key, neighbor, fingerprints)
            cached = cached_edges.get(cache_key)
            if cached is not None:
                p1 = np.asarray(cached['points1'], dtype=np.float64)
                p2 = np.asarray(cached['points2'], dtype=np.float64)
                train = np.asarray(cached['train'], dtype=bool)
                holdout = np.asarray(cached['holdout'], dtype=bool)
                holdout_valid = np.asarray(cached['holdoutAccepted'], dtype=bool)
                train_count = int(cached['trainingRansacInliers'])
                matched = (p1, p2)
                precomputed = (train, holdout, (np.zeros(len(p1), dtype=bool), holdout_valid), train_count)
            else:
                matched = edge_matches(key, neighbor, b, cache, sift)
                precomputed = None
            if matched is None:
                edges.append({'from': key, 'to': neighbor, 'status': 'insufficient-matches'})
                continue
            p1, p2 = matched
            train, holdout, evidence_masks, train_count = (
                precomputed if precomputed is not None else robust_train_holdout(p1, p2))
            # Fit uses training points only. Preserve every raw holdout pair in
            # separate metrics; use only independently validated holdout pairs
            # for the main correspondence-geometry comparison.
            train_inliers, holdout_valid = evidence_masks
            if cached is None:
                cached_edges[cache_key] = {'points1': p1.tolist(), 'points2': p2.tolist(),
                                           'train': train.tolist(), 'holdout': holdout.tolist(),
                                           'holdoutAccepted': holdout_valid.tolist(),
                                           'trainingRansacInliers': train_count}
                new_cache_edges += 1
                if new_cache_edges >= 32:
                    persist_cache(cache_path, saved)
                    new_cache_edges = 0
            if holdout_valid.sum() < args.min_holdout:
                edges.append({'from': key, 'to': neighbor, 'status': 'insufficient-holdout',
                              'matches': len(p1), 'holdoutCount': int(holdout.sum()),
                              'holdoutRansacRejected': int(holdout.sum() - holdout_valid.sum())})
                continue
            held = np.flatnonzero(holdout)
            accepted = np.zeros(len(p1), dtype=bool)
            accepted[held[holdout_valid]] = True
            eb_raw, _, _ = metric_for(before, b, key, neighbor, p1, p2, holdout)
            ea_raw, _, _ = metric_for(after, a, key, neighbor, p1, p2, holdout)
            eb, qb1, qb2 = metric_for(before, b, key, neighbor, p1, p2, accepted)
            ea, qa1, qa2 = metric_for(after, a, key, neighbor, p1, p2, accepted)
            all_before.extend(eb.tolist())
            all_after.extend(ea.tolist())
            all_before_raw.extend(eb_raw.tolist())
            all_after_raw.extend(ea_raw.tolist())
            coverage = np.floor((p1[accepted] / np.array([b[key]['width'], b[key]['height']])) * 8)
            coverage = np.clip(coverage.astype(int), 0, 7)
            coverage_cells = len(set(map(tuple, coverage.tolist())))
            record = {'from': key, 'to': neighbor, 'status': 'measured',
                      'ratioMatches': len(p1), 'trainingCount': int(train.sum()),
                      'trainingRansacInliers': train_count,
                      'trainingRansacRejected': int(train.sum()) - train_count,
                      'holdoutCount': int(holdout.sum()),
                      'holdoutRansacRejected': int(holdout.sum() - accepted.sum()),
                      'holdoutAccepted': int(accepted.sum()),
                      'holdoutSpatialCells8x8': coverage_cells,
                      'beforeRawHoldout': stats(eb_raw), 'afterRawHoldout': stats(ea_raw),
                      'before': stats(eb), 'after': stats(ea)}
            edges.append(record)
            crop_candidates.append((float(np.median(ea)), record, qb1, qb2, qa1, qa2))

    if new_cache_edges:
        persist_cache(cache_path, saved)
    summary = {'semantics': 'rawHoldout includes every held-out SIFT ratio pair; main metrics '
                            'include only holdout pairs agreeing within 3 source px with a '
                            'homography fit exclusively on spatially separate training matches',
               'humanSeamAcceptance': 'not established; inspect generated crops and final render',
               'evidenceScope': 'checker-owned spatial holdout split; not independent production-solver points',
               'neighborMode': '8-neighbor' if args.diagonal_neighbors else 'cardinal',
               'targetCell': args.target_cell,
               'beforeLayout': str(args.before), 'afterLayout': str(args.after),
               'edgeCountMeasured': sum(e['status'] == 'measured' for e in edges),
               'edgeCountAttempted': len(edges), 'before': stats(np.asarray(all_before)),
               'after': stats(np.asarray(all_after)),
               'beforeRawHoldout': stats(np.asarray(all_before_raw)),
               'afterRawHoldout': stats(np.asarray(all_after_raw)), 'edges': edges}
    args.output.mkdir(parents=True, exist_ok=True)
    selected = select_edge_samples(crop_candidates, args.target_cell)
    summary['cropEdges'] = {}
    crop_jobs = []
    for sample_name, candidate in selected.items():
        if sample_name == 'targetEdges':
            crop_jobs.extend((f'target-{side}', edge) for side, edge in candidate.items())
        else:
            crop_jobs.append((sample_name, candidate))
    for sample_name, candidate in crop_jobs:
        _, record, qb1, qb2, qa1, qa2 = candidate
        summary['cropEdges'][sample_name] = {
            'from': record['from'], 'to': record['to'],
            'afterP95Px': record['after']['p95Px'],
            'holdoutSpatialCells8x8': record['holdoutSpatialCells8x8'],
        }
        if sample_name == 'representative':
            crop_prefix = 'seam'
        elif sample_name.startswith('target-'):
            crop_prefix = (f'target-{args.target_cell[0]}-{args.target_cell[1]}-'
                           f'{sample_name.removeprefix("target-")}-seam')
        else:
            crop_prefix = 'worst-seam'
        for label, pyramid, points in (
                ('before', args.pyramid_before, np.vstack((qb1, qb2))),
                ('after', args.pyramid_after, np.vstack((qa1, qa2)))):
            if pyramid is None:
                continue
            center = np.median(points, axis=0)
            crop = pyramid_crop(pyramid, center)
            cv2.imwrite(str(args.output / f'{label}-{crop_prefix}-crop.jpg'), crop,
                        [cv2.IMWRITE_JPEG_QUALITY, 94])

    if args.roi:
        x, y, width, height = args.roi
        if width <= 0 or height <= 0 or x < 0 or y < 0 or x + width > before['width'] or y + height > before['height']:
            raise ValueError('--roi must be a positive rectangle inside the before layout')
        bounds = roi_angles(before, x, y, width, height)
        for label, layout in (('before', before), ('after', after)):
            cropped = dict(layout)
            cropped.update(bounds)
            cropped['width'], cropped['height'] = width, height
            (args.output / f'{label}-roi-layout.json').write_text(
                json.dumps(cropped, indent=2), encoding='utf-8')
            cx, cy, cw, ch = roi_pixels_for_layout(layout, bounds)
            source_crop = pyramid_crop(args.pyramid_before if label == 'before' else args.pyramid_after,
                                       (cx, cy), (max(1, round(cw)), max(1, round(ch))))
            if source_crop is not None:
                if source_crop.shape[1] != width or source_crop.shape[0] != height:
                    source_crop = cv2.resize(source_crop, (width, height), interpolation=cv2.INTER_AREA)
                cv2.imwrite(str(args.output / f'{label}-roi-seam-crop.jpg'), source_crop,
                            [cv2.IMWRITE_JPEG_QUALITY, 96])
    summary['qualityGate'] = evaluate_quality_gate(args, summary, edges, set(b))
    (args.output / 'texture-alignment-report.json').write_text(
        json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in summary.items() if k != 'edges'}, indent=2))
    if summary['qualityGate']['status'] == 'failed':
        return 2
    if not all_before:
        print('quality evidence is empty; no correspondence holdout samples were measured')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main(arguments()))
