import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/stitch_task.dart';

enum TaskResultProvenanceKind {
  normal,
  nominalGrid,
  measuredGrid,
  estimatedGrid,
  mixedGrid,
  forcedGrid,
  unknown,
}

class TaskResultProvenance {
  const TaskResultProvenance({
    required this.kind,
    this.forcedGridTileCount,
    this.visualTileCount,
    this.gridEstimatedTileCount,
    this.totalTileCount,
    this.isAutomaticGridRetry = false,
  });

  static const unknown = TaskResultProvenance(
    kind: TaskResultProvenanceKind.unknown,
  );

  final TaskResultProvenanceKind kind;
  final int? forcedGridTileCount;
  final int? visualTileCount;
  final int? gridEstimatedTileCount;
  final int? totalTileCount;
  final bool isAutomaticGridRetry;

  static Future<TaskResultProvenance> loadForTask(StitchTask task) async {
    final outputDirectory = task.outputDirectory;
    if (outputDirectory.isEmpty) return _unknownFor(task);
    try {
      final canonicalRoot = await Directory(
        outputDirectory,
      ).resolveSymbolicLinks();
      final layoutFile = File(p.join(canonicalRoot, 'layout.json'));
      if (await FileSystemEntity.type(layoutFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return _unknownFor(task);
      }
      final canonicalLayout = await layoutFile.resolveSymbolicLinks();
      if (!p.isWithin(canonicalRoot, canonicalLayout)) return _unknownFor(task);
      final file = File(canonicalLayout);
      final maxLayoutBytes =
          (Platform.isAndroid || Platform.isIOS ? 32 : 128) * 1024 * 1024;
      if (await file.length() > maxLayoutBytes) return _unknownFor(task);
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return _unknownFor(task);
      final rawReport = decoded['report'];
      if (rawReport is! Map) return _unknownFor(task);
      return fromReport(
        Map<String, Object?>.from(rawReport),
        isAutomaticGridRetry: task.automaticGridRetry,
        layoutTotalTileCount: decoded['tiles'] is List
            ? (decoded['tiles']! as List).length
            : null,
      );
    } on Object {
      return _unknownFor(task);
    }
  }

  static TaskResultProvenance _unknownFor(StitchTask task) =>
      TaskResultProvenance(
        kind: TaskResultProvenanceKind.unknown,
        isAutomaticGridRetry: task.automaticGridRetry,
      );

  static TaskResultProvenance fromReport(
    Map<String, Object?> report, {
    bool isAutomaticGridRetry = false,
    int? layoutTotalTileCount,
  }) {
    final geometry = report['geometryModel'] is String
        ? report['geometryModel']! as String
        : null;
    final forced = _count(report['forcedGridTileCount']);
    final visual = _count(report['visualTileCount']);
    final estimated = _count(report['gridEstimatedTileCount']);
    final total = _count(report['totalTileCount']) ?? layoutTotalTileCount;
    final quality = report['qualityStatus'];
    final completeEvidence = report['completeCorrespondenceEvidence'];
    final nominalOnly = report['nominalGridOnlyNeedsVisualReview'] == true;
    final hasGridModel = geometry?.toLowerCase().contains('grid') == true;
    final gridEstimates = estimated != null && estimated > 0;
    final forcedCells = forced != null && forced > 0;
    final anyVisual = visual != null && visual > 0;
    final knownGridEvidence =
        nominalOnly || hasGridModel || gridEstimates || forcedCells;

    late final TaskResultProvenanceKind kind;
    final visualModel = geometry?.startsWith('visual-') == true;
    final visualCountsAreConsistent = total == null
        ? true
        : visual == total && estimated == 0 && forced == 0;
    final legacyVisualReport =
        visualModel && visual == null && estimated == null && forced == null;
    if (!knownGridEvidence &&
        (completeEvidence == true || visualModel) &&
        quality == 'passed-measured-checks' &&
        (visualCountsAreConsistent || legacyVisualReport)) {
      kind = TaskResultProvenanceKind.normal;
    } else if (geometry == 'central-measured-overlap-grid') {
      kind = TaskResultProvenanceKind.measuredGrid;
    } else if (geometry == 'nominal-fov-grid' || nominalOnly) {
      kind = forcedCells
          ? TaskResultProvenanceKind.forcedGrid
          : TaskResultProvenanceKind.nominalGrid;
    } else if (forcedCells && total != null && forced >= total && !anyVisual) {
      kind = TaskResultProvenanceKind.forcedGrid;
    } else if (forcedCells ||
        (gridEstimates && anyVisual) ||
        geometry?.contains('grid-bridge') == true ||
        geometry?.contains('visual-ray-grid') == true) {
      kind = TaskResultProvenanceKind.mixedGrid;
    } else if (gridEstimates && !anyVisual) {
      kind = TaskResultProvenanceKind.estimatedGrid;
    } else if (hasGridModel || forcedCells || gridEstimates) {
      kind = TaskResultProvenanceKind.mixedGrid;
    } else {
      kind = TaskResultProvenanceKind.unknown;
    }

    return TaskResultProvenance(
      kind: kind,
      forcedGridTileCount: forced,
      visualTileCount: visual,
      gridEstimatedTileCount: estimated,
      totalTileCount: total,
      isAutomaticGridRetry: isAutomaticGridRetry,
    );
  }

  static int? _count(Object? value) =>
      value is num &&
          value.isFinite &&
          value >= 0 &&
          value == value.roundToDouble()
      ? value.toInt()
      : null;
}

extension TaskResultProvenanceKindLabels on TaskResultProvenanceKind {
  String get labelKey => switch (this) {
    TaskResultProvenanceKind.normal => '常规拼接 · 视觉测量',
    TaskResultProvenanceKind.nominalGrid => '名义网格拼接 · 建议复核',
    TaskResultProvenanceKind.measuredGrid => '常规拼接 · 测量网格',
    TaskResultProvenanceKind.estimatedGrid => '网格估算拼接 · 建议复核',
    TaskResultProvenanceKind.mixedGrid => '混合网格辅助',
    TaskResultProvenanceKind.forcedGrid => '强制网格拼接 · 建议复核',
    TaskResultProvenanceKind.unknown => '结果来源未知',
  };

  String get explanationKey => switch (this) {
    TaskResultProvenanceKind.normal => '拼接来源说明：完整视觉对应证据通过测量检查。',
    TaskResultProvenanceKind.nominalGrid => '拼接来源说明：依据名义视角网格估算，建议检查全景。',
    TaskResultProvenanceKind.measuredGrid => '拼接来源说明：依据中心区域测得的网格重叠。',
    TaskResultProvenanceKind.estimatedGrid => '拼接来源说明：存在网格估算位置，建议检查全景。',
    TaskResultProvenanceKind.mixedGrid => '拼接来源说明：视觉对应与网格辅助位置混合。',
    TaskResultProvenanceKind.forcedGrid => '拼接来源说明：存在强制网格单元，建议检查全景。',
    TaskResultProvenanceKind.unknown => '拼接来源未知：没有可读取的结果报告。',
  };
}
