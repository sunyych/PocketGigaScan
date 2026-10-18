import 'imported_photo.dart';

enum GridMode { filename, sequence }

enum TraversalAxis { row, column }

enum StartCorner { topLeft, topRight, bottomLeft, bottomRight }

enum GridConstraintOrigin { operatorAction, systemFallback, legacyUnknown }

GridConstraintOrigin gridConstraintOriginFromJson(Object? value) =>
    switch (value) {
      'operator' => GridConstraintOrigin.operatorAction,
      'systemFallback' => GridConstraintOrigin.systemFallback,
      _ => GridConstraintOrigin.legacyUnknown,
    };

class GridPlacementConstraint {
  const GridPlacementConstraint({required this.kind, required this.origin});

  final String kind;
  final GridConstraintOrigin origin;

  String get originName => switch (origin) {
    GridConstraintOrigin.operatorAction => 'operator',
    GridConstraintOrigin.systemFallback => 'systemFallback',
    GridConstraintOrigin.legacyUnknown => 'legacyUnknown',
  };

  Map<String, Object?> toJson() => {'kind': kind, 'origin': originName};
}

class GridCell {
  const GridCell(this.row, this.column);
  final int row;
  final int column;

  @override
  bool operator ==(Object other) =>
      other is GridCell && row == other.row && column == other.column;

  @override
  int get hashCode => Object.hash(row, column);
}

Set<GridCell> remapForcedCellsByPhoto({
  required List<ImportedPhoto> photos,
  required List<GridCell> oldMapping,
  required Set<GridCell> oldForced,
  required List<GridCell> newMapping,
}) {
  if (oldMapping.length != photos.length ||
      newMapping.length != photos.length) {
    return const {};
  }
  final forcedPaths = <String>{
    for (var index = 0; index < photos.length; index++)
      if (oldForced.contains(oldMapping[index])) photos[index].storedPath,
  };
  return {
    for (var index = 0; index < photos.length; index++)
      if (forcedPaths.contains(photos[index].storedPath)) newMapping[index],
  };
}

GridOptions remapGridLocksByPhoto({
  required List<ImportedPhoto> photos,
  required List<GridCell> oldMapping,
  required GridOptions oldOptions,
  required GridOptions nextOptions,
  required List<GridCell> newMapping,
  required bool oldMappingValid,
  required bool newMappingValid,
}) {
  final originsByPhoto = Map<String, GridConstraintOrigin>.of(
    oldOptions.lockedPhotoOrigins,
  );
  if (oldMappingValid && oldMapping.length == photos.length) {
    for (var index = 0; index < photos.length; index++) {
      final oldCell = oldMapping[index];
      if (oldOptions.activeForcedGridCells.contains(oldCell)) {
        originsByPhoto.putIfAbsent(
          photos[index].storedPath,
          () =>
              oldOptions.forceGridCellOrigins[oldCell] ??
              GridConstraintOrigin.legacyUnknown,
        );
      }
    }
  }

  final pending = <GridCell>{...oldOptions.pendingForceGridCells};
  if (oldMappingValid) {
    final mappedCells = oldMapping.toSet();
    for (final cell in oldOptions.activeForcedGridCells) {
      if (!mappedCells.contains(cell)) pending.add(cell);
    }
  } else {
    final unassociatedCount =
        (oldOptions.forceGridCells.length -
                originsByPhoto.length -
                pending.length)
            .clamp(0, oldOptions.forceGridCells.length);
    final unresolvedCandidates = oldOptions.activeForcedGridCells.toList()
      ..sort(
        (a, b) => a.row != b.row
            ? a.row.compareTo(b.row)
            : a.column.compareTo(b.column),
      );
    pending.addAll(unresolvedCandidates.take(unassociatedCount));
  }
  if (!newMappingValid || newMapping.length != photos.length) {
    final pendingOrigins = Map<GridCell, GridConstraintOrigin>.of(
      oldOptions.forceGridCellOrigins,
    );
    for (final cell in oldOptions.forceGridCells) {
      pendingOrigins.putIfAbsent(
        cell,
        () => GridConstraintOrigin.legacyUnknown,
      );
    }
    return nextOptions.copyWith(
      forceGridCells: oldOptions.forceGridCells,
      forceGridCellOrigins: pendingOrigins,
      lockedPhotoOrigins: originsByPhoto,
      pendingForceGridCells: pending,
    );
  }

  final forced = <GridCell>{};
  final cellOrigins = <GridCell, GridConstraintOrigin>{};
  for (var index = 0; index < photos.length; index++) {
    final origin = originsByPhoto[photos[index].storedPath];
    if (origin != null) {
      final cell = newMapping[index];
      forced.add(cell);
      cellOrigins[cell] = origin;
    }
  }

  forced.addAll(pending);
  for (final cell in pending) {
    cellOrigins.putIfAbsent(cell, () => GridConstraintOrigin.legacyUnknown);
  }
  return nextOptions.copyWith(
    forceGridCells: forced,
    forceGridCellOrigins: cellOrigins,
    lockedPhotoOrigins: originsByPhoto,
    pendingForceGridCells: pending,
  );
}

class GridOptions {
  const GridOptions({
    this.mode = GridMode.filename,
    this.rows = 1,
    this.columns = 1,
    this.axis = TraversalAxis.row,
    this.startCorner = StartCorner.topLeft,
    this.serpentine = false,
    this.forceGridCells = const {},
    this.forceGridCellOrigins = const {},
    this.lockedPhotoOrigins = const {},
    this.pendingForceGridCells = const {},
  });

  static const _maxInt = 0x7fffffffffffffff;

  static bool productFits(int rows, int columns) =>
      rows > 0 && columns > 0 && rows <= _maxInt ~/ columns;

  final GridMode mode;
  final int rows;
  final int columns;
  final TraversalAxis axis;
  final StartCorner startCorner;
  final bool serpentine;
  final Set<GridCell> forceGridCells;
  final Map<GridCell, GridConstraintOrigin> forceGridCellOrigins;
  final Map<String, GridConstraintOrigin> lockedPhotoOrigins;
  final Set<GridCell> pendingForceGridCells;
  Set<GridCell> get activeForcedGridCells =>
      forceGridCells.difference(pendingForceGridCells);

  GridOptions copyWith({
    GridMode? mode,
    int? rows,
    int? columns,
    TraversalAxis? axis,
    StartCorner? startCorner,
    bool? serpentine,
    Set<GridCell>? forceGridCells,
    Map<GridCell, GridConstraintOrigin>? forceGridCellOrigins,
    Map<String, GridConstraintOrigin>? lockedPhotoOrigins,
    Set<GridCell>? pendingForceGridCells,
  }) => GridOptions(
    mode: mode ?? this.mode,
    rows: rows ?? this.rows,
    columns: columns ?? this.columns,
    axis: axis ?? this.axis,
    startCorner: startCorner ?? this.startCorner,
    serpentine: serpentine ?? this.serpentine,
    forceGridCells: forceGridCells ?? this.forceGridCells,
    forceGridCellOrigins: forceGridCellOrigins ?? this.forceGridCellOrigins,
    lockedPhotoOrigins: lockedPhotoOrigins ?? this.lockedPhotoOrigins,
    pendingForceGridCells: pendingForceGridCells ?? this.pendingForceGridCells,
  );

  GridOptions toggleForced(GridCell cell, {String? photoPath}) {
    final isLocked = photoPath == null
        ? activeForcedGridCells.contains(cell)
        : lockedPhotoOrigins.containsKey(photoPath) ||
              activeForcedGridCells.contains(cell);
    return setPhotoLock(cell, photoPath, locked: !isLocked);
  }

  GridOptions setPhotoLock(
    GridCell cell,
    String? photoPath, {
    required bool locked,
  }) {
    final updated = {...forceGridCells};
    final cellOrigins = Map<GridCell, GridConstraintOrigin>.of(
      forceGridCellOrigins,
    );
    final photoOrigins = Map<String, GridConstraintOrigin>.of(
      lockedPhotoOrigins,
    );
    if (!locked) {
      if (!pendingForceGridCells.contains(cell)) updated.remove(cell);
      cellOrigins.remove(cell);
      if (photoPath != null) photoOrigins.remove(photoPath);
    } else {
      updated.add(cell);
      cellOrigins[cell] = GridConstraintOrigin.operatorAction;
      if (photoPath != null) {
        photoOrigins[photoPath] = GridConstraintOrigin.operatorAction;
      }
    }
    return copyWith(
      forceGridCells: updated,
      forceGridCellOrigins: cellOrigins,
      lockedPhotoOrigins: photoOrigins,
    );
  }

  GridPlacementConstraint placementFor(ImportedPhoto photo, GridCell cell) {
    final hardLock =
        activeForcedGridCells.contains(cell) ||
        lockedPhotoOrigins.containsKey(photo.storedPath);
    final origin =
        lockedPhotoOrigins[photo.storedPath] ??
        (hardLock
            ? (forceGridCellOrigins[cell] ?? GridConstraintOrigin.legacyUnknown)
            : GridConstraintOrigin.systemFallback);
    return GridPlacementConstraint(
      kind: hardLock ? 'hardGridLock' : 'gridPrior',
      origin: origin,
    );
  }

  String? get validationError {
    if (rows < 1 || columns < 1) {
      return '行列数必须是正整数';
    }
    if (!productFits(rows, columns)) return '网格行列乘积超出支持范围';
    return null;
  }

  List<GridCell> sequenceCells() {
    if (validationError != null) return const [];
    final startsRight =
        startCorner == StartCorner.topRight ||
        startCorner == StartCorner.bottomRight;
    final startsBottom =
        startCorner == StartCorner.bottomLeft ||
        startCorner == StartCorner.bottomRight;
    final result = <GridCell>[];
    if (axis == TraversalAxis.row) {
      final rowOrder = startsBottom
          ? List.generate(rows, (i) => rows - 1 - i)
          : List.generate(rows, (i) => i);
      for (var visitRow = 0; visitRow < rowOrder.length; visitRow++) {
        var rightToLeft = startsRight;
        if (serpentine && visitRow.isOdd) rightToLeft = !rightToLeft;
        final columnsOrder = rightToLeft
            ? List.generate(columns, (i) => columns - 1 - i)
            : List.generate(columns, (i) => i);
        result.addAll(
          columnsOrder.map((column) => GridCell(rowOrder[visitRow], column)),
        );
      }
    } else {
      final columnOrder = startsRight
          ? List.generate(columns, (i) => columns - 1 - i)
          : List.generate(columns, (i) => i);
      for (
        var visitColumn = 0;
        visitColumn < columnOrder.length;
        visitColumn++
      ) {
        var bottomToTop = startsBottom;
        if (serpentine && visitColumn.isOdd) bottomToTop = !bottomToTop;
        final rowsOrder = bottomToTop
            ? List.generate(rows, (i) => rows - 1 - i)
            : List.generate(rows, (i) => i);
        result.addAll(
          rowsOrder.map((row) => GridCell(row, columnOrder[visitColumn])),
        );
      }
    }
    return result;
  }

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'rows': rows,
    'columns': columns,
    'axis': axis.name,
    'startCorner': switch (startCorner) {
      StartCorner.topLeft => 'top-left',
      StartCorner.topRight => 'top-right',
      StartCorner.bottomLeft => 'bottom-left',
      StartCorner.bottomRight => 'bottom-right',
    },
    'serpentine': serpentine,
    'forceGridCells': forceGridCells
        .map((cell) => {'row': cell.row, 'column': cell.column})
        .toList(),
    'forceGridCellOrigins': forceGridCellOrigins.entries
        .map(
          (entry) => {
            'row': entry.key.row,
            'column': entry.key.column,
            'origin': GridPlacementConstraint(
              kind: 'hardGridLock',
              origin: entry.value,
            ).originName,
          },
        )
        .toList(),
    'lockedPhotoOrigins': lockedPhotoOrigins.entries
        .map(
          (entry) => {
            'storedPath': entry.key,
            'origin': GridPlacementConstraint(
              kind: 'hardGridLock',
              origin: entry.value,
            ).originName,
          },
        )
        .toList(),
    'pendingForceGridCells': pendingForceGridCells
        .map((cell) => {'row': cell.row, 'column': cell.column})
        .toList(),
  };

  static GridOptions fromJson(
    Map<String, Object?> json, {
    required List<ImportedPhoto> photos,
  }) {
    final forced = (json['forceGridCells'] as List<Object?>? ?? const [])
        .map((value) => value as Map<String, Object?>)
        .map((value) => GridCell(value['row']! as int, value['column']! as int))
        .toSet();
    final cellOrigins = <GridCell, GridConstraintOrigin>{
      for (final value
          in (json['forceGridCellOrigins'] as List<Object?>? ?? const []))
        if (value is Map<String, Object?>)
          GridCell(value['row']! as int, value['column']! as int):
              gridConstraintOriginFromJson(value['origin']),
    };
    final photoOrigins = <String, GridConstraintOrigin>{
      for (final value
          in (json['lockedPhotoOrigins'] as List<Object?>? ?? const []))
        if (value is Map<String, Object?>)
          value['storedPath']! as String: gridConstraintOriginFromJson(
            value['origin'],
          ),
    };
    final pending =
        (json['pendingForceGridCells'] as List<Object?>? ?? const [])
            .map((value) => value as Map<String, Object?>)
            .map(
              (value) =>
                  GridCell(value['row']! as int, value['column']! as int),
            )
            .toSet();
    final corner = switch (json['startCorner']) {
      'top-right' => StartCorner.topRight,
      'bottom-left' => StartCorner.bottomLeft,
      'bottom-right' => StartCorner.bottomRight,
      _ => StartCorner.topLeft,
    };
    final mode = json['mode'] == 'sequence'
        ? GridMode.sequence
        : GridMode.filename;
    final options = GridOptions(
      mode: mode,
      rows: json['rows'] as int? ?? 1,
      columns: json['columns'] as int? ?? 1,
      axis: json['axis'] == 'column' ? TraversalAxis.column : TraversalAxis.row,
      startCorner: corner,
      serpentine: json['serpentine'] as bool? ?? false,
      forceGridCells: forced,
      forceGridCellOrigins: cellOrigins,
      lockedPhotoOrigins: photoOrigins,
      pendingForceGridCells: pending,
    );
    if (forced.isNotEmpty) {
      final mapping = mode == GridMode.filename
          ? GridMapping.fromFilenames(photos)
          : GridMapping.sequence(photos, options);
      if (mapping.isValid && mapping.cells.length == photos.length) {
        final hadStablePhotoOrigins =
            (json['lockedPhotoOrigins'] as List<Object?>? ?? const [])
                .isNotEmpty;
        final mappedCells = mapping.cells.toSet();
        for (var index = 0; index < photos.length; index++) {
          final cell = mapping.cells[index];
          if (forced.contains(cell) && !pending.contains(cell)) {
            final path = photos[index].storedPath;
            if (!photoOrigins.containsKey(path)) {
              final recordedCellOrigin = cellOrigins[cell];
              if (!hadStablePhotoOrigins || recordedCellOrigin != null) {
                photoOrigins[path] =
                    recordedCellOrigin ?? GridConstraintOrigin.legacyUnknown;
              } else {
                pending.add(cell);
                cellOrigins[cell] = GridConstraintOrigin.legacyUnknown;
              }
            }
          }
        }
        for (final cell in forced) {
          if (!mappedCells.contains(cell)) {
            pending.add(cell);
            cellOrigins.putIfAbsent(
              cell,
              () => GridConstraintOrigin.legacyUnknown,
            );
          }
        }
      } else {
        for (final cell in forced) {
          pending.add(cell);
          cellOrigins.putIfAbsent(
            cell,
            () => GridConstraintOrigin.legacyUnknown,
          );
        }
      }
    }
    return options.copyWith(
      forceGridCellOrigins: cellOrigins,
      lockedPhotoOrigins: photoOrigins,
      pendingForceGridCells: pending,
    );
  }
}

class GridMapping {
  const GridMapping({
    required this.rows,
    required this.columns,
    required this.cells,
    this.error,
    this.warning,
  });

  final int rows;
  final int columns;
  final List<GridCell> cells;
  final String? error;
  final String? warning;

  bool get isValid => error == null;

  static final _coordinate = RegExp(
    r'^(\d+)[_-](\d+)\.(?:jpe?g)$',
    caseSensitive: false,
  );

  static GridMapping fromFilenames(List<ImportedPhoto> photos) {
    if (photos.isEmpty) {
      return const GridMapping(rows: 0, columns: 0, cells: [], error: '请先导入原片');
    }
    final parsed = <(int, int)>[];
    for (final photo in photos) {
      final match = _coordinate.firstMatch(photo.originalName);
      if (match == null) {
        return const GridMapping(
          rows: 0,
          columns: 0,
          cells: [],
          error: '文件名需为 row_column.jpg；可切换到顺序模式',
        );
      }
      final row = int.tryParse(match.group(1)!);
      final column = int.tryParse(match.group(2)!);
      if (row == null || column == null) {
        return const GridMapping(
          rows: 0,
          columns: 0,
          cells: [],
          error: '文件名行列编号超出支持范围',
        );
      }
      parsed.add((row, column));
    }
    final minRow = parsed
        .map((point) => point.$1)
        .reduce((a, b) => a < b ? a : b);
    final minColumn = parsed
        .map((point) => point.$2)
        .reduce((a, b) => a < b ? a : b);
    final normalized = parsed
        .map((point) => GridCell(point.$1 - minRow, point.$2 - minColumn))
        .toList();
    if (normalized.toSet().length != normalized.length) {
      return const GridMapping(
        rows: 0,
        columns: 0,
        cells: [],
        error: '检测到重复行列文件；请改用顺序模式，全部原片都会保留',
      );
    }
    final maxNormalizedRow = normalized
        .map((cell) => cell.row)
        .reduce((a, b) => a > b ? a : b);
    final maxNormalizedColumn = normalized
        .map((cell) => cell.column)
        .reduce((a, b) => a > b ? a : b);
    if (maxNormalizedRow == GridOptions._maxInt ||
        maxNormalizedColumn == GridOptions._maxInt) {
      return const GridMapping(
        rows: 0,
        columns: 0,
        cells: [],
        error: '文件名行列范围超出整数支持范围',
      );
    }
    final rows = maxNormalizedRow + 1;
    final columns = maxNormalizedColumn + 1;
    if (!GridOptions.productFits(rows, columns)) {
      return GridMapping(
        rows: rows,
        columns: columns,
        cells: normalized,
        error: '网格行列乘积超出整数支持范围',
      );
    }
    if (normalized.length != rows * columns) {
      return GridMapping(
        rows: rows,
        columns: columns,
        cells: normalized,
        error: '文件名网格有空格；请切换到顺序模式并调整行列。所有 ${photos.length} 张原片都会保留。',
      );
    }
    return GridMapping(rows: rows, columns: columns, cells: normalized);
  }

  static GridMapping sequence(List<ImportedPhoto> photos, GridOptions options) {
    if (options.validationError != null) {
      return GridMapping(
        rows: options.rows,
        columns: options.columns,
        cells: const [],
        error: options.validationError,
      );
    }
    if (photos.length != options.rows * options.columns) {
      return GridMapping(
        rows: options.rows,
        columns: options.columns,
        cells: const [],
        error:
            '${photos.length} 张原片无法填满 ${options.rows}×${options.columns} 网格；请调整行列。',
      );
    }
    return GridMapping(
      rows: options.rows,
      columns: options.columns,
      cells: options.sequenceCells(),
    );
  }

  List<Map<String, Object?>> tiles(
    List<ImportedPhoto> photos, {
    Set<GridCell> forced = const {},
    Map<GridCell, GridConstraintOrigin> forceGridCellOrigins = const {},
    Map<String, GridConstraintOrigin> lockedPhotoOrigins = const {},
    Set<GridCell> pendingForceGridCells = const {},
  }) {
    if (!isValid || photos.length != cells.length) return const [];
    return List.generate(photos.length, (index) {
      final photo = photos[index];
      final cell = cells[index];
      final hardLock =
          (forced.contains(cell) && !pendingForceGridCells.contains(cell)) ||
          lockedPhotoOrigins.containsKey(photo.storedPath);
      final origin =
          lockedPhotoOrigins[photo.storedPath] ??
          (hardLock
              ? (forceGridCellOrigins[cell] ??
                    GridConstraintOrigin.legacyUnknown)
              : GridConstraintOrigin.systemFallback);
      final placement = GridPlacementConstraint(
        kind: hardLock ? 'hardGridLock' : 'gridPrior',
        origin: origin,
      );
      return {
        'row': cell.row,
        'column': cell.column,
        'path': photo.storedPath,
        'forceGrid': hardLock,
        'placementConstraint': placement.toJson(),
      };
    });
  }
}
