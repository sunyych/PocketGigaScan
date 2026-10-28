import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/jpeg_dimension_estimator.dart';

StitchTask _task({
  required int width,
  required int height,
  int rows = 1,
  int columns = 1,
  double horizontalFovDegrees = 90,
  double horizontalOverlap = 0.3,
  double verticalOverlap = 0.3,
}) => StitchTask(
  id: 'task',
  createdAt: DateTime.utc(2026),
  sourceDirectory: '/source',
  outputDirectory: '/task/render',
  photos: [
    ImportedPhoto(
      originalName: 'photo.jpg',
      storedPath: '/source/photo.jpg',
      sha256: 'hash',
      width: width,
      height: height,
      originalOrder: 0,
    ),
  ],
  grid: GridOptions(rows: rows, columns: columns),
  horizontalFovDegrees: horizontalFovDegrees,
  gridHorizontalOverlap: horizontalOverlap,
  gridVerticalOverlap: verticalOverlap,
  memoryBudgetMiB: 512,
  workers: 1,
  phase: StitchPhase.imported,
);

void main() {
  test('estimates dimensions from pixels, grid, overlap and camera FOV', () {
    final single = estimateOutputDimensions(_task(width: 4000, height: 3000));
    final wider = estimateOutputDimensions(
      _task(width: 4000, height: 3000, columns: 8),
    );
    final moreOverlap = estimateOutputDimensions(
      _task(width: 4000, height: 3000, columns: 8, horizontalOverlap: 0.7),
    );
    final narrowerFov = estimateOutputDimensions(
      _task(width: 4000, height: 3000, columns: 8, horizontalFovDegrees: 35),
    );

    expect(single, isNotNull);
    expect(wider!.width, greaterThan(single!.width));
    expect(moreOverlap!.width, lessThan(wider.width));
    expect(narrowerFov!.width, isNot(wider.width));
  });

  test('uses a strict edge limit and returns unknown for invalid geometry', () {
    final atLimit = estimateOutputDimensions(
      _task(width: 65500, height: 65500),
    );
    final above = estimateOutputDimensions(_task(width: 65501, height: 65500));

    expect(atLimit!.width, jpegMaximumDimension);
    expect(atLimit.height, jpegMaximumDimension);
    expect(atLimit.exceedsJpegLimit, isFalse);
    expect(above!.exceedsJpegLimit, isTrue);
    expect(
      estimateOutputDimensions(
        _task(width: 4000, height: 3000, horizontalFovDegrees: 180),
      ),
      isNull,
    );
  });
}
