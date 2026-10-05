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

  String text(String source) {
    if (isChinese) return _zh[source] ?? source;
    final exact = _en[source];
    if (exact != null) return exact;
    final status = RegExp(r'^(.+) · (\d+)% · (.+)$').firstMatch(source);
    if (status != null) {
      return '${text(status[1]!)} · ${status[2]}% · ${text(status[3]!)}';
    }
    final autoExport = RegExp(r'^完成后自动导出：(.+)$').firstMatch(source);
    if (autoExport != null) {
      return 'Automatic export after stitching: ${autoExport[1]}';
    }
    for (final entry in _en.entries) {
      if ((entry.key.endsWith('：') || entry.key == '设置 ') &&
          source.startsWith(entry.key)) {
        return '${entry.value}${source.substring(entry.key.length)}';
      }
    }
    final details = RegExp(r'^(\d+) 张 · (.+) · (.+)$').firstMatch(source);
    if (details != null) {
      return '${details[1]} photos · ${text(details[2]!)} · ${text(details[3]!)}';
    }
    final elapsed = RegExp(r'^已用 (\d+) 秒$').firstMatch(source);
    if (elapsed != null) return 'Elapsed ${elapsed[1]} sec';
    final elapsedMinutes = RegExp(r'^已用 (\d+) 分 (\d+) 秒$').firstMatch(source);
    if (elapsedMinutes != null) {
      return 'Elapsed ${elapsedMinutes[1]} min ${elapsedMinutes[2]} sec';
    }
    final estimatedGrid = RegExp(r'^网格为估算值，尚未校准；(.+)$').firstMatch(source);
    if (estimatedGrid != null) {
      return 'Grid positions are estimated and are not calibrated; '
          '${estimatedGrid[1]}';
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
      return 'DWARFLAB / DWARF3 / TELE identified from photo EXIF. Using '
          'nominal 150 mm profile fx=${cameraProfile[1]} px (scaled to image '
          'width), not calibrated. EXIF focal length: ${cameraProfile[2]}';
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
    'Lumia Stitch': 'PocketGigaScan',
    'DWARF Stitch': 'PocketGigaScan',
    '本地任务': 'Local tasks',
    '任务记录': 'Task history',
    '导入原片': 'Import photos',
    '导入照片': 'Import photos',
    '批处理队列': 'Batch queue',
    '批处理仅限 Windows 桌面版': 'Batch processing is available on Windows desktop',
    '查看输出': 'View output',
    '整图输出': 'Full image output',
    '排列与相机': 'Grid and camera',
    '输出与画质': 'Output and quality',
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
    '收起输出信息': 'Hide output information',
    '查看输出信息': 'Show output information',
    '重新检查': 'Check again',
    '100%': '100%',
    '正在加载全景…': 'Loading panorama…',
    '完整 PNG 导出独立于瓦片预览，使用上方“导出完整 PNG”。':
        'Full PNG export is separate from the tile preview. Use “Export full PNG” above.',
    '金字塔中暂无瓦片': 'No tiles are available in this pyramid',
    '导出完整 PNG': 'Export full PNG',
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
    '局部纹理校正': 'Local texture correction',
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
    '照片不可从网格移除；点按照片切换“强制按网格放置”。完整文件名可长按查看。':
        'Photos cannot be removed from the grid. Tap a photo to toggle forced grid placement. Long press to see the full filename.',
    '修正排列方式后查看网格预览。': 'Correct the grid order to preview the layout.',
    '金字塔清单无效：': 'Invalid pyramid manifest: ',
    '读取进度失败：': 'Could not read progress: ',
    '无法读取本地任务：': 'Could not load local tasks: ',
    '导入失败：': 'Import failed: ',
    '无法加入批处理：': 'Could not add batch: ',
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
    '未知': 'Unknown',
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
    '中心照片提供水平/垂直估算；启用精细校正后，此项用于四邻照片配准。':
        'Center photos provide horizontal and vertical estimates. With neighbor refinement enabled, this option applies to four-direction alignment.',
    '自动网格只估算中心相邻照片；启用精细校正后可并行四邻照片配准。':
        'Automatic grid mode estimates overlap from center neighbors only. Neighbor refinement can align four-direction pairs in parallel.',
    '自动网格使用固定的中心相邻照片估算；此项在自动模式下暂停使用。':
        'Automatic grid mode uses fixed center-neighbor estimates. This option is paused in automatic mode.',
    '精细校正会固定检查四个方向的相邻照片；关闭精细校正后可恢复此项设置。':
        'Neighbor refinement always checks all four directions. Turn it off to restore this setting.',
    '中心重叠估算固定使用 SIFT/BF；此项用于启用中的四邻照片配准。':
        'Center overlap estimation always uses SIFT/BF. This option applies to enabled four-direction alignment.',
    '自动网格估算固定使用 SIFT/BF；启用精细校正后可测试四邻照片配准。':
        'Automatic grid estimation always uses SIFT/BF. Enable neighbor refinement to experiment with four-direction alignment.',
    'ORB 使用 BF 匹配；FLANN 已关闭。': 'ORB uses BF matching; FLANN is disabled.',
    '默认使用 SIFT 特征。': 'SIFT features are used by default.',
    '自动网格估算固定使用 SIFT/BF；启用精细校正后可测试四邻配准。':
        'Automatic grid estimation always uses SIFT/BF. Enable neighbor refinement to experiment with four-direction alignment.',
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
    '批处理仅在 Windows 桌面版开放。移动版仍可使用单任务合成。':
        'Batch processing is available on Windows desktop. Single-task stitching remains available on mobile.',
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
    '结合四个方向的相邻照片校正网格配准，可能需要更长时间。':
        'Refine grid alignment using neighboring photos in four directions. This may take longer.',
    '减少错位边缘的宽区域叠加；场景视差仍需检查。关闭可与传统羽化结果对照。':
        'Reduces broad blending around misaligned edges. Check scene parallax. Turn off to compare traditional feather blending.',
    '缓存保存在任务输入目录旁的应用任务目录中。':
        'The cache is stored in the app task folder beside the task input directory.',
    '使用 0.6 MP 配准图；关闭时使用 2.0 MP。最终渲染仍为全分辨率。':
        'Align using 0.6 MP images; when off, use 2.0 MP. Final rendering remains full resolution.',
    '保存提速测试选项失败：': 'Could not save performance options: ',
    '行列必须是有效整数。': 'Rows and columns must be valid integers.',
    '水平视角需介于 1° 与 179°。':
        'Horizontal field of view must be between 1° and 179°.',
    '渲染内存预算需为 128–4096 MiB。': 'Render memory budget must be 128–4096 MiB.',
    '配准并行数需为 1–32。': 'Alignment worker count must be 1–32.',
    '水平与垂直重叠率需分别为 15%–80%。':
        'Horizontal and vertical overlap must each be 15%–80%.',
    '焦距像素值必须大于零。': 'Focal length in pixels must be greater than zero.',
    '无法映射': 'Cannot map',
    '布局': 'layout',
    'tile source information': 'Tile source information',
    '文件名需为 row_column.jpg；可切换到顺序模式':
        'Filenames must use row_column.jpg; switch to sequence mode.',
  };

  static const _zh = <String, String>{
    'Lumia Stitch': 'DWARF Stitch',
    '本地任务': '本地任务',
    '任务记录': '任务记录',
    '导入原片': '导入照片',
    '批处理队列': '批处理队列',
    '批处理仅限 Windows 桌面版': '批处理仅限 Windows 桌面版',
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
