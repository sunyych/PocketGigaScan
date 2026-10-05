"""Independent, holdout-based adjacent texture alignment validation.

The checker compares only cardinal neighbors, never all-photo pairs. RANSAC is
fit on spatially distributed training matches; reported render-space errors use
held-out matches only. Metrics describe correspondence geometry, not human seam
acceptance or foreground parallax.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

import cv2
import numpy as np


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pyramid-before', type=Path)
    parser.add_argument('--pyramid-after', type=Path)
    parser.add_argument('--max-features', type=int, default=2500)
    parser.add_argument('--min-holdout', type=int, default=8)
    parser.add_argument('--correspondence-cache', type=Path,
                        help='persistent local JSON cache for independent matches')
    parser.add_argument('--roi', nargs=4, type=int, metavar=('X', 'Y', 'W', 'H'),
                        help='write same-angle crop layouts and crops for a before-render ROI')
    return parser.parse_args()


def keyed(layout):
    return {(int(tile['row']), int(tile['column'])): tile for tile in layout['tiles']}


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
    saved = {}
    if cache_path.is_file():
        saved = json.loads(cache_path.read_text(encoding='utf-8'))
        if saved.get('schemaVersion') != 2:
            raise ValueError('unsupported correspondence cache schema')
        if saved.get('sourceFingerprints') != {f'{k[0]},{k[1]}': v for k, v in fingerprints.items()}:
            raise ValueError('correspondence cache source SHA-256/size fingerprints do not match')
        if saved.get('matcher') != {'algorithm': 'SIFT-BF-knn-ratio', 'maxFeatures': args.max_features,
                                    'contrastThreshold': .015, 'ratioThreshold': .75,
                                    'spatialSplit': '8x8-checkerboard-mod4-v1',
                                    'holdoutValidationThresholdSourcePx': 3.}:
            raise ValueError('correspondence cache matcher/split parameters do not match')
    cached_edges = saved.setdefault('edges', {})
    saved.update({'schemaVersion': 2,
                  'sourceFingerprints': {f'{k[0]},{k[1]}': v for k, v in fingerprints.items()},
                  'matcher': {'algorithm': 'SIFT-BF-knn-ratio', 'maxFeatures': args.max_features,
                              'contrastThreshold': .015, 'ratioThreshold': .75,
                              'spatialSplit': '8x8-checkerboard-mod4-v1',
                              'holdoutValidationThresholdSourcePx': 3.},
                  'semantics': 'all SIFT ratio pairs stored; holdout accepted only when it agrees '
                               'within 3 source px with a train-only RANSAC model'})
    persist_cache(cache_path, saved)
    new_cache_edges = 0
    cv2.setNumThreads(1)
    sift = cv2.SIFT_create(nfeatures=args.max_features, contrastThreshold=.015)
    cache, edges, all_before, all_after, all_before_raw, all_after_raw = {}, [], [], [], [], []
    crop_candidates = []
    for key in sorted(b):
        for neighbor in ((key[0], key[1] + 1), (key[0] + 1, key[1])):
            if neighbor not in b:
                continue
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

    if not all_before:
        raise RuntimeError('no edges had sufficient independent holdout correspondences')
    if new_cache_edges:
        persist_cache(cache_path, saved)
    summary = {'semantics': 'rawHoldout includes every held-out SIFT ratio pair; main metrics '
                            'include only holdout pairs agreeing within 3 source px with a '
                            'homography fit exclusively on spatially separate training matches',
               'humanSeamAcceptance': 'not established; inspect generated crops and final render',
               'beforeLayout': str(args.before), 'afterLayout': str(args.after),
               'edgeCountMeasured': sum(e['status'] == 'measured' for e in edges),
               'edgeCountAttempted': len(edges), 'before': stats(np.asarray(all_before)),
               'after': stats(np.asarray(all_after)),
               'beforeRawHoldout': stats(np.asarray(all_before_raw)),
               'afterRawHoldout': stats(np.asarray(all_after_raw)), 'edges': edges}
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'texture-alignment-report.json').write_text(
        json.dumps(summary, indent=2), encoding='utf-8')

    # Select the clearest reliably matched edge (small after median, broad
    # spatial coverage) for local output-pyramid crops on each layout.
    candidate = sorted(crop_candidates, key=lambda c: (
        -c[1]['holdoutSpatialCells8x8'], c[0]))
    if candidate:
        _, record, qb1, qb2, qa1, qa2 = candidate[0]
        for label, pyramid, points in (('before', args.pyramid_before, np.vstack((qb1, qb2))),
                                        ('after', args.pyramid_after, np.vstack((qa1, qa2)))):
            if pyramid is None:
                continue
            center = np.median(points, axis=0)
            crop = pyramid_crop(pyramid, center)
            cv2.imwrite(str(args.output / f'{label}-seam-crop.jpg'), crop,
                        [cv2.IMWRITE_JPEG_QUALITY, 94])
        summary['cropEdge'] = {'from': record['from'], 'to': record['to'],
                               'holdoutSpatialCells8x8': record['holdoutSpatialCells8x8']}
        (args.output / 'texture-alignment-report.json').write_text(
            json.dumps(summary, indent=2), encoding='utf-8')

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
    print(json.dumps({k: v for k, v in summary.items() if k != 'edges'}, indent=2))


if __name__ == '__main__':
    main(arguments())
