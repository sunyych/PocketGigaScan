import 'dart:math' as math;

import '../models/stitch_task.dart';

const jpegMaximumDimension = 65500;

class EstimatedOutputDimensions {
  const EstimatedOutputDimensions({required this.width, required this.height});

  final int width;
  final int height;

  bool get exceedsJpegLimit =>
      width > jpegMaximumDimension || height > jpegMaximumDimension;
}

/// A conservative rectilinear estimate. Registration and spherical projection
/// can change the final bounds; callers must check the rendered manifest too.
EstimatedOutputDimensions? estimateOutputDimensions(StitchTask task) {
  if (task.photos.isEmpty ||
      task.grid.rows < 1 ||
      task.grid.columns < 1 ||
      !task.horizontalFovDegrees.isFinite ||
      task.horizontalFovDegrees <= 1 ||
      task.horizontalFovDegrees >= 179 ||
      !task.gridHorizontalOverlap.isFinite ||
      !task.gridVerticalOverlap.isFinite ||
      task.gridHorizontalOverlap < 0 ||
      task.gridHorizontalOverlap >= 1 ||
      task.gridVerticalOverlap < 0 ||
      task.gridVerticalOverlap >= 1) {
    return null;
  }

  final photo = task.photos.first;
  if (photo.width < 1 || photo.height < 1) return null;
  final horizontalFov = task.horizontalFovDegrees * math.pi / 180;
  final verticalFov =
      2 * math.atan(math.tan(horizontalFov / 2) * photo.height / photo.width);
  final focalPixels = photo.width / (2 * math.tan(horizontalFov / 2));
  final width =
      photo.width +
      (task.grid.columns - 1) *
          focalPixels *
          horizontalFov *
          (1 - task.gridHorizontalOverlap);
  final height =
      photo.height +
      (task.grid.rows - 1) *
          focalPixels *
          verticalFov *
          (1 - task.gridVerticalOverlap);
  if (!width.isFinite || !height.isFinite || width < 1 || height < 1) {
    return null;
  }
  return EstimatedOutputDimensions(width: width.ceil(), height: height.ceil());
}
