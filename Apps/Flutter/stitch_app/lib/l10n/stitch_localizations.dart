import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// App copy is English by default and follows the host locale at runtime.
/// All Chinese locales use the Simplified Chinese translation.
class StitchLocalizations {
  const StitchLocalizations(this.locale);

  final Locale locale;

  static const supportedLocales = <Locale>[Locale('en'), Locale('zh')];

  static const LocalizationsDelegate<StitchLocalizations> delegate =
      _StitchLocalizationsDelegate();

  static StitchLocalizations of(BuildContext context) =>
      Localizations.of<StitchLocalizations>(context, StitchLocalizations) ??
      const StitchLocalizations(Locale('en'));

  bool get isChinese => locale.languageCode.toLowerCase() == 'zh';

  String get appName => 'PocketGigaScan';

  String get compositionInfoLogs => text('合成信息 / 日志');
  String get stitchDetails => text('合成详情');
  String get stitchingLog => text('合成日志');
  String get stitchingProgressTitle => text('Stitching progress');
  String get importedTaskUnavailable => text(
    'The imported panorama task is not available yet. It remains in the task list; try opening it again.',
  );
  String importedTaskOpenFailed(String error) => isChinese
      ? '无法打开导入的全景任务：$error'
      : 'Could not open the imported panorama task: $error';
  String get stitchingForegroundPowerHint => text(
    'Keep the app open and connect power while stitching. Background work may pause; reopen the app to continue.',
  );
  String get timelineDurationUnknown => text('总用时未知（旧任务没有时间记录）');
  String get timelineTimeUnknown => text('未知');
  String get timelineInProgress => text('进行中');
  String timelineBounds(String started, String finished, String total) =>
      isChinese
      ? '开始：$started\n结束：$finished\n$total'
      : 'Started: $started\nFinished: $finished\n$total';
  String timelineStage(String stage) {
    if (stage.startsWith('retry-matching-progress:') ||
        stage.startsWith('clahe-retry-progress:')) {
      final match = RegExp(r'^[^:]+-progress:(\d+)/(\d+)$').firstMatch(stage);
      final completed = int.tryParse(match?.group(1) ?? '');
      final total = int.tryParse(match?.group(2) ?? '');
      if (completed != null &&
          total != null &&
          total > 0 &&
          completed <= total) {
        final family = text('retry-neighbor-matching');
        final count = '$completed/$total';
        return isChinese ? '$family（$count）' : '$family ($count)';
      }
      return text('retry-neighbor-matching');
    }
    return text(switch (stage) {
      'validate' => 'validate',
      'source-validation' => 'source-validation',
      'validation-complete' => 'validation-complete',
      'register' => 'register',
      'render-level-0' => 'render-level-0',
      'pyramid' => 'pyramid',
      'commit-render' => 'commit-render',
      'commit-export' => 'commit-export',
      'spool-jxl' => 'spool-jxl',
      'encode-jxl' => 'encode-jxl',
      'export' => 'export',
      'optimize-grid-poses' => 'optimize-grid-poses',
      'refine-pixel-texture' => 'refine-pixel-texture',
      'fit-local-texture-warp' => 'fit-local-texture-warp',
      'grid-overlap-feature-extraction' => 'grid-overlap-feature-extraction',
      'grid-overlap-pair-matching' => 'grid-overlap-pair-matching',
      'grid-overlap-complete' => 'grid-overlap-complete',
      'initial-matching-complete' => 'initial-matching-complete',
      'matching-edge-batch' => 'matching-edge-batch',
      'adaptive-diagonal-matching' => 'adaptive-diagonal-matching',
      'retry-matching' => 'retry-neighbor-matching',
      'retry-feature-extraction' => 'retry-neighbor-matching',
      'clahe-retry' => 'retry-neighbor-matching',
      'retry-neighbor-matching' => 'retry-neighbor-matching',
      'registration-complete' => 'registration-complete',
      'semantic-analysis' => 'semantic-analysis',
      'precision-recovery-start' => 'precision-recovery-start',
      'registration-failed' => 'registration-failed',
      'feature-extraction-batch' => 'feature-extraction-batch',
      'feature-extraction-complete' => 'feature-extraction-complete',
      'publish-export' => 'publish-export',
      'publishing' => 'publishing',
      'published' => 'published',
      'publish-failed' => 'publish-failed',
      'prune-conflicting-neighbors' => 'prune-conflicting-neighbors',
      'done' => 'done',
      'paused' => 'paused',
      'cancelled' => 'cancelled',
      _ => stage,
    });
  }

  String timelineTotal(String elapsed, {required bool pausedIncluded}) =>
      isChinese
      ? '总用时：$elapsed${pausedIncluded ? '（包含暂停时间）' : ''}'
      : 'Wall-clock total: $elapsed${pausedIncluded ? ' (includes paused time)' : ''}';
  String timelineTransition(String state, String subject) =>
      '$subject · $state';
  String get settingsTitle => text('设置');
  String memoryBudgetAdmission(
    String operation,
    int requested,
    int limit,
    int held,
  ) => isChinese
      ? '$operation需要${requested.toString()}MiB；当前共享预算${limit.toString()}MiB中已有${held.toString()}MiB被占用。'
      : '$operation needs $requested MiB; $held MiB of the $limit MiB shared budget is already reserved.';
  String memoryConcurrencyAdmission(String operation, int active, int limit) =>
      isChinese
      ? '$operation暂缓：共享并发上限为 $limit 个任务，当前已有 $active 个原生任务占用名额。'
      : '$operation is deferred: the shared concurrency limit is $limit jobs, with $active native job(s) currently using a slot.';
  String resourceBudgetStatusFailed(String operation, String error) => isChinese
      ? '${text('无法确认资源预算')}（$operation）：$error'
      : '${text('无法确认资源预算')} for $operation: $error';
  String pendingLegacyGridLocks(int count) => isChinese
      ? '有 $count 个旧网格锁定位置无法关联到当前照片；它们不会固定其他照片。请检查照片映射，并使用锁定按钮明确固定正确原片。'
      : '$count legacy grid lock position(s) cannot be matched to a photo. They will not lock another photo. Review the mapping and use the lock button on the intended source photo.';
  String get language => text('语言');
  String get appearance => text('外观');
  String get accentColor => text('强调色');
  String get outputQuality => text('输出画质');
  String get outputFormat => text('输出格式');
  String get refineNeighbors => text('精细校正相邻照片位置');
  String get seamBlend => text('接缝融合');
  String get localTextureWarp => text('局部纹理校正');
  String get protectPeople => text('保护人物');
  String get protectPeopleHelp =>
      text('尽量保留完整原片人物，避免接缝切割人物。场景分析需要更多内存，处理时间也更长。');
  String get smoothWater => text('平滑水面');
  String get smoothWaterHelp =>
      text('平滑水面接缝可能会柔化局部细节；同时启用时优先保护人物。场景分析需要更多内存，处理时间也更长。');
  String get sceneModel => text('场景模型');
  String get sceneModelPrepare => text('重新准备模型缓存');
  String get sceneModelBundleHelp => text('模型随 Windows 和 macOS 程序附带，可离线使用。');
  String get sceneModelDelete => text('清除模型使用副本');
  String get sceneModelReady => text('场景模型已验证并可离线使用。');
  String get sceneModelPreparing => text('正在准备并验证场景模型');
  String get done => text('完成');
  String get cancel => text('取消');
  String get retry => text('重试');
  String get maxEdgeReprojectionRms => text('相邻配准误差上限 RMS（像素）');
  String get maxEdgeReprojectionRmsHelp => text('限制相邻照片配准可接受的重投影均方根误差；较低值更严格。');
  String get maxEdgeReprojectionRmsWarning =>
      text('高于 12 像素会放宽配准误差上限，可能接受更不准确的相邻匹配。');
  String get maxEdgeReprojectionRmsLocked =>
      text('任务已提交到原生核心；请先点“新建副本重新合成”再调整。副本会继续使用已校验的原片。');
  String get performanceDefaults => text('性能默认值');
  String get parallelMatching => text('并行图像匹配');
  String get parallelRendering => text('并行分块渲染');
  String get sourceCache => text('启用原片纹理缓存');
  String get alignmentCache => text('缓存图像配准结果');
  String get fastRegistration => text('快速配准');
  String get fourNeighborFirst => text('优先尝试四邻方向（自适应）');
  String get orbFeatures => text('ORB 快速特征');
  String get flannMatching => text('FLANN 近似匹配');
  String get outputFolder => text('输出文件夹');
  String get defaultOutputFolder => text('使用默认文件夹');
  String get useDefaultFolder => text('使用默认文件夹');
  String get chooseFolder => text('选择文件夹');
  String get chooseBatchParentFolder => text('选择包含多个全景子目录的母目录');
  String get dwarfDeviceImport => text('Import from DWARF3');
  String get dwarfDeviceTitle => text('DWARF3 panoramas');
  String get dwarfHost => text('Device address');
  String get dwarfConnect => text('Connect to device');
  String get dwarfReconnect => text('Refresh panoramas');
  String get dwarfOpenWifi => text('Open Wi-Fi settings');
  String get dwarfWifiOpened =>
      text('Wi-Fi settings opened. Join DWARF3, then return here.');
  String get dwarfWifiManual =>
      text('Open Settings > Wi-Fi, join DWARF3, then return here.');
  String get dwarfSelectPanoramas => text('Select panoramas to download');
  String get dwarfDownloadSelected => text('Download selected panoramas');
  String get dwarfQueueCompleted =>
      text('Add downloaded panoramas to stitch queue');
  String get dwarfNoPanoramas =>
      text('No panoramas are available on the device');
  String get dwarfConnectHint =>
      text('Connect to DWARF3 Wi-Fi, then enter the device address.');
  String get dwarfDefaultHostHint => text('Default address: 192.168.88.1');
  String get dwarfDownloadPaused => text('Download paused');
  String get dwarfBackgroundPause => text(
    'Downloads paused when the app entered the background. Resume while the app is open.',
  );
  String get dwarfForegroundPowerHint => text(
    'Keep this page open and connect power. The screen stays awake while downloading; background downloads pause safely.',
  );
  String get dwarfPauseDownload => text('Pause download');
  String get dwarfResumeDownload => text('Resume download');
  String get dwarfRetryDownload => text('Retry failed downloads');
  String get dwarfDownloadComplete => text('Download complete');
  String dwarfDownloadedCount(int count) =>
      isChinese ? '已完成 $count 个全景下载' : '$count panorama download(s) complete';
  String dwarfDownloadProgress(int done, int total, String status) =>
      '$done/$total · ${text(status)}';
  String dwarfDeviceError(String error) =>
      RegExp(r'[\u4e00-\u9fff]').hasMatch(error)
      ? error
      : '${text('DWARF operation failed:')} ${_localizedDwarfError(error)}';
  String _localizedDwarfError(String error) {
    if (!isChinese) return error;
    final normalizedError = error.toLowerCase();
    if (normalizedError.contains('duplicate') ||
        normalizedError.contains('already exists') ||
        normalizedError.contains('same name')) {
      return '设备返回了重复的原片文件名，请刷新全景列表后重试。';
    }
    const messages = <String, String>{
      'The DWARF SD card is unavailable': 'DWARF 存储卡不可用，请检查设备存储卡。',
      'No original JPEGs were found': '所选全景目录中没有找到原始 JPEG 照片。',
      'Selected item is outside DWARF3/Panoramas': '所选项目不在 DWARF3 全景目录中。',
      'DWARF source changed after it was selected': '设备上的原片列表已变化，请刷新后重新选择全景。',
      'DWARF server did not confirm the source validator for resume':
          '设备未确认下载断点对应的原片版本；请重试以重新下载。',
      'Downloaded source is not a complete JPEG': '下载的文件不是完整 JPEG 原片；可以重试下载。',
      'Unsafe download manifest': '下载记录路径无效，无法安全恢复。',
      'Connection refused': '无法连接设备服务。请确认手机已连接 DWARF3 Wi-Fi，地址为 192.168.88.1。',
      'Failed host lookup': '找不到设备地址。请连接 DWARF3 Wi-Fi，并检查设备地址。',
      'Network is unreachable': '网络不可达。请确认手机已连接 DWARF3 Wi-Fi。',
      'timed out': '连接超时。请检查 DWARF3 Wi-Fi 和设备地址后重试。',
    };
    for (final entry in messages.entries) {
      if (error.contains(entry.key)) return entry.value;
    }
    return error
        .replaceFirst('FormatException: ', '数据格式错误：')
        .replaceFirst('HttpException: ', '设备 HTTP 通信失败：')
        .replaceFirst('SocketException: ', '网络连接失败：')
        .replaceFirst('StateError: ', '当前操作无法继续：');
  }

  String dwarfDownloadState(String state) => text(switch (state) {
    'downloading' => 'Downloading',
    'paused' || 'cancelled' => 'Download paused',
    'completed' => 'Download complete',
    'failed' => 'Download failed',
    'queued' => 'Waiting to download',
    _ => state,
  });
  String dwarfByteProgress(int completed, int total) => isChinese
      ? '已下载 ${_formatBytes(completed)} / ${_formatBytes(total)}'
      : 'Downloaded ${_formatBytes(completed)} / ${_formatBytes(total)}';
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  String get dwarfOriginalCount => text('Original photos');
  String get dwarfUnknownSize => text('Size unknown');
  String get dwarfDownloadRestored =>
      text('Recoverable device downloads found');
  String get dwarfDownloading => text('Downloading');
  String get dwarfDismissError => text('Dismiss');
  String get dwarfDeviceTransfers => text('DWARF transfers');
  String get dwarfWaiting => text('Waiting to download');
  String folderSelectionFailed(String error) => '${text('无法选择文件夹：')}$error';
  String get retryOutputCopy => text('重试复制到输出文件夹');
  String outputCopyFailed(String error) => '${text('复制到输出文件夹失败：')}$error';
  String settingsOption(String value) => text(switch (value) {
    'system' => '系统',
    'en' => '英文',
    'zh' => '中文',
    'light' => '浅色',
    'dark' => '深色',
    'teal' => '青绿',
    'blue' => '蓝色',
    'purple' => '紫色',
    'orange' => '橙色',
    'feather' => '羽化',
    'deghost' => '去重影',
    _ => value,
  });
  String settingsSaveFailed(String error) => '${text('设置保存失败：')}$error';

  String get duplicateBeforeEditingSettings => text('先新建副本，再修改设置');

  String get fullResolutionOutputUsesTaskFormat =>
      text('整图输出独立于瓦片预览，使用任务选择的输出格式。');

  String neighborReliabilitySummary({
    required int adjustedEdges,
    required int ambiguousEdges,
  }) => isChinese
      ? '相邻匹配权重调整：$adjustedEdges 条；存在闭环不一致的边：$ambiguousEdges 条。'
      : 'Neighbor match weights adjusted: $adjustedEdges; edges in inconsistent loops: $ambiguousEdges.';

  String phaseLabel(String phase) {
    final normalized = phase.trim().toLowerCase();
    final english = <String, String>{
      'imported': 'Imported',
      'queued': 'Queued',
      'running': 'Stitching',
      'pausing': 'Pausing',
      'paused': 'Paused',
      'interrupted': 'Interrupted',
      'exporting': 'Exporting',
      'completed': 'Completed',
      'failed': 'Failed',
      'cancelled': 'Cancelled',
    };
    final chinese = <String, String>{
      'imported': '已导入',
      'queued': '排队中',
      'running': '合成中',
      'pausing': '正在暂停',
      'paused': '已暂停',
      'interrupted': '已中断',
      'exporting': '正在导出',
      'completed': '已完成',
      'failed': '失败',
      'cancelled': '已取消',
    };
    return (isChinese ? chinese : english)[normalized] ?? text(phase);
  }

  String taskSummary({
    required int photoCount,
    required String phase,
    required String format,
  }) =>
      '$photoCount ${isChinese ? '张' : 'photos'} · '
      '${phaseLabel(phase)} · ${formatLabel(format)}';

  String formatLabel(String format) {
    final normalized = format.trim().toLowerCase();
    if (normalized.startsWith('jpeg xl') ||
        normalized == 'jpegxl' ||
        normalized == 'jxl') {
      return 'JPEG XL';
    }
    if (normalized.startsWith('tiff') || normalized == 'tif') return 'TIFF';
    if (normalized.startsWith('png')) return 'PNG';
    return text(format);
  }

  String exportDescription(String format) {
    final normalized = format.trim().toLowerCase();
    if (normalized == 'png' || normalized.startsWith('png（无损）')) {
      return 'PNG (lossless)';
    }
    if (normalized == 'tiff' ||
        normalized == 'tif' ||
        normalized.startsWith('tiff（无损')) {
      return 'TIFF (lossless; BigTIFF for large images)';
    }
    if (normalized == 'jpeg xl' ||
        normalized == 'jpegxl' ||
        normalized == 'jxl' ||
        normalized.startsWith('jpeg xl（有损）')) {
      return 'JPEG XL (lossy)';
    }
    return format;
  }

  String largeJobConfirmation({
    required int rows,
    required int columns,
    required int photoCount,
    bool onBattery = false,
  }) {
    if (isChinese) {
      return '任务网格为 $rows×$columns，共 $photoCount 张原片，运行时间可能较长。'
          '${onBattery ? '\n当前未连接外接电源，长时间运行可能耗尽电量。' : ''}';
    }
    return 'This job uses a $rows×$columns grid with $photoCount source photos and may run for a while.'
        '${onBattery ? '\nNo external power is connected; a long run may drain the battery.' : ''}';
  }

  /// Bilingual audit plan B: the export viewer's pixel-trace panel is
  /// assembled here so no operator-visible CJK literal remains in the UI.
  String traceOutputLine(String outputX, String outputY, int cameraCount) =>
      isChinese
      ? '输出 ($outputX, $outputY) · 覆盖 $cameraCount 张原片（几何覆盖，不代表最终混合权重）'
      : 'Output ($outputX, $outputY) · $cameraCount geometric source '
            'coverage(s); final blend weights are not reported.';

  String traceCameraLine({
    required String originalName,
    required String sourcePath,
    required int row,
    required int column,
    required String sourceX,
    required String sourceY,
    required String positionSource,
    required String placementKind,
    required String placementOrigin,
    required bool directVisualEvidence,
  }) {
    final position = text(_tracePositionLabel(positionSource));
    final placement = text(_tracePlacementLabel(placementKind));
    final origin = text(_traceOriginLabel(placementOrigin));
    final grid = '${row + 1},${column + 1}';
    if (isChinese) {
      return '$originalName · $sourcePath · 网格 $grid · 原片 ($sourceX, $sourceY) · '
          '$position · $placement / $origin · 直接视觉证据 ${directVisualEvidence ? '有' : '无'}';
    }
    return '$originalName · $sourcePath · grid $grid · source ($sourceX, $sourceY) · '
        '$position · $placement / $origin · '
        'direct visual evidence ${directVisualEvidence ? 'yes' : 'no'}';
  }

  String traceNeighborLine({
    required int row,
    required int column,
    required String disposition,
    String? medianResidualPx,
    String? rmsResidualPx,
  }) {
    final position = text(_traceDispositionLabel(disposition));
    final median = medianResidualPx ?? (isChinese ? '未知' : 'unknown');
    final rms = rmsResidualPx ?? (isChinese ? '未知' : 'unknown');
    final grid = '${row + 1},${column + 1}';
    if (isChinese) {
      return '  邻居 $grid · $position · 中位残差 $median px · RMS $rms px';
    }
    return '  Neighbor $grid · $position · median $median px · RMS $rms px';
  }

  String traceUnknownFormat(String extension) =>
      isChinese ? '未知格式（$extension）' : 'Unknown format ($extension)';

  String traceUnavailableReason(String reason) => text(switch (reason) {
    'traceLoadFailed' => '无法安全验证布局来源，像素追踪已停用。',
    'associationMismatch' => '任务记录未验证当前输出与布局清单的关联。',
    'noVerifiedReceipt' => '此格式没有可验证的导出回执，来源追踪已停用。',
    'outputPreviewDimensionMismatch' => '实际输出尺寸与分块预览清单不一致，来源追踪已停用。',
    'outputRecordDimensionMismatch' => '实际输出尺寸与任务记录不一致，来源追踪已停用。',
    'outputManifestDimensionMismatch' => '输出尺寸与任务清单不一致，来源追踪已停用。',
    'layoutManifestIntegrityFailed' => '任务布局或清单校验失败，来源追踪已停用。',
    'manifestPathMismatch' => '任务记录与当前预览清单不是同一文件。',
    'layoutOutsideTask' => '布局文件路径超出任务目录，已拒绝读取。',
    'layoutTooLarge' => '布局记录超过安全读取上限。',
    'layoutDimensionMismatch' => '布局投影或输出尺寸与实际文件不一致。',
    'invalidOutputCoordinate' => '输出坐标或布局无效。',
    'layoutTilesMissing' => '布局缺少相机信息。',
    'layoutBoundsInvalid' => '布局投影范围无效。',
    'taskGridInvalid' => '任务网格映射无效。',
    _ => '几何追踪数据无效，已停止检查。',
  });

  String _tracePositionLabel(String value) => switch (value) {
    'visual' => '视觉测量',
    'gridEstimated' => '网格估算',
    _ => '位置来源未知',
  };

  String _tracePlacementLabel(String value) => switch (value) {
    'hardGridLock' => '网格硬锁',
    'gridPrior' => '网格先验',
    'none' => '无放置约束',
    _ => '约束未知',
  };

  String _traceOriginLabel(String value) => switch (value) {
    'operator' => '操作员',
    'systemFallback' => '系统回退',
    'legacyUnknown' => '旧记录来源未知',
    _ => '来源未知',
  };

  String _traceDispositionLabel(String value) => switch (value) {
    'accepted' => '已接受',
    'forced_grid_cell' => '网格硬锁边，未参与视觉匹配',
    'descriptor_missing_or_invalid' => '描述子缺失或无效',
    'too_few_ratio_test_matches' => '比率检验匹配不足',
    'ransac_failed' => 'RANSAC 失败',
    'too_few_inliers' => '内点不足',
    'low_inlier_ratio' => '内点比例过低',
    'ray_fit_pending' => '等待射线拟合',
    'weak_support_loop_conflict' => '弱支持回环冲突',
    'ray_fit_degenerate' => '射线拟合退化',
    'ray_residual_exceeds_12px' => '射线残差超过 12 px 门限',
    'rejected_joint_pixel_leave_one_out_conflict' => '联合像素留一冲突',
    'weak_support' => '支持不足',
    _ => '状态未知',
  };

  String text(String source) {
    final unwrapped = source.replaceFirst(
      RegExp(r'^(?:Bad state: |Exception: )'),
      '',
    );
    if (unwrapped != source) return text(unwrapped);
    if (source.startsWith(
      'FileSystemException: Bundled scene model is missing',
    )) {
      return text('Bundled scene model is missing.');
    }
    final modelSizeMismatch = RegExp(
      r'^Scene model size mismatch: expected (\d+) bytes, received (\d+)\.$',
    ).firstMatch(source);
    if (modelSizeMismatch != null) {
      return isChinese
          ? '场景模型大小不匹配：预期 ${modelSizeMismatch[1]} 字节，实际 ${modelSizeMismatch[2]} 字节。'
          : source;
    }
    final publishError = RegExp(
      r'^发布失败：(.*)。私有整图已保留，可重试发布。$',
    ).firstMatch(source);
    if (publishError != null) {
      return isChinese
          ? source
          : 'Publishing failed: ${publishError[1]}. The private full image is preserved; retry publishing.';
    }
    final nativeRendererError = RegExp(
      r'^(?:([A-Z0-9_]+): )?(invalid input: )?renderer algorithm changed; create a task copy and restitch(?: to avoid mixing tiles)?$',
    ).firstMatch(source);
    if (nativeRendererError != null) {
      if (!isChinese) return source;
      final prefix = [
        if (nativeRendererError[1] != null) '${nativeRendererError[1]}: ',
        if (nativeRendererError[2] != null) '输入无效：',
      ].join();
      final translated = source.endsWith('to avoid mixing tiles')
          ? '渲染算法已更改；请新建任务副本并重新合成，以避免瓦片混用。'
          : '渲染算法已更改；请新建任务副本并重新合成。';
      return '$prefix$translated';
    }
    final details = RegExp(r'^(\d+) 张 · (.+) · (.+)$').firstMatch(source);
    if (details != null) {
      return taskSummary(
        photoCount: int.parse(details[1]!),
        phase: details[2]!,
        format: details[3]!,
      );
    }
    final fullImageFormat = RegExp(r'^整图格式：(.+)$').firstMatch(source);
    if (fullImageFormat != null) {
      return isChinese
          ? source
          : 'Full image format: ${exportDescription(fullImageFormat[1]!)}';
    }
    if (isChinese) {
      final modelProgress = RegExp(r'^正在准备场景模型：(\d+)%$').firstMatch(source);
      if (modelProgress != null) {
        return '正在准备场景模型：${modelProgress[1]}%';
      }
      final modelMemory = RegExp(
        r'^scene analysis needs approximately (\d+) MiB for (\d+)x(\d+) source, model and ONNX Runtime workspace, above the (\d+) MiB job budget$',
      ).firstMatch(source);
      if (modelMemory != null) {
        return '场景分析约需 ${modelMemory[1]} MiB（${modelMemory[2]}×${modelMemory[3]} 原片、模型及 ONNX Runtime 工作区），超过 ${modelMemory[4]} MiB 任务预算。';
      }
      final prefixedNativeError = RegExp(
        r'^([A-Z0-9_]+): (.*)$',
      ).firstMatch(source);
      if (prefixedNativeError != null) {
        final nested = text(prefixedNativeError[2]!);
        if (nested != prefixedNativeError[2]) {
          return '${prefixedNativeError[1]}: $nested';
        }
      }
      for (final entry in _zh.entries) {
        if (source.startsWith('${entry.key}: ')) {
          return '${entry.value}：${source.substring(entry.key.length + 2)}';
        }
      }
      return _zh[source] ?? source;
    }
    final exact = _en[source];
    if (exact != null) return exact;
    final status = RegExp(r'^(.+) · (\d+)% · (.+)$').firstMatch(source);
    if (status != null) {
      return '${text(status[1]!)} · ${status[2]}% · ${text(status[3]!)}';
    }
    final autoExport = RegExp(r'^完成后自动导出：(.+)$').firstMatch(source);
    if (autoExport != null) {
      return 'Automatic export after stitching: ${formatLabel(autoExport[1]!)}';
    }
    for (final entry in _en.entries) {
      if ((entry.key.endsWith('：') || entry.key == '设置 ') &&
          source.startsWith(entry.key)) {
        return '${entry.value}${source.substring(entry.key.length)}';
      }
    }
    final nativeJobStateKept = RegExp(
      r'^原生任务状态为 (.+)；停止确认前保留本地任务$',
    ).firstMatch(source);
    if (nativeJobStateKept != null) {
      return 'Native job state is ${nativeJobStateKept[1]}; '
          'the local task is kept until stop is confirmed';
    }
    final nativeJobState = RegExp(r'^原生任务状态为 (.+)$').firstMatch(source);
    if (nativeJobState != null) {
      return 'Native job state is ${nativeJobState[1]}';
    }
    final nativeLibraryMissing = RegExp(
      r'^未找到原生库 (.+)：(.*)$',
    ).firstMatch(source);
    if (nativeLibraryMissing != null) {
      return 'Native library ${nativeLibraryMissing[1]} not found: '
          '${nativeLibraryMissing[2]}';
    }
    final nativeAbiMismatch = RegExp(
      r'^不兼容的原生核心 ABI：(.+)（需要 (.+)）$',
    ).firstMatch(source);
    if (nativeAbiMismatch != null) {
      return 'Incompatible native core ABI: ${nativeAbiMismatch[1]} '
          '(requires ${nativeAbiMismatch[2]})';
    }
    final newExportKept = RegExp(
      r'^新整图导出(.+)；保留了此前成功的导出文件。$',
    ).firstMatch(source);
    if (newExportKept != null) {
      return 'New full-image export ${newExportKept[1]}; '
          'the previously successful export file is preserved.';
    }
    final exportState = RegExp(r'^整图导出(.+)。$').firstMatch(source);
    if (exportState != null) {
      return 'Full image export ${exportState[1]}.';
    }
    final fullNotGenerated = RegExp(r'^完整(.+)尚未生成。$').firstMatch(source);
    if (fullNotGenerated != null) {
      return 'The full ${formatLabel(fullNotGenerated[1]!)} '
          'has not been generated yet.';
    }
    final waitingExport = RegExp(r'^合成完成，等待 (.+) 导出$').firstMatch(source);
    if (waitingExport != null) {
      return 'Composition complete; waiting for '
          '${exportDescription(waitingExport[1]!)} export';
    }
    final exportingFullImage = RegExp(r'^合成完成，正在导出整图 (.+)$').firstMatch(source);
    if (exportingFullImage != null) {
      return 'Composition complete; exporting the full '
          '${formatLabel(exportingFullImage[1]!)}';
    }
    final exportingImage = RegExp(r'^合成完成，正在导出 (.+)$').firstMatch(source);
    if (exportingImage != null) {
      return 'Composition complete; exporting ${formatLabel(exportingImage[1]!)}';
    }
    final exportFullImage = RegExp(r'^导出整图 (.+)$').firstMatch(source);
    if (exportFullImage != null) {
      return 'Exporting the full ${formatLabel(exportFullImage[1]!)}';
    }
    final retryFullImage = RegExp(r'^重试完整 (.+)$').firstMatch(source);
    if (retryFullImage != null) {
      return 'Retry full ${formatLabel(retryFullImage[1]!)}';
    }
    final exportFull = RegExp(r'^导出完整 (.+)$').firstMatch(source);
    if (exportFull != null) {
      return 'Export full ${formatLabel(exportFull[1]!)}';
    }
    final waitingOperation = RegExp(r'^(.+)（等待当前操作完成）$').firstMatch(source);
    if (waitingOperation != null) {
      return '${text(waitingOperation[1]!)} '
          '(waiting for the current operation to finish)';
    }
    final filenameGrid = RegExp(r'^按文件名识别 (\d+)×(\d+)$').firstMatch(source);
    if (filenameGrid != null) {
      return 'Identified a ${filenameGrid[1]}×${filenameGrid[2]} grid from filenames';
    }
    final estimatedRows = RegExp(r'^估算为 (\d+)×(\d+)，按行排列$').firstMatch(source);
    if (estimatedRows != null) {
      return 'Estimated as ${estimatedRows[1]}×${estimatedRows[2]}, '
          'arranged by rows';
    }
    final confirmedFilenameGrid = RegExp(
      r'^已确认文件名中的 (\d+)×(\d+) 网格与相机视角$',
    ).firstMatch(source);
    if (confirmedFilenameGrid != null) {
      return 'Confirmed the ${confirmedFilenameGrid[1]}×'
          '${confirmedFilenameGrid[2]} grid and camera angles from filenames';
    }
    final confirmedSequence = RegExp(
      r'^已确认 (\d+)×(\d+) 顺序排列与相机视角$',
    ).firstMatch(source);
    if (confirmedSequence != null) {
      return 'Confirmed the ${confirmedSequence[1]}×${confirmedSequence[2]} '
          'sequential layout and camera angles';
    }
    final estimatedArrangement = RegExp(
      r'^(.+) · 估算排列，建议检查$',
    ).firstMatch(source);
    if (estimatedArrangement != null) {
      return '${text(estimatedArrangement[1]!)} · estimated arrangement, '
          'review it';
    }
    final phaseEtaMinutes = RegExp(
      r'^(\d+)% · 本阶段预计剩余 (\d+) 分 (\d+) 秒$',
    ).firstMatch(source);
    if (phaseEtaMinutes != null) {
      return '${phaseEtaMinutes[1]}% · ${phaseEtaMinutes[2]} min '
          '${phaseEtaMinutes[3]} sec remaining in this phase';
    }
    final phaseEtaSeconds = RegExp(
      r'^(\d+)% · 本阶段预计剩余 (\d+) 秒$',
    ).firstMatch(source);
    if (phaseEtaSeconds != null) {
      return '${phaseEtaSeconds[1]}% · ${phaseEtaSeconds[2]} sec '
          'remaining in this phase';
    }
    final durationMinutes = RegExp(r'^(\d+) 分 (\d+) 秒$').firstMatch(source);
    if (durationMinutes != null) {
      return '${durationMinutes[1]} min ${durationMinutes[2]} sec';
    }
    final durationSeconds = RegExp(r'^(\d+) 秒$').firstMatch(source);
    if (durationSeconds != null) {
      return '${durationSeconds[1]} sec';
    }
    final elapsed = RegExp(r'^已用 (\d+) 秒$').firstMatch(source);
    if (elapsed != null) return 'Elapsed ${elapsed[1]} sec';
    final elapsedMinutes = RegExp(r'^已用 (\d+) 分 (\d+) 秒$').firstMatch(source);
    if (elapsedMinutes != null) {
      return 'Elapsed ${elapsedMinutes[1]} min ${elapsedMinutes[2]} sec';
    }
    final estimatedGrid = RegExp(r'^网格为估算值，尚未校准；(.+)$').firstMatch(source);
    if (estimatedGrid != null) {
      final translatedDetails = estimatedGrid[1]!
          .split(' · ')
          .map((detail) {
            if (detail.startsWith('方法 ')) {
              return 'Method ${detail.substring('方法 '.length)}';
            }
            if (detail.startsWith('置信度 ')) {
              return 'Confidence ${detail.substring('置信度 '.length)}';
            }
            return detail;
          })
          .join(' · ');
      return 'Grid positions are estimated and are not calibrated; '
          '$translatedDetails';
    }
    final running = RegExp(
      r'^(\d+)/(\d+) 已导出 · (\d+) 项处理中$',
    ).firstMatch(source);
    if (running != null) {
      return '${running[1]}/${running[2]} exported · ${running[3]} in progress';
    }
    final imageTotal = RegExp(r'^上次成功整图 (.+)：(.+)$').firstMatch(source);
    if (imageTotal != null) {
      return 'Last successful full image ${imageTotal[1]}: ${imageTotal[2]}';
    }
    final filenameGridGap = RegExp(
      r'^文件名网格有空格；请切换到顺序模式并调整行列。所有 (\d+) 张原片都会保留。$',
    ).firstMatch(source);
    if (filenameGridGap != null) {
      return 'The filename grid has gaps; switch to sequence mode and adjust rows and columns. All ${filenameGridGap[1]} source photos will be kept.';
    }
    final zoom = RegExp(r'^缩放 (\d+)%$').firstMatch(source);
    if (zoom != null) return 'Zoom ${zoom[1]}%';
    final level = RegExp(r'^预览层级 (\d+)$').firstMatch(source);
    if (level != null) return 'Preview level ${level[1]}';
    final coreTime = RegExp(r'^核心计时 · (.+)：([\d.]+) 秒$').firstMatch(source);
    if (coreTime != null) {
      return 'Engine timing · ${text(coreTime[1]!)}: ${coreTime[2]} sec';
    }
    final estimate = RegExp(
      r'^估算网格步长：水平 (.+) px · 垂直 (.+) px$',
    ).firstMatch(source);
    if (estimate != null) {
      return 'Estimated grid step: horizontal ${estimate[1]} px · '
          'vertical ${estimate[2]} px';
    }
    final overlap = RegExp(
      r'^中间相邻照片估算重叠：水平 (.+) · 垂直 (.+)$',
    ).firstMatch(source);
    if (overlap != null) {
      return 'Measured overlap between center neighbors: horizontal '
          '${overlap[1]} · vertical ${overlap[2]}';
    }
    final evidence = RegExp(r'^估算证据：(\d+) 组相邻照片配对$').firstMatch(source);
    if (evidence != null) {
      return 'Estimate evidence: ${evidence[1]} neighboring photo pairs';
    }
    final cameraProfile = RegExp(
      r'^已按照片 EXIF 识别 DWARFLAB / DWARF3 / TELE；使用名义 150 mm 配置 fx=(.+) px（随图像宽度缩放），未校准。实际 EXIF 焦距：(.*)$',
    ).firstMatch(source);
    if (cameraProfile != null) {
      final rawFocalLength = cameraProfile[2]!;
      final focalLength = rawFocalLength.startsWith('未记录')
          ? 'not recorded${rawFocalLength.substring('未记录'.length)}'.replaceAll(
              '。',
              '.',
            )
          : rawFocalLength;
      return 'DWARFLAB / DWARF3 / TELE identified from photo EXIF. Using '
          'nominal 150 mm profile fx=${cameraProfile[1]} px (scaled to image '
          'width), not calibrated. EXIF focal length: $focalLength';
    }
    final panoramaLevel = RegExp(r'^分块全景 · (\d+)$').firstMatch(source);
    if (panoramaLevel != null) {
      return 'Tiled panorama · level ${panoramaLevel[1]}';
    }
    final itemCount = RegExp(
      r'^已复制并校验 (\d+) 张原片（(\d+)×(\d+)）。$',
    ).firstMatch(source);
    if (itemCount != null) {
      return 'Copied and verified ${itemCount[1]} source photos '
          '(${itemCount[2]}×${itemCount[3]}).';
    }
    final retained = RegExp(
      r'^全部 (\d+) 张照片保留；尺寸 (.+)。无法映射时不会丢弃原片。$',
    ).firstMatch(source);
    if (retained != null) {
      return 'All ${retained[1]} photos are kept; dimensions ${retained[2]}. '
          'Photos are never discarded when mapping fails.';
    }
    final mappingCount = RegExp(r'^照片与网格映射（(\d+)/(\d+)）$').firstMatch(source);
    if (mappingCount != null) {
      return 'Photo-to-grid mapping (${mappingCount[1]}/${mappingCount[2]})';
    }
    final recentSeconds = RegExp(r'^正在暂停 · (\d+) 秒$').firstMatch(source);
    if (recentSeconds != null) return 'Pausing · ${recentSeconds[1]} sec';
    final recentMinutes = RegExp(
      r'^正在暂停 · (\d+) 分 (\d+) 秒$',
    ).firstMatch(source);
    if (recentMinutes != null) {
      return 'Pausing · ${recentMinutes[1]} min ${recentMinutes[2]} sec';
    }
    final taskDimensions = RegExp(
      r'^(\d+) 张原片 · (\d+×\d+)$',
    ).firstMatch(source);
    if (taskDimensions != null) {
      return '${taskDimensions[1]} source photos · ${taskDimensions[2]}';
    }
    final photosOnly = RegExp(r'^(\d+) 张原片 · ?$').firstMatch(source);
    if (photosOnly != null) return '${photosOnly[1]} source photos';
    final itemElapsed = RegExp(r'^(.+) · 已用 (\d+) 秒$').firstMatch(source);
    if (itemElapsed != null) {
      return '${text(itemElapsed[1]!)} · Elapsed ${itemElapsed[2]} sec';
    }
    final itemElapsedMinutes = RegExp(
      r'^(.+) · 已用 (\d+) 分 (\d+) 秒$',
    ).firstMatch(source);
    if (itemElapsedMinutes != null) {
      return '${text(itemElapsedMinutes[1]!)} · Elapsed '
          '${itemElapsedMinutes[2]} min ${itemElapsedMinutes[3]} sec';
    }
    return source;
  }

  static const _en = <String, String>{
    'Bundled scene model is missing.': 'The bundled scene model is missing.',
    'Scene model SHA-256 verification failed.':
        'Scene model SHA-256 verification failed.',
    'Scene model manifest is invalid.': 'The scene model manifest is invalid.',
    'Scene model manifest has an invalid bundled model path.':
        'The scene model bundle path is invalid.',
    'Scene model is unavailable: its verified SHA-256 is not configured.':
        'The scene model is unavailable because its verified SHA-256 is missing.',
    'Scene model is unavailable: its verified file size is not configured.':
        'The scene model is unavailable because its verified file size is missing.',
    'Cannot remove the scene model while a task is active.':
        'Cannot remove the scene model while a task is active.',
    'Cannot remove the scene model during preparation.':
        'Cannot remove the scene model while it is being prepared.',
    'semantic-analysis': 'Semantic scene analysis',
    '正在准备场景模型：': 'Preparing scene model: ',
    '保护人物': 'Protect people',
    '尽量保留完整原片人物，避免接缝切割人物。场景分析需要更多内存，处理时间也更长。':
        'Preserve people from the original photos and avoid cutting them at seams where possible. Scene analysis uses more memory and takes longer.',
    '平滑水面': 'Smooth water',
    '平滑水面接缝可能会柔化局部细节；同时启用时优先保护人物。场景分析需要更多内存，处理时间也更长。':
        'Smooth water seams may soften local detail. People protection takes priority when both are enabled. Scene analysis uses more memory and takes longer.',
    '场景模型': 'Scene model',
    '重新准备模型缓存': 'Prepare model cache again',
    '模型随 Windows 程序附带，可离线使用。':
        'The model is included with the Windows app and works offline.',
    '清除模型使用副本': 'Clear cached model copy',
    '场景模型已验证并可离线使用。': 'The scene model is verified and available offline.',
    '正在准备并验证场景模型': 'Preparing and verifying the scene model',
    'Import from DWARF3': 'Import from DWARF3',
    'DWARF3 panoramas': 'DWARF3 panoramas',
    'Device address': 'Device address',
    'Connect to device': 'Connect to device',
    'Refresh panoramas': 'Refresh panoramas',
    'Open Wi-Fi settings': 'Open Wi-Fi settings',
    'Wi-Fi settings opened. Join DWARF3, then return here.':
        'Wi-Fi settings opened. Join DWARF3, then return here.',
    'Open Settings > Wi-Fi, join DWARF3, then return here.':
        'Open Settings > Wi-Fi, join DWARF3, then return here.',
    'Select panoramas to download': 'Select panoramas to download',
    'Download selected panoramas': 'Download selected panoramas',
    'Add downloaded panoramas to stitch queue':
        'Add downloaded panoramas to stitch queue',
    'No panoramas are available on the device':
        'No panoramas are available on the device',
    'Connect to DWARF3 Wi-Fi, then enter the device address.':
        'Connect to DWARF3 Wi-Fi, then enter the device address.',
    'Default address: 192.168.88.1': 'Default address: 192.168.88.1',
    'Download paused': 'Download paused',
    'Downloads paused when the app entered the background. Resume while the app is open.':
        'Downloads paused when the app entered the background. Resume while the app is open.',
    'Keep this page open and connect power. The screen stays awake while downloading; background downloads pause safely.':
        'Keep this page open and connect power. The screen stays awake while downloading; background downloads pause safely.',
    'Download failed': 'Download failed',
    'Pause download': 'Pause download',
    'Resume download': 'Resume download',
    'Retry failed downloads': 'Retry failed downloads',
    'Download complete': 'Download complete',
    'Device connection failed:': 'Device connection failed:',
    'DWARF operation failed:': 'DWARF operation failed:',
    '移动端将文件夹复制到应用私有暂存目录，再逐个导入其中的原片。':
        'Mobile devices copy the selected folder into private app staging, then import its source photos one panorama at a time.',
    '无法读取移动端后台暂停记录；请重试后再启动或恢复。':
        'Could not read mobile background pause records. Retry before starting or resuming work.',
    '移动端应用进入后台；原生任务仍在停止，等待确认安全暂停。':
        'The app entered the background; the native job is stopping while a safe pause is confirmed.',
    '移动端应用进入后台；保留此前成功的导出结果。':
        'The app entered the background; the previous successful export is preserved.',
    '移动端应用进入后台；任务已安全暂停。':
        'The app entered the background; the job is safely paused.',
    '移动端应用进入后台；已记录原生任务的终止状态。':
        'The app entered the background; the native job state is recorded.',
    '无法启动移动端后台运行保护；核心任务尚未启动':
        'Could not register mobile background handling; the native job has not started.',
    '移动端无法启动后台任务管理，任务已安全暂停':
        'Mobile background handling could not start; the job is safely paused.',
    '移动端无法确认后台安全暂停，正在核对原生任务状态':
        'Could not confirm a safe mobile background pause; checking native job state.',
    '移动端无法启动后台任务管理；未开始导出。':
        'Mobile background handling could not start; export has not started.',
    '移动端无法确认安全暂停；正在核对原生任务状态。':
        'Could not confirm a safe pause; checking native job state.',
    '移动端无法确认安全暂停，正在核对原生任务状态。':
        'Could not confirm a safe pause; checking native job state.',
    'Original photos': 'Original photos',
    'Size unknown': 'Size unknown',
    'Recoverable device downloads found': 'Recoverable device downloads found',
    'Downloading': 'Downloading',
    'Dismiss': 'Dismiss',
    'DWARF transfers': 'DWARF transfers',
    'Waiting to download': 'Waiting to download',
    '应用内存预算': 'App memory budget',
    '无法确认资源预算': 'Could not verify the resource budget',
    '恢复任务': 'Resume task',
    '启动任务': 'Start task',
    '整图导出': 'Full-image export',
    '为整个应用设置共享预算；不会预先占用所选内存，也不代表操作系统硬内存限制。':
        'Set the shared app-wide managed reservation and cache budget. It does not allocate memory up front or impose an operating-system RSS limit.',
    '自动分配': 'Automatic',
    '根据当前可用内存自动推荐。': 'Recommended from currently available memory.',
    '手动设置': 'Manual',
    '限制所有并行任务共享的总预算。':
        'Sets the aggregate managed reservation and cache budget shared by concurrent tasks.',
    '已选': 'Selected',
    '总内存': 'Total memory',
    '可用': 'Available',
    '推荐': 'Recommended',
    '本次上限': 'Current maximum',
    '使用保守回退值': 'Using conservative fallback',
    '设置': 'Settings',
    '语言': 'Language',
    '外观': 'Appearance',
    '强调色': 'Accent color',
    '合成详情': 'Stitch details',
    '合成日志': 'Stitching log',
    '总用时未知（旧任务没有时间记录）': 'Total time unknown (legacy task has no timing data)',
    '总用时：': 'Total time: ',
    '未知': 'Unknown',
    '进行中': 'In progress',
    'validate': 'Input validation',
    'source-validation': 'Source validation',
    'validation-complete': 'Validation complete',
    'register': 'Photo registration',
    'render-level-0': 'Full-resolution rendering',
    'pyramid': 'Preview pyramid',
    'commit-render': 'Save render checkpoint',
    'commit-export': 'Save export checkpoint',
    'spool-jxl': 'Prepare JPEG XL output',
    'encode-jxl': 'Encode JPEG XL',
    'export': 'Full image export',
    'optimize-grid-poses': 'Optimize grid alignment',
    'refine-pixel-texture': 'Refine pixel alignment',
    'fit-local-texture-warp': 'Fit local texture correction',
    'grid-overlap-feature-extraction': 'Find grid overlap features',
    'grid-overlap-pair-matching': 'Match grid overlaps',
    'grid-overlap-complete': 'Grid overlap analysis complete',
    'initial-matching-complete': 'Initial matching complete',
    'matching-edge-batch': 'Match neighboring photos',
    'adaptive-diagonal-matching': 'Check diagonal neighbors',
    'retry-neighbor-matching': 'Retry neighbor matching',
    'precision-recovery-start': 'Retry registration at higher precision',
    'registration-complete': 'Registration complete',
    'registration-failed': 'Registration failed',
    'feature-extraction-batch': 'Extract image features',
    'feature-extraction-complete': 'Feature extraction complete',
    'publish-export': 'Copy export to chosen folder',
    'publishing': 'Publishing export',
    'published': 'Export published',
    'publish-failed': 'Export publishing failed',
    'prune-conflicting-neighbors': 'Remove conflicting neighbor matches',
    'done': 'Done',
    'paused': 'Paused',
    'cancelled': 'Cancelled',
    '重试复制到输出文件夹': 'Retry copy to output folder',
    '复制到输出文件夹失败：': 'Could not copy to output folder: ',
    '重试发布整图': 'Retry publishing export',
    '输出画质': 'Output quality',
    '相邻配准误差上限 RMS（像素）': 'Neighbor registration RMS limit (pixels)',
    '限制相邻照片配准可接受的重投影均方根误差；较低值更严格。':
        'Limits the acceptable reprojection RMS for neighboring photo matches; lower values are stricter.',
    '高于 12 像素会放宽配准误差上限，可能接受更不准确的相邻匹配。':
        'Values above 12 pixels relax the registration limit and may accept less accurate neighbor matches.',
    '任务已提交到原生核心；请先点“新建副本重新合成”再调整。副本会继续使用已校验的原片。':
        'This task was submitted to the native engine. Choose “Create a copy and restitch” before changing this value. The copy keeps using the verified source photos.',
    '接缝融合': 'Seam blending',
    '性能默认值': 'Performance defaults',
    '输出文件夹': 'Output folder',
    '使用默认文件夹': 'Use default folder',
    '选择文件夹': 'Choose folder',
    '系统': 'System',
    '中文': 'Chinese',
    '英文': 'English',
    '浅色': 'Light',
    '深色': 'Dark',
    '青绿': 'Teal',
    '蓝色': 'Blue',
    '紫色': 'Purple',
    '橙色': 'Orange',
    '羽化': 'Feather',
    '去重影': 'Deghost',
    '设置保存失败：': 'Could not save settings: ',
    'Lumia Stitch': 'PocketGigaScan',
    'DWARF Stitch': 'PocketGigaScan',
    '本地任务': 'Local tasks',
    '任务记录': 'Task history',
    '导入原片': 'Import photos',
    '导入照片': 'Import photos',
    '批处理仅限 Windows 桌面版': 'Batch processing is available on Windows desktop',
    '查看输出': 'View output',
    '整图输出': 'Full image output',
    '合成信息 / 日志': 'Stitch details / log',
    '先新建副本，再修改设置': 'Create a copy before changing settings',
    '整图输出独立于瓦片预览，使用任务选择的输出格式。':
        'Full-resolution output is separate from the tile preview and uses the format selected for this task.',
    '排列与相机': 'Grid and camera',
    '输出与画质': 'Output and quality',
    '局部纹理校正': 'Local texture correction',
    '查看输出信息': 'View output information',
    '收起输出信息': 'Hide output information',
    '保存整图': 'Save full image',
    '分享整图': 'Share full image',
    '已保存整图': 'Full image saved',
    '保存已取消或失败': 'Save was canceled or failed',
    '已发送整图': 'Full image shared',
    '分享已取消或失败': 'Share was canceled or failed',
    '批处理队列': 'Batch queue',
    '批准并开始': 'Approve and start',
    '确认后开始': 'Review and start',
    '确认大型任务': 'Confirm large job',
    '等待大型任务确认': 'Waiting for large-job approval',
    '确认大型合成任务': 'Confirm large stitching job',
    '无法设置 Android 渲染资源预算，已暂缓启动。':
        'Could not configure Android render resources. The job was not started.',
    '无法设置 iOS 渲染资源预算，已暂缓启动。':
        'Could not configure iOS render resources. The job was not started.',
    '无法保存 iOS 后台暂停记录；请重试后再启动或恢复。':
        'Could not save the iOS background pause record; retry before starting or resuming.',
    '无法启动 iOS 后台任务管理；核心任务尚未启动':
        'iOS could not register foreground work; the native job was not started.',
    '设备温度较高，待温度降低后再启动新任务。':
        'Device temperature is elevated. Wait for it to cool before starting another job.',
    '已按设备当前资源限制并发参数。':
        'Concurrency settings were limited to current device resources.',
    '大型任务需要重新确认': 'This large job needs approval again',
    '正在安全暂停大型任务；确认后才能继续':
        'Safely pausing this large job; it can continue after approval',
    '大型任务需要确认后才会开始': 'This large job needs approval before it starts',
    '无法启动后台运行保护；任务已请求暂停':
        'Background protection could not start. A safe pause was requested.',
    'Android 无法启动后台运行保护，任务已请求暂停':
        'Android background protection could not start. A safe pause was requested.',
    'Android 无法启动后台运行保护，任务已暂停':
        'Android background protection could not start. The task is paused.',
    '无法启动后台运行保护；整图导出未开始。':
        'Background protection could not start. Full-image export was not started.',
    'Android 后台运行时限已到，任务已请求安全暂停':
        'Android background runtime limit reached. A safe pause was requested.',
    'Android 后台运行时限已到；核心状态已确认':
        'Android background execution timed out; the native job state is confirmed.',
    'Android 后台运行时限已到；正在核对暂停状态':
        'Android background execution timed out; checking the pause state.',
    '已安全暂停': 'Safely paused',
    '核心作业已结束': 'The native job has ended',
    '正在安全暂停；等待核心确认': 'Safely pausing; waiting for the native job to confirm.',
    '无法读取 Android 后台超时记录；批处理任务保持待核对：':
        'Unable to read the Android background-timeout record; batch jobs remain pending verification: ',
    '无法读取 Android 后台超时记录；启动、恢复与导出已暂缓：':
        'Unable to read the Android background-timeout record; start, resume, and export are deferred: ',
    '无法保存 Android 后台暂停记录；请重试后再启动或恢复。':
        'Could not save the Android background pause record; retry before starting or resuming.',
    'Android 后台超时任务仍待安全核对：':
        'Android background-timeout jobs still require safety verification: ',
    'Android 后台运行时限已到，原生任务仍在停止；等待确认安全暂停。':
        'Android background execution timed out; the native job is still stopping. Waiting to confirm a safe pause.',
    'Android 后台运行时限已到，任务已安全暂停。':
        'Android background execution timed out; the job is safely paused.',
    'Android 后台运行时限已到；已记录原生任务的终止状态。':
        'Android background execution timed out; the native job\'s terminal state was recorded.',
    'Android 后台运行时限已到；保留此前成功的导出结果。':
        'Android background execution timed out; the previous successful export is preserved.',
    '无法启动 Android 后台运行保护；核心任务尚未启动':
        'Android background protection could not start; the native job was not started.',
    'Android 后台运行保护不可用；请手动重试导出':
        'Android background protection is unavailable; retry the export manually.',
    '无法启动 Android 后台运行保护；整图导出尚未启动':
        'Android background protection could not start; the full-image export was not started.',
    '无法启动后台运行保护；导出保持暂停':
        'Background protection could not start; the export remains paused.',
    '无法启动后台运行保护；任务已安全暂停':
        'Background protection could not start; the job is safely paused.',
    '无法启动后台运行保护；正在核对核心暂停状态':
        'Background protection could not start; checking the native pause state.',
    'Android 无法确认后台安全暂停，正在核对原生任务状态':
        'Android could not confirm a safe background pause; checking the native job state.',
    'Android 批处理需要选择一个包含全景子目录的母目录。':
        'Choose a parent folder containing panorama subfolders to add an Android batch.',
    'Android 将文件夹复制到应用私有暂存目录，再逐个导入其中的原片。':
        'Android copies the selected folder to private staging, then imports each panorama subfolder.',
    '批处理仅在 Windows 桌面版开放。移动版仍可使用单任务合成。':
        'Batch processing is available on desktop. Mobile can still stitch single tasks.',
    '保存到设备': 'Save to device',
    '分享到…': 'Share…',
    '保存成功': 'Saved successfully',
    '分享已取消': 'Sharing was cancelled',
    '提速测试选项': 'Performance options',
    '保存任务设置': 'Save task settings',
    '保存': 'Save',
    '返回': 'Back',
    '取消': 'Cancel',
    '应用': 'Apply',
    '保留': 'Keep',
    '删除任务记录': 'Delete task record',
    '删除本地任务？': 'Delete local task?',
    '删除任务记录？': 'Delete task record?',
    '只删除任务记录和队列引用。已导入原片、渲染瓦片及导出照片都会保留。':
        'This removes the task record and queue references. Imported photos, rendered tiles, and exported images will be kept.',
    '只移除任务记录和队列项目。原片、渲染瓦片及已导出照片都会保留。':
        'This removes the task record and queue item. Source photos, rendered tiles, and exported images will be kept.',
    '选择多张 JPEG 原片': 'Select JPEG photos',
    '选择母目录': 'Choose parent folder',
    '选择一个母目录；每个直接子目录会成为独立全景任务。':
        'Choose a parent folder. Each immediate subfolder becomes a separate panorama task.',
    '添加批次': 'Add batch',
    '批处理资源设置': 'Batch resource settings',
    '批量整图格式': 'Batch output format',
    '批处理资源': 'Batch resources',
    '正在导入子目录；已加入队列的任务会继续处理。':
        'Importing subfolders. Tasks already in the queue will keep running.',
    '暂停': 'Pause',
    '继续': 'Resume',
    '重试': 'Retry',
    '查看': 'View',
    '暂停任务': 'Pause task',
    '取消任务': 'Cancel task',
    '重试或继续': 'Retry or resume',
    '打开全景查看器': 'Open panorama viewer',
    '设置行列与相机视角': 'Set grid and camera field of view',
    '资源设置': 'Resource settings',
    '适合窗口': 'Fit to window',
    '重新检查': 'Check again',
    '100%': '100%',
    '正在加载全景…': 'Loading panorama…',
    '完整 PNG 导出独立于瓦片预览，使用上方“导出完整 PNG”。':
        'Full PNG export is separate from the tile preview. Use “Export full PNG” above.',
    '金字塔中暂无瓦片': 'No tiles are available in this pyramid',
    '导出完整 PNG': 'Export full PNG',
    '导出完整 TIFF': 'Export full TIFF',
    '导出完整 JPEG XL': 'Export full JPEG XL',
    '重试完整 PNG': 'Retry full PNG',
    '重试完整 TIFF': 'Retry full TIFF',
    '重试完整 JPEG XL': 'Retry full JPEG XL',
    '导出整图': 'Export full image',
    '分享 / 保存图像': 'Share / save image',
    '在文件夹中显示图像': 'Show image in folder',
    '自动读取文件名行列': 'Read row and column from filenames',
    '按选择顺序排列': 'Arrange in selection order',
    '逐行拍摄': 'Capture row by row',
    '逐列拍摄': 'Capture column by column',
    '左上起拍': 'Start at top left',
    '右上起拍': 'Start at top right',
    '左下起拍': 'Start at bottom left',
    '右下起拍': 'Start at bottom right',
    '蛇形': 'Serpentine',
    '强制网格合成': 'Force grid placement',
    '按手动参数强制网格重试': 'Retry with manual grid placement',
    '新建副本重新合成': 'Create a copy and stitch again',
    'DWARF 固定视角（名义值）': 'DWARF nominal field of view',
    '抑制接缝重影': 'Reduce seam ghosting',
    '精细校正相邻照片位置': 'Refine neighboring photo positions',
    '并行图像匹配': 'Parallel image matching',
    '并行分块渲染': 'Parallel tile rendering',
    '启用原片纹理缓存': 'Cache source image textures',
    '缓存图像配准结果': 'Cache image alignment results',
    '快速配准': 'Fast alignment',
    'ORB 快速特征': 'ORB fast features',
    'FLANN 近似匹配': 'FLANN approximate matching',
    'GPU 加速': 'GPU acceleration',
    '当前 CPU 原生包未提供 GPU 后端。':
        'The current CPU native package does not provide a GPU backend.',
    '照片不会从网格移除；使用照片上的锁定按钮可固定其网格位置。锁定会跳过该照片的相邻纹理匹配，仅适用于顺序已确认的原片。点按照片不会更改锁定；长按可查看完整文件名。':
        'Photos stay in the grid. Use the lock button on a photo to fix its grid position. A lock skips neighbor texture matching for that photo, so use it only when the photo order is known. Tapping the photo itself does not change the lock; long-press to see the full filename.',
    '锁定网格位置': 'Lock grid position',
    '解除网格位置锁定': 'Unlock grid position',
    '旧任务锁定位置来源未知；点按可解除锁定': 'Legacy grid lock; origin unknown. Tap to unlock.',
    '修正排列方式后查看网格预览。': 'Correct the grid order to preview the layout.',
    '金字塔清单无效：': 'Invalid pyramid manifest: ',
    '读取进度失败：': 'Could not read progress: ',
    '无法读取本地任务：': 'Could not load local tasks: ',
    '导入失败：': 'Import failed: ',
    '无法加入批处理：': 'Could not add batch: ',
    '无法选择文件夹：': 'Could not choose a folder: ',
    '资源设置失败：': 'Could not save resource settings: ',
    '暂停请求失败：': 'Pause request failed: ',
    '取消请求失败：': 'Cancel request failed: ',
    '整图导出失败：': 'Full image export failed: ',
    '无法分享导出文件：': 'Could not share exported file: ',
    '已在文件管理器中打开导出文件夹。': 'Opened the export folder in the file manager.',
    '此任务没有可打开的已成功导出照片。':
        'This task has no successfully exported image to open.',
    '本期大图查看器仅在 Windows 桌面版提供。':
        'The full-size viewer is available on Windows desktop.',
    '任务记录已删除；原片、瓦片和已导出照片已保留。':
        'Task record deleted. Source photos, tiles, and exported images were kept.',
    '已完成': 'Completed',
    '排队中': 'Queued',
    '处理中': 'Stitching',
    '已暂停': 'Paused',
    '失败': 'Failed',
    '已取消': 'Cancelled',
    '正在导出': 'Exporting',
    '准备中': 'Preparing',
    '水平参考：以网格中心照片为准': 'Horizontal reference: center photo in the grid',
    '原片仅复制到本机任务目录，不上传。':
        'Photos are copied to a local task folder and are never uploaded.',
    '应用进入后台，已请求暂停；等待核心确认':
        'App moved to the background. Pause requested; waiting for the engine to confirm.',
    '排列已改变；修正网格后请重新标记异常照片。':
        'Grid order changed. Correct the grid and mark exceptional photos again.',
    '排列已改变；强制网格标记已随原片保留。':
        'Grid order changed. Forced placement markers were retained with their photos.',
    '导入照片后即可设置网格。': 'Import photos to configure the grid.',
    '已复制并校验 ': 'Copied and verified ',
    ' 张原片（': ' source photos (',
    '原片尺寸不一致；请统一尺寸后重新导入。照片均已保留。':
        'Source photo dimensions differ. Use matching dimensions and import again. All photos were kept.',
    '操作完成后已提交暂停请求': 'Operation completed. Pause request submitted.',
    '此任务由批处理队列管理，请在批处理队列中控制。':
        'This task is managed by the batch queue. Control it from the batch queue.',
    '此原生核心未报告内置 JPEG XL 编码器，已阻止启动。':
        'The native engine did not report a built-in JPEG XL encoder. Start was blocked.',
    '无法确认外接电源状态；连接充电器后再开始或恢复。':
        'Could not determine external power status. Connect a charger before starting or resuming.',
    '移动设备须接入外部电源后才能开始或恢复合成。':
        'Connect the mobile device to external power before starting or resuming a stitch.',
    '原片或参数已变化；请重新预览并重新开始。':
        'Source photos or settings changed. Preview again and restart.',
    '核心资源暂时繁忙，任务保留供稍后继续。':
        'The engine is busy. The task is saved so you can resume it later.',
    '已请求取消；等待核心确认':
        'Cancellation requested; waiting for the engine to confirm.',
    '此移动版目前仅支持已验证的 PNG 导出。':
        'This mobile build currently supports verified PNG export only.',
    '整图导出需要外接电源；连接充电器后再导出。':
        'Full image export requires external power. Connect a charger and try again.',
    '核心报告导出完成，但输出文件不存在或为空。':
        'The engine reported a completed export, but the output file is missing or empty.',
    '核心报告导出完成，但输出文件不存在或为空；保留上次成功输出。':
        'The engine reported a completed export, but the output file is missing or empty. The previous successful output was kept.',
    '任务缺少原生作业编号': 'Task is missing its native job ID',
    '应用在后台，暂停请求已提交': 'The app is in the background. Pause request submitted.',
    '外接电源已断开，暂停请求已提交':
        'External power was disconnected. Pause request submitted.',
    '未删除任务，原生停止未能确认：':
        'Task was not deleted because the native engine did not confirm it stopped: ',
    '导入照片，创建本地全景任务': 'Import photos to create a local panorama task',
    '原生合成核心已加载': 'Native stitching engine loaded',
    '原生核心不可用': 'Native engine unavailable',
    '开始合成': 'Start stitching',
    '新建合成任务': 'New stitching task',
    '查看上次成功输出': 'View last successful output',
    '上次成功整图 ': 'Last successful full image ',
    'DWARF 固定视角快捷项使用名义 fx=75000 px，尚未校准；cx/cy 根据照片尺寸计算。':
        'The DWARF nominal field of view shortcut uses fx=75000 px and is not calibrated. cx/cy are calculated from photo dimensions.',
    '已按照片 EXIF 识别 DWARFLAB / DWARF3 / TELE；使用名义 150 mm 配置 fx=':
        'Photo EXIF identifies DWARFLAB / DWARF3 / TELE. Using the nominal 150 mm profile with fx=',
    '尚未校准。实际 EXIF 焦距：': 'Not calibrated. EXIF focal length: ',
    '结果是网格估算值，尚未校准，仍需目视检查接缝。':
        'Grid positions are estimates and are not calibrated. Visually inspect the seams.',
    '最多检查 24 组中心相邻照片；结果是网格估算值，尚未校准，仍需目视检查接缝。':
        'Checks up to 24 neighboring photo pairs around the center; grid positions are estimates and are not calibrated. Visually inspect the seams.',
    '最多检查 24 组中心相邻照片；':
        'Checks up to 24 neighboring photo pairs around the center; ',
    '重叠率由照片实测；未知镜头的视角仍需填写。当前视角用于球面投影，默认 45° 不是照片测量值。最多检查 24 组中心相邻照片，结果仍需目视检查接缝。':
        'Overlap is measured from the photos. Enter the field of view for unknown lenses. The current field of view is used for spherical projection; the default 45° is not measured from the photos. Up to 24 neighboring photo pairs around the center are checked, and the result still requires visual seam inspection.',
    '重叠率由照片实测；未知镜头的视角仍需填写。':
        'Overlap is measured from the photos. Enter the field of view for unknown lenses.',
    '渲染内存预算用于缓存和活动图像/瓦片估算；配准阶段 OpenCV 与进程其他内存另计。':
        'The render memory budget estimates cache and active image/tile memory. OpenCV alignment and other process memory are accounted separately.',
    '在相邻重叠区域限制局部变形，减少纹理错位':
        'Limits local deformation in neighboring overlaps to reduce texture misalignment.',
    '选项会随任务保存；正在处理或等待恢复的任务使用已提交参数。最终整图仍使用全部原片和完整分辨率。':
        'Options are saved with each task. Running or resumable tasks use their submitted settings. Final output uses all source photos at full resolution.',
    '中心照片提供水平/垂直估算；启用精细校正后，此项用于八个方向相邻照片配准。':
        'Center photos provide horizontal and vertical estimates. With neighbor refinement enabled, this option applies to the eight neighboring directions.',
    '自动网格只估算中心相邻照片；启用精细校正后可并行配准八个方向的相邻照片。':
        'Automatic grid mode estimates overlap from center neighbors only. Neighbor refinement can align pairs in all eight directions in parallel.',
    '自动网格使用固定的中心相邻照片估算；此项在自动模式下暂停使用。':
        'Automatic grid mode uses fixed center-neighbor estimates. This option is paused in automatic mode.',
    '精细校正会固定检查四个方向的相邻照片；关闭精细校正后可恢复此项设置。':
        'Neighbor refinement always checks all four directions. Turn it off to restore this setting.',
    '中心重叠估算固定使用 SIFT/BF；此项用于启用中的八方向相邻照片配准。':
        'Center overlap estimation always uses SIFT/BF. This option applies to enabled eight-direction alignment.',
    '自动网格估算固定使用 SIFT/BF；启用精细校正后可测试八方向相邻照片配准。':
        'Automatic grid estimation always uses SIFT/BF. Enable neighbor refinement to experiment with eight-direction alignment.',
    'ORB 使用 BF 匹配；FLANN 已关闭。': 'ORB uses BF matching; FLANN is disabled.',
    '默认使用 SIFT 特征。': 'SIFT features are used by default.',
    'ORB 模式不可用；请先切回 SIFT。':
        'ORB mode is unavailable. Switch back to SIFT first.',
    '默认使用 BF 精确匹配。': 'BF exact matching is used by default.',
    '照片与网格映射': 'Photo-to-grid mapping',
    '全部 ': 'All ',
    ' 张照片保留；尺寸 ': ' photos kept; dimensions ',
    '原片尺寸不一致，核心无法共用相机内参。':
        'Source photo dimensions differ, so the engine cannot share camera intrinsics.',
    '找不到已完成任务的导出照片。': 'No exported image was found for the completed task.',
    '输出文件已变化，关联分块预览已停用。请重新合成以生成匹配的预览。':
        'The output file changed, so its linked tile preview is disabled. Stitch again to create a matching preview.',
    '旧任务没有导出指纹；核心记录确认此路径属于任务，但无法确认文件后来是否被外部修改。预览来自任务金字塔。':
        'This older task has no export fingerprint. The engine associates this path with the task, but later external changes cannot be verified. Preview is from the task pyramid.',
    '旧任务没有导出指纹，且核心未核验导出记录。预览来自保存任务的金字塔，可能与当前文件内容不同。':
        'This older task has no export fingerprint and the engine did not verify the export record. Preview is from the saved task pyramid and may differ from the current file.',
    '输出大小和修改时间与导出时记录一致（未做内容哈希）。预览来源：本任务的 PNG 分块金字塔（同一渲染像素）。':
        'Output size and modification time match the export record (content hash not checked). Preview source: this task’s PNG tile pyramid (same rendered pixels).',
    '此任务没有可用的分块预览清单。': 'This task has no tile preview manifest.',
    '预览清单路径超出任务目录，已拒绝读取。':
        'Preview manifest path is outside the task directory. Reading was denied.',
    '预览清单过大，已拒绝读取。': 'Preview manifest is too large. Reading was denied.',
    '导出文件的大小或修改时间已变化': 'Exported file size or modification time has changed',
    '无法确认导出文件与此任务的关联，已停止打开预览。':
        'Could not verify that the exported file belongs to this task. Preview was stopped.',
    '预览清单格式无效或尚未完成。': 'Preview manifest is invalid or incomplete.',
    '预览尺寸超出支持范围。': 'Preview dimensions exceed the supported range.',
    '预览瓦片尺寸不受支持。': 'Preview tile dimensions are not supported.',
    '预览层级清单无效。': 'Preview level manifest is invalid.',
    '预览层级格式无效。': 'Preview level format is invalid.',
    '预览层级重复。': 'Duplicate preview level.',
    '预览瓦片列表无效。': 'Preview tile list is invalid.',
    '预览瓦片数量过多，已拒绝读取。': 'Too many preview tiles. Reading was denied.',
    '预览瓦片信息无效。': 'Preview tile information is invalid.',
    '预览瓦片路径或坐标无效。': 'Preview tile path or coordinates are invalid.',
    '预览最高分辨率与清单尺寸不一致。':
        'Preview maximum resolution does not match the manifest dimensions.',
    '预览层级尺寸顺序无效。': 'Preview levels have invalid dimensions or order.',
    '预览尺寸必须是正整数。': 'Preview dimensions must be positive integers.',
    '预览层级或坐标必须是非负整数。':
        'Preview levels and coordinates must be non-negative integers.',
    '输出格式：': 'Output format: ',
    '输出文件：': 'Output file: ',
    '缩放 ': 'Zoom ',
    '未知格式（': 'Unknown format (',
    '导出文件不存在：': 'Exported file does not exist: ',
    '无法安全读取任务预览：': 'Could not safely read task preview: ',
    '估算排列，建议检查': 'Estimated layout; review recommended',
    '等待资源': 'Waiting for resources',
    '需要处理设置': 'Needs setup',
    '已跳过': 'Skipped',
    '等待开始': 'Ready to start',
    '合成中': 'Stitching',
    '导出整图 PNG': 'Exporting full PNG',
    '需要处理': 'Needs setup',
    '整图已导出': 'Full image exported',
    '正在暂停 · ': 'Pausing · ',
    ' 秒': ' sec',
    ' 分 ': ' min ',
    '选择包含多个全景子目录的母目录': 'Choose a parent folder containing panorama subfolders',
    '没有删除队列项目：': 'Could not remove queue item: ',
    '位于任务目录之外的路径已拒绝读取。': 'Reading paths outside the task directory is denied.',
    '全部': 'All',
    '行': 'Rows',
    '列': 'Columns',
    '焦距（像素）': 'Focal length (px)',
    '水平视角（度）': 'Horizontal field of view (degrees)',
    '水平重叠率（%）': 'Horizontal overlap (%)',
    '垂直重叠率（%）': 'Vertical overlap (%)',
    '输出格式': 'Output format',
    '文件名': 'Filename',
    '已估算': 'Estimated',
    '估算': 'Estimated',
    '设置 ': 'Settings ',
    '已导入': 'Imported',
    '正在暂停': 'Pausing',
    '等待手动恢复': 'Waiting for manual resume',
    '导出中': 'Exporting',
    '处理失败': 'Failed',
    '图像配准': 'Image alignment',
    '生成全分辨率瓦片': 'Render full-resolution tiles',
    '生成缩放金字塔': 'Build the zoom pyramid',
    '写入预览清单': 'Write preview manifest',
    '合成完成，自动导出整图': 'Stitching completed; automatic full image export',
    '导出完整图像': 'Export full image',
    '整图导出失败，可重试': 'Full image export failed; retry available',
    '完成': 'Completed',
    '配准': 'Alignment',
    '分块渲染': 'Tile rendering',
    '缩放金字塔': 'Zoom pyramid',
    '总耗时': 'Total time',
    '输入校验': 'Input validation',
    '原片解码': 'Source image decoding',
    '瓦片写入': 'Tile writing',
    'TIFF 类型：': 'TIFF variant: ',
    'PNG（无损）': 'PNG (lossless)',
    'TIFF（无损，大图自动 BigTIFF）': 'TIFF (lossless; BigTIFF for large images)',
    'JPEG XL（有损）': 'JPEG XL (lossy)',
    '实际渲染工作线程：': 'Actual render worker threads: ',
    '原片纹理缓存命中：': 'Source texture cache hits: ',
    '配准缓存：命中（沿用已保存的配准结果）': 'Alignment cache: hit (reusing saved alignment)',
    '配准缓存：未命中': 'Alignment cache: miss',
    '配准质量状态：': 'Alignment quality status: ',
    '样本配对：': 'Sample pairs: ',
    '网格为估算值，尚未校准；': 'Grid positions are estimated and not calibrated; ',
    '优先尝试四邻方向（自适应）': 'Try four neighbor directions first (adaptive)',
    'Technical details': 'Technical details',
    '行数': 'Rows',
    '列数': 'Columns',
    '总 CPU 工作线程': 'Total CPU worker threads',
    '总内存预算（MiB）': 'Total memory budget (MiB)',
    '并发任务数（最多 8）': 'Concurrent tasks (max 8)',
    'JPEG XL（需随程序加载 libjxl）': 'JPEG XL (requires libjxl bundled with the app)',
    '导出文件': 'Exported file',
    '整图格式：': 'Full image format: ',
    '组相邻照片配对': ' neighboring photo pairs',
    '估算值，尚未校准；': 'is an estimate and is not calibrated; ',
    '默认输出格式': 'Default output format',
    '完成后自动导出格式': 'Format for automatic export after stitching',
    '完成后自动导出：PNG': 'Automatic export after stitching: PNG',
    '完成后自动导出：TIFF': 'Automatic export after stitching: TIFF',
    '完成后自动导出：JPEG XL': 'Automatic export after stitching: JPEG XL',
    '单任务合成完成后自动导出全分辨率整图。':
        'Automatically export the full-resolution image when a single task completes.',
    '水平视角 °': 'Horizontal field of view °',
    '焦距像素（可选）': 'Focal length in pixels (optional)',
    '渲染内存 MiB': 'Render memory MiB',
    '工作线程数': 'Worker threads',
    '手动水平重叠率 %': 'Manual horizontal overlap %',
    '手动垂直重叠率 %': 'Manual vertical overlap %',
    '15–80；自动模式忽略此值，实测结果见报告':
        '15–80; ignored in automatic mode. See measured values in the report.',
    '自动重叠关闭时，无法可靠匹配的方向才会按焦距/视角和手动重叠率估算网格位置。':
        'When automatic overlap is off, unmatched directions use focal length or field of view and manual overlap to estimate grid positions.',
    '从中间照片估算水平/垂直重叠并按网格合成':
        'Estimate horizontal and vertical overlap from center photos, then stitch the grid',
    '结合八个方向相邻照片的可靠匹配校正位置；匹配不可靠时会降低其影响，可能需要更长时间。':
        'Refines placement from reliable matches in all eight neighboring directions; unreliable matches have less influence. This may take longer.',
    '重叠区域优先采用更清晰的照片来源以减少重影；没有更清晰的邻图时仍会保留原片。关闭可与传统羽化结果对照。':
        'Prefers sharper photo sources in overlaps to reduce ghosting; original coverage is kept when no sharper neighbor exists. Turn off to compare feather blending.',
    '缓存保存在任务输入目录旁的应用任务目录中。':
        'The cache is stored in the app task folder beside the task input directory.',
    '使用 0.6 MP 配准图；关闭时使用 2.0 MP。最终渲染仍为全分辨率。':
        'Align using 0.6 MP images; when off, use 2.0 MP. Final rendering remains full resolution.',
    '保存提速测试选项失败：': 'Could not save performance options: ',
    '行列数必须是正整数': 'Rows and columns must be positive integers.',
    '网格行列乘积超出支持范围': 'The grid dimensions exceed the supported integer range.',
    '网格行列乘积超出整数支持范围': 'The grid dimensions exceed the supported integer range.',
    '文件名行列范围超出整数支持范围':
        'The filename grid dimensions exceed the supported integer range.',
    'Android 无法启动后台运行保护；未开始导出。':
        'Android could not start background protection; export was not started.',
    '无法启动后台运行保护；任务已请求安全暂停。':
        'Background protection could not start; a safe pause was requested.',
    '行列必须是有效整数。': 'Rows and columns must be valid integers.',
    '水平视角需介于 1° 与 179°。':
        'Horizontal field of view must be between 1° and 179°.',
    '渲染内存预算需为 128–131072 MiB。': 'Render memory budget must be 128–131072 MiB.',
    '配准并行数需为 1–32。': 'Alignment worker count must be 1–32.',
    '水平与垂直重叠率需分别为 15%–80%。':
        'Horizontal and vertical overlap must each be 15%–80%.',
    '焦距像素值必须大于零。': 'Focal length in pixels must be greater than zero.',
    '无法映射': 'Cannot map',
    '布局': 'layout',
    'tile source information': 'Tile source information',
    '文件名需为 row_column.jpg；可切换到顺序模式':
        'Filenames must use row_column.jpg; switch to sequence mode.',
    // Prefix keys (colon-terminated; the remainder is appended verbatim).
    '无法启动：': 'Could not start: ',
    '无法启用前台任务锁：': 'Could not enable the foreground task lock: ',
    '前台任务锁不可用，正在请求暂停：': 'Foreground task lock unavailable; requesting pause: ',
    '无法创建新任务副本：': 'Could not create a task copy: ',
    '恢复任务状态失败：': 'Failed to restore task state: ',
    '无法读取移动端后台暂停记录；启动、恢复与导出已暂缓：':
        'Could not read mobile background pause records; start, resume and export are deferred: ',
    '移动端后台暂停任务仍待安全核对：':
        'A mobile background-paused task still needs a safety check: ',
    '无法读取移动端后台暂停记录；批处理任务保持待核对：':
        'Could not read mobile background pause records; the batch task stays pending verification: ',
    '无法重新读取母目录：': 'Could not re-read the parent directory: ',
    '无法读取子目录：': 'Could not read the subdirectory: ',
    '仅支持 JPEG 原片：': 'Only original JPEG photos are supported: ',
    '无法读取所选文件：': 'Could not read the selected file: ',
    '文件不是有效 JPEG：': 'The file is not a valid JPEG: ',
    'JPEG marker 顺序无效：': 'Invalid JPEG marker order: ',
    'JPEG 头中找不到图像尺寸：': 'No image size found in the JPEG header: ',
    '本地合成核心不可用：': 'The local stitching core is unavailable: ',
    '调用原生合成核心失败：': 'Failed to call the native stitching core: ',
    '启动失败：': 'Failed to start: ',
    '取消失败：': 'Failed to cancel: ',
    '无法读取核心资源：': 'Could not read core resources: ',
    '读取批处理队列失败：': 'Failed to read the batch queue: ',
    '导入批次失败：': 'Failed to import the batch: ',
    '原生任务已创建，正在重新连接：': 'The native job was created; reconnecting: ',
    '状态暂时不可用，保留原任务并重试：':
        'State temporarily unavailable; keeping the original task and retrying: ',
    '恢复状态暂不可用，将自动重试：':
        'Recovery state temporarily unavailable; retrying automatically: ',
    '等待原生导出状态：': 'Waiting for the native export state: ',
    '设备全景导入失败：': 'Device panorama import failed: ',
    '等待连接原生任务：': 'Waiting to connect to the native job: ',
    // Static service/UI keys found by the bilingual audit.
    'Android 后台运行时限已到；等待手动恢复导出':
        'The Android background run limit was reached; export waits for a manual resume',
    'Android 无法启动后台运行保护，任务已安全暂停':
        'Android could not start background protection; the task is safely paused',
    'Android 无法启动后台运行保护，正在核对暂停状态':
        'Android could not start background protection; checking the pause state',
    'JPEG XL（编码器未加载）': 'JPEG XL (encoder not loaded)',
    '任务仍在处理中；停止后才能删除队列项目':
        'The task is still processing; stop it before removing the queue item',
    '任务渲染目录已有内容，拒绝覆盖':
        'The task render directory already has content; refusing to overwrite',
    '任务缺少原生作业编号；无法确认已停止':
        'The task is missing its native job ID; stop could not be confirmed',
    '任务记录丢失': 'Task record is missing',
    '任务输入目录已存在，拒绝覆盖':
        'The task input directory already exists; refusing to overwrite',
    '任务输入目录已存在；请新建任务后再导入，避免覆盖原片':
        'The task input directory already exists; create a new task before importing to avoid overwriting the original photos',
    '全景目录没有可导入的 JPEG 原片':
        'The panorama directory has no importable JPEG source photos',
    '共享资源预算已变化，等待释放后再导出整图':
        'The shared resource budget changed; waiting for it to be released before exporting the full image',
    '删除本地任务记录': 'Delete local task record',
    '原片内容已变化；请重新导入以创建新任务':
        'The source photo content changed; re-import to create a new task',
    '原片尺寸不一致': 'The source photos have inconsistent dimensions',
    '原生任务状态路径与渲染目录不匹配':
        'The native job state path does not match the render directory',
    '原生任务的导出状态缺失': 'The native job export state is missing',
    '原生合成核心不可用': 'The native stitching engine is unavailable',
    '原生响应不是 JSON 对象': 'The native response is not a JSON object',
    '原生核心返回空响应': 'The native engine returned an empty response',
    '只移除任务记录和队列项目。原片、渲染瓦片及已导出照片都会保留。处理中任务会先请求停止。':
        'Only the task record and queue item are removed. The original photos, rendered tiles and exported images are all kept. Running tasks are stopped first.',
    '合成失败': 'Stitching failed',
    '合成完成，等待整图导出': 'Composition complete; waiting for the full image export',
    '合成已完成': 'Composition completed',
    '合成已开始': 'Stitching started',
    '后台时间到；整图导出已暂停，点击恢复继续':
        'Background time limit reached; the full image export is paused. Tap Resume to continue',
    '后台运行已暂停；等待手动恢复导出':
        'Background run paused; waiting for a manual export resume',
    '大型任务尚未安全暂停，确认后不能继续':
        'The large job is not safely paused yet; it cannot continue after confirmation',
    '大型任务需要确认后才会导出': 'The large job needs confirmation before exporting',
    '大型任务需要重新确认后才能导出':
        'The large job needs to be re-confirmed before exporting',
    '子目录中没有直接 JPEG 原片': 'No direct JPEG source photos in the subdirectory',
    '已恢复原生任务': 'Restored the native job',
    '已提交暂停请求': 'Pause request submitted',
    '已有处理目录；请创建新任务，避免覆盖或误恢复旧参数':
        'A processing directory already exists; create a new task to avoid overwriting or accidentally restoring old settings',
    '已请求暂停，等待核心确认': 'Pause requested; waiting for the engine to confirm',
    '已请求暂停；等待核心确认': 'Pause requested; waiting for the engine to confirm',
    '已连接正在运行的原生任务': 'Connected to the running native job',
    '应用未运行期间的原生状态不会自动恢复':
        'Native state from while the app was closed is not restored automatically',
    '恢复': 'Resume',
    '恢复整图导出': 'Resume full image export',
    '找不到原始子目录': 'The original subdirectory was not found',
    '找不到原始子目录，无法重新导入':
        'The original subdirectory was not found; cannot re-import',
    '找不到本地任务记录': 'No local task record found',
    '找不到该队列任务': 'The queue task was not found',
    '整图导出失败': 'Full image export failed',
    '整图导出失败。': 'Full image export failed.',
    '整图导出已完成': 'Full image export completed',
    '整图导出已开始': 'Full image export started',
    '整图导出已暂停，点击恢复继续': 'The full image export is paused. Tap Resume to continue',
    '文件名行列编号超出支持范围': 'Filename row/column numbers exceed the supported range',
    '无法分配不冲突的整图文件名': 'Could not assign a non-conflicting full image filename',
    '无法启动 Android 后台运行保护；导出保持暂停':
        'Could not start Android background protection; the export stays paused',
    '无法启动 Android 后台运行保护；正在核对暂停状态':
        'Could not start Android background protection; checking the pause state',
    '本地处理失败': 'Local processing failed',
    '核心报告导出完成，但找不到整图文件':
        'The engine reported a completed export, but the full image file is missing',
    '核心报告导出完成，但找不到非空整图文件':
        'The engine reported a completed export, but no non-empty full image file was found',
    '核心报告导出完成，但输出文件不存在或为空':
        'The engine reported a completed export, but the output file is missing or empty',
    '核心未报告可用的 JPEG XL 无损编码器；已阻止启动。':
        'The engine did not report an available lossless JPEG XL encoder; startup was blocked.',
    '核心未报告可用的 JPEG XL 编码器':
        'The engine did not report an available JPEG XL encoder',
    '检测到重复行列文件；请改用顺序模式，全部原片都会保留':
        'Duplicate row/column files detected; use sequence mode. All source photos are kept.',
    '此原生核心未报告内置 JPEG XL 编码器，已阻止导出。':
        'This native engine did not report a built-in JPEG XL encoder; export was blocked.',
    '此队列项目不需要大型任务确认': 'This queue item does not need a large-job confirmation',
    '母目录不存在': 'The parent directory does not exist',
    '母目录中没有直接子目录': 'No direct subdirectory in the parent directory',
    '水平视角需介于 1° 与 179°': 'Horizontal field of view must be between 1° and 179°',
    '没有原片': 'No source photos',
    '没有选中照片': 'No photos selected',
    '等待共享内存预算释放后再导出整图':
        'Waiting for the shared memory budget to be released before exporting the full image',
    '等待核心资源': 'Waiting for engine resources',
    '等待核心资源以恢复原任务': 'Waiting for engine resources to restore the original task',
    '等待核心资源后自动导出': 'Waiting for engine resources, then exporting automatically',
    '继续完成暂停请求': 'Continue the pause request',
    '继续导出整图': 'Continue the full image export',
    '缺少已导入原片': 'Imported source photos are missing',
    '行列数必须与原片数量一致': 'Rows and columns must match the number of source photos',
    '请先导入原片': 'Import the source photos first',
    '队列正在恢复或导入，请稍后再删除':
        'The queue is recovering or importing; try removing it again later',
    '队列正在恢复或导入，请稍后再删除任务':
        'The queue is recovering or importing; try removing the task again later',
    '需要设置相机视角': 'Set the camera field of view first',
    '需要设置行列': 'Set the rows and columns first',
    '估算布局': 'Estimated layout',
    '图像': 'image',
    // Export viewer trace/source-inspection keys (bilingual audit plan B).
    '点击输出像素查看几何覆盖。': 'Tap an output pixel to inspect geometric coverage.',
    '此射线没有覆盖相机。': 'No camera geometrically covers this ray.',
    '渲染器最终选择与曝光/颜色增益未提供。':
        'Renderer ownership and exposure/color gains are not available.',
    '无法安全验证布局来源，像素追踪已停用。':
        'Could not verify the layout source; pixel tracing is disabled.',
    '任务记录未验证当前输出与布局清单的关联。':
        'The task record does not verify the output-to-layout association.',
    '此格式没有可验证的导出回执，来源追踪已停用。':
        'No verified export receipt is available for this format; source tracing is disabled.',
    '实际输出尺寸与分块预览清单不一致，来源追踪已停用。':
        'The output dimensions do not match the preview manifest; source tracing is disabled.',
    '实际输出尺寸与任务记录不一致，来源追踪已停用。':
        'The output dimensions do not match the task record; source tracing is disabled.',
    '输出尺寸与任务清单不一致，来源追踪已停用。':
        'The output dimensions do not match the task manifest; source tracing is disabled.',
    '任务布局或清单校验失败，来源追踪已停用。':
        'Task layout or manifest integrity verification failed; source tracing is disabled.',
    '任务记录与当前预览清单不是同一文件。':
        'The task record and current preview do not use the same manifest file.',
    '布局文件路径超出任务目录，已拒绝读取。':
        'The layout path is outside the task directory and was rejected.',
    '布局记录超过安全读取上限。': 'The layout record exceeds the safe read limit.',
    '布局投影或输出尺寸与实际文件不一致。':
        'The layout projection or dimensions do not match the output file.',
    '输出坐标或布局无效。': 'The output coordinate or layout is invalid.',
    '布局缺少相机信息。': 'The layout has no camera tiles.',
    '布局投影范围无效。': 'The layout projection bounds are invalid.',
    '任务网格映射无效。': 'The task grid mapping is invalid.',
    '几何追踪数据无效，已停止检查。': 'The geometry trace is invalid and inspection stopped.',
    '视觉测量': 'visually measured',
    '网格估算': 'grid estimated',
    '位置来源未知': 'position source unknown',
    '网格硬锁': 'hard grid lock',
    '网格先验': 'grid prior',
    '无放置约束': 'no placement constraint',
    '约束未知': 'constraint unknown',
    '操作员': 'operator',
    '系统回退': 'system fallback',
    '旧记录来源未知': 'legacy origin unknown',
    '来源未知': 'origin unknown',
    '已接受': 'accepted',
    '网格硬锁边，未参与视觉匹配': 'hard-locked grid edge; visual matching skipped',
    '描述子缺失或无效': 'descriptor missing or invalid',
    '比率检验匹配不足': 'too few ratio-test matches',
    'RANSAC 失败': 'RANSAC failed',
    '内点不足': 'too few inliers',
    '内点比例过低': 'low inlier ratio',
    '等待射线拟合': 'ray fit pending',
    '弱支持回环冲突': 'weak-support loop conflict',
    '射线拟合退化': 'degenerate ray fit',
    '射线残差超过 12 px 门限': 'ray residual exceeds 12 px gate',
    '联合像素留一冲突': 'joint pixel leave-one-out conflict',
    '支持不足': 'weak support',
    '状态未知': 'unknown status',
    '关闭来源检查': 'Stop source inspection',
    '检查像素来源': 'Inspect pixel source',
    '模型随 Windows 和 macOS 程序附带，可离线使用。':
        'The model is included with the Windows and macOS apps and works offline.',
  };

  static const _zh = <String, String>{
    'Bundled scene model is missing.': '程序附带的场景模型文件缺失。',
    'Scene model SHA-256 verification failed.': '场景模型 SHA-256 校验失败。',
    'Scene model manifest is invalid.': '场景模型清单无效。',
    'Scene model manifest has an invalid bundled model path.':
        '场景模型清单中的程序包路径无效。',
    'Scene model is unavailable: its verified SHA-256 is not configured.':
        '场景模型不可用：尚未配置已验证的 SHA-256。',
    'Scene model is unavailable: its verified file size is not configured.':
        '场景模型不可用：尚未配置已验证的文件大小。',
    'Cannot remove the scene model while a task is active.': '任务运行期间不能清除场景模型。',
    'Cannot remove the scene model during preparation.': '正在准备场景模型时不能清除。',
    'semantic-analysis': '场景语义分析',
    '正在准备场景模型：': '正在准备场景模型：',
    'people protection and water smoothing are supported only on Windows':
        '人物保护和水面平滑仅支持 Windows。',
    'ONNX Runtime is missing beside the application': '应用目录旁缺少 ONNX Runtime。',
    'scene model SHA-256 mismatch': '场景模型 SHA-256 校验不匹配。',
    'scene mask cache identity mismatch': '场景掩码缓存身份不匹配。',
    'scene mask cache hash mismatch': '场景掩码缓存哈希不匹配。',
    'scene ONNX input must be float32 [1,3,512,512]':
        '场景 ONNX 输入必须为 float32 [1,3,512,512]。',
    'scene ONNX output must be float32 [1,2,512,512] person/water probabilities':
        '场景 ONNX 输出必须为 float32 [1,2,512,512] 人物/水面概率。',
    'Open stitch task': '打开合成任务',
    'Import from DWARF3': '从 DWARF3 导入',
    'DWARF3 panoramas': 'DWARF3 设备全景',
    'Device address': '设备地址',
    'Connect to device': '连接设备',
    'Refresh panoramas': '刷新全景',
    'Open Wi-Fi settings': '打开 Wi-Fi 设置',
    'Wi-Fi settings opened. Join DWARF3, then return here.':
        'Wi-Fi 设置已打开。请连接 DWARF3，然后返回此页面。',
    'Open Settings > Wi-Fi, join DWARF3, then return here.':
        '请打开“设置 > Wi-Fi”，连接 DWARF3 后返回此页面。',
    'Select panoramas to download': '选择要下载的全景',
    'Download selected panoramas': '下载所选全景',
    'Add downloaded panoramas to stitch queue': '将已下载全景加入合成队列',
    'No panoramas are available on the device': '设备上没有可用的全景',
    'Connect to DWARF3 Wi-Fi, then enter the device address.':
        '请连接 DWARF3 Wi-Fi 后输入设备地址。',
    'Default address: 192.168.88.1': '默认地址：192.168.88.1',
    'Download paused': '下载已暂停',
    'Downloads paused when the app entered the background. Resume while the app is open.':
        '应用进入后台后已暂停下载。请在应用保持打开时继续下载。',
    'Keep this page open and connect power. The screen stays awake while downloading; background downloads pause safely.':
        '请保持此页面打开并连接电源。下载时屏幕会保持常亮；应用进入后台后会安全暂停下载。',
    'Stitching progress': '合成进度',
    'The imported panorama task is not available yet. It remains in the task list; try opening it again.':
        '导入的全景任务暂不可用。任务仍保留在列表中，请稍后重试打开。',
    'Stitching': '合成中',
    'Exporting': '导出中',
    'Keep the app open and connect power while stitching. Background work may pause; reopen the app to continue.':
        '合成期间请保持应用打开并连接电源。进入后台后任务可能暂停；返回应用即可继续。',
    'Download failed': '下载失败',
    'Pause download': '暂停下载',
    'Resume download': '继续下载',
    'Retry failed downloads': '重试失败下载',
    'Download complete': '下载完成',
    'Device connection failed:': '设备连接失败：',
    'DWARF operation failed:': 'DWARF 操作失败：',
    '无法读取移动端后台暂停记录；请重试后再启动或恢复。': '无法读取移动端后台暂停记录；请重试后再启动或恢复。',
    '移动端应用进入后台；原生任务仍在停止，等待确认安全暂停。': '应用已进入后台；原生任务仍在停止，等待确认安全暂停。',
    '移动端应用进入后台；保留此前成功的导出结果。': '应用已进入后台；此前成功的整图导出仍会保留。',
    '移动端应用进入后台；任务已安全暂停。': '应用已进入后台；任务已安全暂停。',
    '移动端应用进入后台；已记录原生任务的终止状态。': '应用已进入后台；已记录原生任务的终止状态。',
    '无法启动移动端后台运行保护；核心任务尚未启动': '无法启用移动端后台任务管理；合成任务尚未启动。',
    '移动端无法启动后台任务管理，任务已安全暂停': '移动端后台任务管理未能启动；任务已安全暂停。',
    '移动端无法确认后台安全暂停，正在核对原生任务状态': '无法确认后台安全暂停；正在核对原生任务状态。',
    '移动端无法启动后台任务管理；未开始导出。': '移动端后台任务管理未能启动；尚未开始导出。',
    '移动端无法确认安全暂停；正在核对原生任务状态。': '无法确认安全暂停；正在核对原生任务状态。',
    '移动端无法确认安全暂停，正在核对原生任务状态。': '无法确认安全暂停；正在核对原生任务状态。',
    'Original photos': '原片数量',
    'Size unknown': '大小未知',
    'Recoverable device downloads found': '发现可恢复的设备下载',
    'Downloading': '正在下载',
    'Dismiss': '关闭',
    'DWARF transfers': 'DWARF 传输',
    'Waiting to download': '等待下载',
    '设置': '设置',
    '语言': '语言',
    '外观': '外观',
    '强调色': '强调色',
    '输出画质': '输出画质',
    '合成详情': '合成详情',
    '合成日志': '合成日志',
    '总用时未知（旧任务没有时间记录）': '总用时未知（旧任务没有时间记录）',
    '未知': '未知',
    '进行中': '进行中',
    'validate': '输入校验',
    'source-validation': '原片校验',
    'validation-complete': '校验完成',
    'register': '照片配准',
    'render-level-0': '全分辨率渲染',
    'pyramid': '预览金字塔',
    'commit-render': '保存渲染检查点',
    'commit-export': '保存导出检查点',
    'spool-jxl': '准备 JPEG XL 输出',
    'encode-jxl': '编码 JPEG XL',
    'export': '整图导出',
    'optimize-grid-poses': '优化网格配准',
    'refine-pixel-texture': '校正像素纹理',
    'fit-local-texture-warp': '拟合局部纹理校正',
    'grid-overlap-feature-extraction': '提取网格重叠特征',
    'grid-overlap-pair-matching': '匹配网格重叠区域',
    'grid-overlap-complete': '网格重叠分析完成',
    'initial-matching-complete': '初始匹配完成',
    'matching-edge-batch': '匹配相邻照片',
    'adaptive-diagonal-matching': '检查对角相邻照片',
    'retry-neighbor-matching': '重试相邻照片匹配',
    'precision-recovery-start': '提高配准精度后重试',
    'registration-complete': '配准完成',
    'registration-failed': '配准失败',
    'feature-extraction-batch': '提取图像特征',
    'feature-extraction-complete': '特征提取完成',
    'publish-export': '复制整图到选定文件夹',
    'publishing': '正在发布整图',
    'published': '整图已发布',
    'publish-failed': '整图发布失败',
    'prune-conflicting-neighbors': '移除冲突的相邻匹配',
    'done': '完成',
    'paused': '已暂停',
    'cancelled': '已取消',
    '重试复制到输出文件夹': '重试复制到输出文件夹',
    '复制到输出文件夹失败：': '复制到输出文件夹失败：',
    '重试发布整图': '重试发布整图',
    '输出格式': '输出格式',
    '接缝融合': '接缝融合',
    '性能默认值': '性能默认值',
    '并行图像匹配': '并行图像匹配',
    '并行分块渲染': '并行分块渲染',
    '启用原片纹理缓存': '启用原片纹理缓存',
    '缓存图像配准结果': '缓存图像配准结果',
    '快速配准': '快速配准',
    '输出文件夹': '输出文件夹',
    '使用默认文件夹': '使用默认文件夹',
    '优先尝试四邻方向（自适应）': '优先尝试四邻方向（自适应）',
    'ORB 快速特征': 'ORB 快速特征',
    'FLANN 近似匹配': 'FLANN 近似匹配',
    '选择文件夹': '选择文件夹',
    '系统': '跟随系统',
    '中文': '中文',
    '英文': 'English',
    '浅色': '浅色',
    '深色': '深色',
    '青绿': '青绿',
    '蓝色': '蓝色',
    '紫色': '紫色',
    '橙色': '橙色',
    '羽化': '羽化',
    '去重影': '去重影',
    '设置保存失败：': '设置保存失败：',
    'Lumia Stitch': 'DWARF Stitch',
    '本地任务': '本地任务',
    '任务记录': '任务记录',
    '导入原片': '导入照片',
    '合成信息 / 日志': '合成信息 / 日志',
    '先新建副本，再修改设置': '先新建副本，再修改设置',
    '整图输出独立于瓦片预览，使用任务选择的输出格式。': '整图输出独立于瓦片预览，使用任务选择的输出格式。',
    '整图输出': '整图输出',
    '完成后自动导出格式': '完成后自动导出格式',
    'PNG（无损）': 'PNG（无损）',
    'TIFF（无损，大图自动 BigTIFF）': 'TIFF（无损，大图自动 BigTIFF）',
    'JPEG XL（有损）': 'JPEG XL（有损）',
    '批处理队列': '批处理队列',
    '批处理仅限 Windows 桌面版': '批处理仅限 Windows 桌面版',
    '局部纹理校正': '局部纹理校正',
    '批准并开始': '批准并开始',
    '确认后开始': '确认后开始',
    '确认大型任务': '确认大型任务',
    '等待大型任务确认': '等待大型任务确认',
    '确认大型合成任务': '确认大型合成任务',
    '无法设置 Android 渲染资源预算，已暂缓启动。': '无法设置 Android 渲染资源预算，已暂缓启动。',
    '无法设置 iOS 渲染资源预算，已暂缓启动。': '无法设置 iOS 渲染资源预算，已暂缓启动。',
    '无法保存 iOS 后台暂停记录；请重试后再启动或恢复。': '无法保存 iOS 后台暂停记录；请重试后再启动或恢复。',
    '无法启动 iOS 后台任务管理；核心任务尚未启动': '无法启动 iOS 后台任务管理；核心任务尚未启动',
    '设备温度较高，待温度降低后再启动新任务。': '设备温度较高，待温度降低后再启动新任务。',
    '已按设备当前资源限制并发参数。': '已按设备当前资源限制并发参数。',
    '大型任务需要重新确认': '大型任务需要重新确认',
    '正在安全暂停大型任务；确认后才能继续': '正在安全暂停大型任务；确认后才能继续',
    '大型任务需要确认后才会开始': '大型任务需要确认后才会开始',
    '无法启动后台运行保护；任务已请求暂停': '无法启动后台运行保护；任务已请求暂停',
    'Android 无法启动后台运行保护，任务已请求暂停': 'Android 无法启动后台运行保护，任务已请求暂停',
    'Android 无法启动后台运行保护，任务已暂停': 'Android 无法启动后台运行保护，任务已暂停',
    '无法启动后台运行保护；整图导出未开始。': '无法启动后台运行保护；整图导出未开始。',
    'Android 后台运行时限已到，任务已请求安全暂停': 'Android 后台运行时限已到，任务已请求安全暂停',
    'Android 后台运行时限已到；核心状态已确认': 'Android 后台运行时限已到；核心状态已确认',
    'Android 后台运行时限已到；正在核对暂停状态': 'Android 后台运行时限已到；正在核对暂停状态',
    '已安全暂停': '已安全暂停',
    '核心作业已结束': '核心作业已结束',
    '正在安全暂停；等待核心确认': '正在安全暂停；等待核心确认',
    '无法读取 Android 后台超时记录；批处理任务保持待核对：': '无法读取 Android 后台超时记录；批处理任务保持待核对：',
    '无法读取 Android 后台超时记录；启动、恢复与导出已暂缓：': '无法读取 Android 后台超时记录；启动、恢复与导出已暂缓：',
    '无法保存 Android 后台暂停记录；请重试后再启动或恢复。': '无法保存 Android 后台暂停记录；请重试后再启动或恢复。',
    'Android 后台超时任务仍待安全核对：': 'Android 后台超时任务仍待安全核对：',
    'Android 后台运行时限已到，原生任务仍在停止；等待确认安全暂停。':
        'Android 后台运行时限已到，原生任务仍在停止；等待确认安全暂停。',
    'Android 后台运行时限已到，任务已安全暂停。': 'Android 后台运行时限已到，任务已安全暂停。',
    'Android 后台运行时限已到；已记录原生任务的终止状态。': 'Android 后台运行时限已到；已记录原生任务的终止状态。',
    'Android 后台运行时限已到；保留此前成功的导出结果。': 'Android 后台运行时限已到；保留此前成功的导出结果。',
    '无法启动 Android 后台运行保护；核心任务尚未启动': '无法启动 Android 后台运行保护；核心任务尚未启动',
    'Android 后台运行保护不可用；请手动重试导出': 'Android 后台运行保护不可用；请手动重试导出',
    '无法启动 Android 后台运行保护；整图导出尚未启动': '无法启动 Android 后台运行保护；整图导出尚未启动',
    '无法启动后台运行保护；导出保持暂停': '无法启动后台运行保护；导出保持暂停',
    '无法启动后台运行保护；任务已安全暂停': '无法启动后台运行保护；任务已安全暂停',
    '无法启动后台运行保护；正在核对核心暂停状态': '无法启动后台运行保护；正在核对核心暂停状态',
    'Android 无法确认后台安全暂停，正在核对原生任务状态': 'Android 无法确认后台安全暂停，正在核对原生任务状态',
    'Android 批处理需要选择一个包含全景子目录的母目录。': 'Android 批处理需要选择一个包含全景子目录的母目录。',
    'Android 将文件夹复制到应用私有暂存目录，再逐个导入其中的原片。':
        'Android 将文件夹复制到应用私有暂存目录，再逐个导入其中的原片。',
    '批处理仅在 Windows 桌面版开放。移动版仍可使用单任务合成。': '批处理仅在 Windows 桌面版开放。移动版仍可使用单任务合成。',
    '保存到设备': '保存到设备',
    '分享到…': '分享到…',
    '保存成功': '保存成功',
    '分享已取消': '分享已取消',
    'people protection and water smoothing are supported only on Windows and macOS':
        '人物保护和水面平滑仅支持 Windows 和 macOS。',
    'people protection and water smoothing are supported only on desktop Windows and macOS':
        '人物保护和水面平滑仅支持 Windows 和 macOS 桌面版。',
    'scene semantic analysis is supported only on desktop Windows and macOS':
        '场景语义分析仅支持 Windows 和 macOS 桌面版。',
  };
}

class _StitchLocalizationsDelegate
    extends LocalizationsDelegate<StitchLocalizations> {
  const _StitchLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'en' || locale.languageCode == 'zh';

  @override
  Future<StitchLocalizations> load(Locale locale) =>
      SynchronousFuture(StitchLocalizations(locale));

  @override
  bool shouldReload(_StitchLocalizationsDelegate old) => false;
}
