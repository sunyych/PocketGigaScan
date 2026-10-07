import 'dart:math' as math;

import '../models/grid_options.dart';
import '../models/stitch_task.dart';
import 'package:path/path.dart' as p;

/// Build the exact request accepted by `lumia_gigascan_spherical_json`.
Map<String, Object?> buildSphericalRequest(StitchTask task) {
  final grid = task.grid;
  final mapping = grid.mode == GridMode.filename
      ? GridMapping.fromFilenames(task.photos)
      : GridMapping.sequence(task.photos, grid);
  if (!mapping.isValid) {
    throw FormatException(mapping.error ?? 'Invalid grid mapping');
  }
  if (task.photos.isEmpty ||
      !task.photos.every(
        (photo) =>
            photo.width == task.photos.first.width &&
            photo.height == task.photos.first.height,
      )) {
    throw const FormatException(
      'All source images must have matching dimensions',
    );
  }
  final width = task.photos.first.width, height = task.photos.first.height;
  final fx = task.cameraProfileId == 'dwarf3-tele-nominal-150mm'
      ? 75000.0 * width / 3840
      : width / (2 * math.tan(task.horizontalFovDegrees * math.pi / 360));
  if (!fx.isFinite || fx <= 0) {
    throw const FormatException('Invalid focal length');
  }
  final options = task.performanceOptions;
  return {
    'tiles': mapping.tiles(
      task.photos,
      forced: grid.forceGridCells,
      forceGridCellOrigins: grid.forceGridCellOrigins,
      lockedPhotoOrigins: grid.lockedPhotoOrigins,
      pendingForceGridCells: grid.pendingForceGridCells,
    ),
    'rows': mapping.rows,
    'columns': mapping.columns,
    'fx': fx,
    'fy': fx,
    'cx': (width - 1) / 2,
    'cy': (height - 1) / 2,
    'sourceWidth': width,
    'sourceHeight': height,
    'placementMode': 'grid-assisted',
    'neighborMode': options.neighborMode,
    'parallelMatching': options.parallelMatching,
    'parallelRendering': options.parallelRendering,
    'useSourceCache': options.useSourceCache,
    'useAlignmentCache': options.useAlignmentCache,
    'alignmentCacheDir': p.normalize(
      p.absolute(p.join(p.dirname(task.sourceDirectory), '.alignment-cache')),
    ),
    'featureType': options.featureType,
    'matcherType': options.matcherType,
    'registrationMegapixels': options.registrationMegapixels,
    'allowNominalGridFallback': task.forceGridFallback,
    'autoGridOverlap': task.autoGridOverlap,
    'refineGridNeighbors': task.refineGridNeighbors,
    'seamBlendMode': task.seamBlendMode.name,
    'localTextureWarp': task.localTextureWarp,
    if (!task.autoGridOverlap) ...{
      'gridHorizontalOverlap': task.gridHorizontalOverlap,
      'gridVerticalOverlap': task.gridVerticalOverlap,
    },
  };
}
