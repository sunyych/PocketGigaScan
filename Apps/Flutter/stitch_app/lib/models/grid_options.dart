import 'imported_photo.dart';

enum GridMode { filename, sequence }

enum TraversalAxis { row, column }

enum StartCorner { topLeft, topRight, bottomLeft, bottomRight }

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

class GridOptions {
  const GridOptions({
    this.mode = GridMode.filename,
    this.rows = 1,
    this.columns = 1,
    this.axis = TraversalAxis.row,
    this.startCorner = StartCorner.topLeft,
    this.serpentine = false,
    this.forceGridCells = const {},
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

  GridOptions copyWith({
    GridMode? mode,
    int? rows,
    int? columns,
    TraversalAxis? axis,
    StartCorner? startCorner,
    bool? serpentine,
    Set<GridCell>? forceGridCells,
  }) => GridOptions(
    mode: mode ?? this.mode,
    rows: rows ?? this.rows,
    columns: columns ?? this.columns,
    axis: axis ?? this.axis,
    startCorner: startCorner ?? this.startCorner,
    serpentine: serpentine ?? this.serpentine,
    forceGridCells: forceGridCells ?? this.forceGridCells,
  );

  GridOptions toggleForced(GridCell cell) {
    final updated = {...forceGridCells};
    if (!updated.add(cell)) updated.remove(cell);
    return copyWith(forceGridCells: updated);
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
  };
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
  }) {
    if (!isValid || photos.length != cells.length) return const [];
    return List.generate(photos.length, (index) {
      final photo = photos[index];
      final cell = cells[index];
      return {
        'row': cell.row,
        'column': cell.column,
        'path': photo.storedPath,
        'forceGrid': forced.contains(cell),
      };
    });
  }
}
