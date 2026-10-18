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

  test('6x6, 7x6, and 7x1 complete grids pass without axis or photo caps', () {
    for (final (rows, columns) in [(6, 6), (7, 6), (7, 1), (1, 1025)]) {
      final count = rows * columns;
      final photos = [for (var i = 0; i < count; i++) photo('image$i.jpg', i)];
      final mapping = GridMapping.sequence(
        photos,
        GridOptions(mode: GridMode.sequence, rows: rows, columns: columns),
      );
      expect(mapping.isValid, isTrue, reason: '$rows×$columns');
      expect(mapping.cells, hasLength(count));
    }
  });

  test('positive dimensions reject zero and product overflow safely', () {
    expect(
      const GridOptions(rows: 0, columns: 1).validationError,
      contains('正整数'),
    );
    expect(
      const GridOptions(rows: 0x7fffffffffffffff, columns: 2).validationError,
      contains('乘积'),
    );
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

  test('grid lock provenance follows photo identity through remapping', () {
    final photos = [for (var i = 0; i < 6; i++) photo('photo$i.jpg', i)];
    const oldOptions = GridOptions(
      mode: GridMode.sequence,
      rows: 2,
      columns: 3,
    );
    final locked = oldOptions.setPhotoLock(
      const GridCell(0, 1),
      photos[1].storedPath,
      locked: true,
    );
    const reordered = GridOptions(
      mode: GridMode.sequence,
      rows: 2,
      columns: 3,
      startCorner: StartCorner.bottomRight,
      serpentine: true,
    );

    final moved = remapGridLocksByPhoto(
      photos: photos,
      oldMapping: oldOptions.sequenceCells(),
      oldOptions: locked,
      nextOptions: reordered,
      newMapping: reordered.sequenceCells(),
      oldMappingValid: true,
      newMappingValid: true,
    );

    expect(moved.forceGridCells, {const GridCell(1, 1)});
    expect(
      moved.lockedPhotoOrigins[photos[1].storedPath],
      GridConstraintOrigin.operatorAction,
    );
    expect(moved.placementFor(photos[1], const GridCell(1, 1)).toJson(), {
      'kind': 'hardGridLock',
      'origin': 'operator',
    });
  });

  test('invalid mapping keeps coordinate-only legacy locks pending', () {
    final photos = [for (var i = 0; i < 4; i++) photo('photo$i.jpg', i)];
    final legacy = GridOptions(
      mode: GridMode.sequence,
      rows: 1,
      columns: 4,
      forceGridCells: {const GridCell(0, 2)},
    );
    const invalidNext = GridOptions(
      mode: GridMode.sequence,
      rows: 2,
      columns: 3,
    );
    final pending = remapGridLocksByPhoto(
      photos: photos,
      oldMapping: const [],
      oldOptions: legacy,
      nextOptions: invalidNext,
      newMapping: const [],
      oldMappingValid: false,
      newMappingValid: false,
    );

    expect(pending.forceGridCells, {const GridCell(0, 2)});
    expect(pending.pendingForceGridCells, {const GridCell(0, 2)});
    expect(
      pending.forceGridCellOrigins[const GridCell(0, 2)],
      GridConstraintOrigin.legacyUnknown,
    );
  });

  test(
    'shrink then expand remaps mapped locks without locking another photo',
    () {
      final photos = [for (var i = 0; i < 4; i++) photo('photo$i.jpg', i)];
      const full = GridOptions(mode: GridMode.sequence, rows: 2, columns: 2);
      final locked = full.setPhotoLock(
        const GridCell(1, 1),
        photos[3].storedPath,
        locked: true,
      );
      const shrunk = GridOptions(mode: GridMode.sequence, rows: 1, columns: 2);
      final invalidStage = remapGridLocksByPhoto(
        photos: photos,
        oldMapping: full.sequenceCells(),
        oldOptions: locked,
        nextOptions: shrunk,
        newMapping: const [],
        oldMappingValid: true,
        newMappingValid: false,
      );
      const expanded = GridOptions(
        mode: GridMode.sequence,
        rows: 2,
        columns: 2,
        startCorner: StartCorner.bottomRight,
      );
      final restored = remapGridLocksByPhoto(
        photos: photos,
        oldMapping: const [],
        oldOptions: invalidStage,
        nextOptions: expanded,
        newMapping: expanded.sequenceCells(),
        oldMappingValid: false,
        newMappingValid: true,
      );
      final restoredMapping = expanded.sequenceCells();
      final correctPhotoCell = restoredMapping[3];
      final unrelatedAtFormerLockCell = restoredMapping.indexOf(
        const GridCell(1, 1),
      );

      expect(restored.pendingForceGridCells, isEmpty);
      expect(restored.placementFor(photos[3], correctPhotoCell).toJson(), {
        'kind': 'hardGridLock',
        'origin': 'operator',
      });
      expect(
        restored
            .placementFor(
              photos[unrelatedAtFormerLockCell],
              const GridCell(1, 1),
            )
            .toJson(),
        {'kind': 'gridPrior', 'origin': 'systemFallback'},
      );
      expect(restored.toJson()['pendingForceGridCells'], isEmpty);
    },
  );

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
