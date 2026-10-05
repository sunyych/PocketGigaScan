import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';

ImportedPhoto photo(String name, int order) => ImportedPhoto(
  originalName: name,
  storedPath: '$order.jpg',
  sha256: 'hash',
  width: 4000,
  height: 3000,
  originalOrder: order,
);

void main() {
  test(
    'right-bottom row serpentine sequence assigns the first frame at bottom-right',
    () {
      const options = GridOptions(
        rows: 2,
        columns: 3,
        axis: TraversalAxis.row,
        startCorner: StartCorner.bottomRight,
        serpentine: true,
      );
      expect(options.sequenceCells(), const [
        GridCell(1, 2),
        GridCell(1, 1),
        GridCell(1, 0),
        GridCell(0, 0),
        GridCell(0, 1),
        GridCell(0, 2),
      ]);
    },
  );

  test('column traversal and 1-based filename mapping keep every image', () {
    const options = GridOptions(
      rows: 2,
      columns: 3,
      mode: GridMode.sequence,
      axis: TraversalAxis.column,
      startCorner: StartCorner.topRight,
      serpentine: true,
    );
    expect(options.sequenceCells(), const [
      GridCell(0, 2),
      GridCell(1, 2),
      GridCell(1, 1),
      GridCell(0, 1),
      GridCell(0, 0),
      GridCell(1, 0),
    ]);
    final photos = [
      for (var r = 1; r <= 2; r++)
        for (var c = 1; c <= 2; c++) photo('${r}_$c.jpg', r * 10 + c),
    ];
    final mapping = GridMapping.fromFilenames(photos);
    expect(mapping.isValid, isTrue);
    expect(mapping.tiles(photos), hasLength(4));
    expect(mapping.cells.toSet(), {
      const GridCell(0, 0),
      const GridCell(0, 1),
      const GridCell(1, 0),
      const GridCell(1, 1),
    });
  });

  test('a forced photo follows its identity when traversal order changes', () {
    final photos = [for (var i = 0; i < 6; i++) photo('photo$i.jpg', i)];
    const rowMajor = GridOptions(mode: GridMode.sequence, rows: 2, columns: 3);
    const rightBottomSnake = GridOptions(
      mode: GridMode.sequence,
      rows: 2,
      columns: 3,
      startCorner: StartCorner.bottomRight,
      serpentine: true,
    );
    const forcedPhotoCell = GridCell(0, 1); // Original selection item 1.
    final moved = remapForcedCellsByPhoto(
      photos: photos,
      oldMapping: rowMajor.sequenceCells(),
      oldForced: {forcedPhotoCell},
      newMapping: rightBottomSnake.sequenceCells(),
    );
    final mappedIndex = rightBottomSnake.sequenceCells().indexOf(moved.single);
    expect(photos[mappedIndex].originalName, 'photo1.jpg');
  });

  test(
    'gapped or mixed-base filenames fail mapping without excluding selected photos',
    () {
      final gap = GridMapping.fromFilenames([
        photo('00_00.jpg', 0),
        photo('01_01.jpg', 1),
      ]);
      expect(gap.isValid, isFalse);
      expect(gap.error, contains('空格'));
      expect(
        GridMapping.fromFilenames([
          photo('0_1.jpg', 0),
          photo('1_2.jpg', 1),
        ]).isValid,
        isFalse,
      );
    },
  );
}
