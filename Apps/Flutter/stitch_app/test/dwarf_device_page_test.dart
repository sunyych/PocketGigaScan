import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/dwarf_device_page.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/dwarf_download.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/device_network_service.dart';
import 'package:stitch_app/services/dwarf_device_client.dart';
import 'package:stitch_app/services/dwarf_download_service.dart';
import 'package:stitch_app/services/native_job_api.dart';

class _NoopJobApi implements JobApi {
  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<Map<String, Object?>> capabilities() async => const {};
  @override
  Future<Map<String, Object?>> cancel(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => const {};
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async =>
      const {};
  @override
  Future<Map<String, Object?>> pause(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> resume(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async => const {};
  @override
  Future<Map<String, Object?>> status(String jobId) async => const {};
}

class _FixtureQueueController extends BatchQueueController {
  _FixtureQueueController() : super(api: _NoopJobApi());

  final admitted = <DwarfDownloadBatch>[];
  List<BatchQueue> fixtureQueues = const [];

  @override
  List<BatchQueue> get queues => fixtureQueues;

  @override
  Future<void> addCompletedPanoramas(
    List<DwarfDownloadBatch> completedBatches, {
    AppSettings? settings,
  }) async {
    admitted.addAll(completedBatches);
    fixtureQueues = [
      BatchQueue(
        id: 'fixture-queue',
        createdAt: DateTime.utc(2026),
        parentDirectory: 'fixture-download-root',
        outputDirectory: 'fixture-output',
        items: [
          for (final batch in completedBatches)
            BatchQueueItem(
              id: batch.id,
              name: batch.metadata['title'] as String? ?? batch.id,
              sourceDirectory: batch.directory,
              state: BatchItemState.completed,
              taskId: 'task-${batch.id}',
            ),
        ],
      ),
    ];
  }
}

class _FixtureClient extends DwarfDeviceClient {
  _FixtureClient() : super('192.168.88.1');

  final panorama = const DwarfPanorama(
    id: '/sdcard/DCIM/DWARF3/Panoramas/Panorama_01',
    title: 'Panorama_01',
    filePath: '/sdcard/DCIM/DWARF3/Panoramas/Panorama_01',
    fileSize: 1024,
    mediaType: 1,
  );
  final originals = const [
    DwarfOriginal(
      id: 'source-01',
      name: 'image_001.jpg',
      url: 'http://192.168.88.1/image_001.jpg',
      size: 12,
    ),
  ];

  @override
  Future<DwarfDeviceInfo> probe() async =>
      const DwarfDeviceInfo(deviceName: 'DWARF3', sdCardAvailable: true);

  @override
  Future<List<DwarfPanorama>> listPanoramas({int pageSize = 50}) async => [
    panorama,
  ];

  @override
  Future<List<DwarfOriginal>> listOriginals(DwarfPanorama panorama) async =>
      originals;
}

class _FixtureDownloader extends DwarfDownloadService {
  _FixtureDownloader({this._saved = const []})
    : super(rootDirectory: 'fixture-download-root');

  final List<DwarfDownloadBatch> _saved;
  final Completer<DwarfDownloadBatch> transfer = Completer();
  Object? downloadFailure;
  bool downloadStarted = false;
  bool resumeStarted = false;
  bool cancelCalled = false;
  DwarfDownloadProgress? lastProgress;
  DwarfDownloadBatch? lastBatch;

  @override
  Future<List<DwarfDownloadBatch>> listBatches() async => _saved;

  @override
  Future<DwarfDownloadBatch?> loadBatch(String batchId) async {
    for (final batch in _saved) {
      if (batch.id == batchId) return batch;
    }
    if (lastBatch?.id == batchId) return lastBatch;
    return null;
  }

  @override
  Future<DwarfDownloadBatch> downloadBatch({
    required String batchId,
    required List<DwarfOriginal> originals,
    Map<String, Object?> metadata = const {},
    void Function(DwarfDownloadProgress progress)? onProgress,
  }) {
    downloadStarted = true;
    if (downloadFailure != null) return Future.error(downloadFailure!);
    lastBatch = DwarfDownloadBatch(
      id: batchId,
      directory: 'fixture-download-root/panorama',
      state: DwarfDownloadState.downloading,
      files: [
        DwarfDownloadFile(
          original: originals.single,
          path: 'fixture-download-root/panorama/image_001.jpg',
        ),
      ],
      metadata: metadata,
    );
    lastProgress = DwarfDownloadProgress(
      batchId: batchId,
      fileName: originals.single.name,
      fileBytes: 5,
      fileSize: 12,
      completedFiles: 0,
      totalFiles: 1,
    );
    onProgress?.call(lastProgress!);
    return transfer.future;
  }

  @override
  Future<DwarfDownloadBatch> resumeBatch(
    String batchId, {
    void Function(DwarfDownloadProgress progress)? onProgress,
  }) async {
    resumeStarted = true;
    final batch = _saved.singleWhere((value) => value.id == batchId);
    return completed(batch);
  }

  @override
  Future<void> cancelBatch(String batchId) async {
    cancelCalled = true;
    final current = lastBatch;
    if (current == null || transfer.isCompleted) return;
    lastBatch = _withState(current, DwarfDownloadState.cancelled);
    transfer.complete(lastBatch!);
  }

  @override
  void close({bool force = false}) {}
}

class _FixtureNetworkService extends DeviceNetworkService {
  @override
  Future<WifiSettingsHelpResult> openWifiSettings() async =>
      const WifiSettingsHelpResult(
        opened: false,
        guidance: 'Open Settings > Wi-Fi',
      );
}

DwarfDownloadBatch _withState(
  DwarfDownloadBatch batch,
  DwarfDownloadState state, {
  List<DwarfDownloadFile>? files,
}) => DwarfDownloadBatch(
  id: batch.id,
  directory: batch.directory,
  state: state,
  files: files ?? batch.files,
  metadata: batch.metadata,
);

DwarfDownloadBatch completed(DwarfDownloadBatch batch) => _withState(
  batch,
  DwarfDownloadState.completed,
  files: batch.files
      .map(
        (file) => DwarfDownloadFile(
          original: file.original,
          path: file.path,
          bytes: 12,
          complete: true,
          sha256: 'digest',
        ),
      )
      .toList(),
);

Widget _app(
  Widget child,
  Locale locale, {
  GlobalKey<NavigatorState>? navigatorKey,
}) => MaterialApp(
  navigatorKey: navigatorKey,
  locale: locale,
  supportedLocales: StitchLocalizations.supportedLocales,
  localizationsDelegates: const [
    StitchLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: child,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows editable host and English actions', (tester) async {
    final queue = BatchQueueController(api: _NoopJobApi());
    final downloader = _FixtureDownloader();
    await tester.pumpWidget(
      _app(
        DwarfDevicePage(
          queueController: queue,
          downloader: downloader,
          client: _FixtureClient(),
          networkService: _FixtureNetworkService(),
        ),
        const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('192.168.88.1'), findsOneWidget);
    expect(find.text('Connect to device'), findsOneWidget);
    expect(find.text('Open Wi-Fi settings'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '192.168.88.2');
    expect(find.text('192.168.88.2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    queue.dispose();
  });

  testWidgets('exposes Pause during the first panorama transfer', (
    tester,
  ) async {
    final queue = BatchQueueController(api: _NoopJobApi());
    final client = _FixtureClient();
    final downloader = _FixtureDownloader();
    await tester.pumpWidget(
      _app(
        DwarfDevicePage(
          queueController: queue,
          downloader: downloader,
          client: client,
          networkService: _FixtureNetworkService(),
        ),
        const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect to device'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download selected panoramas'));
    await tester.pump();
    await tester.pump();

    expect(downloader.downloadStarted, isTrue);
    expect(find.text('Pause download'), findsOneWidget);
    await tester.tap(find.text('Pause download'));
    await tester.pumpAndSettle();
    expect(find.text('Resume download'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    queue.dispose();
  });

  testWidgets('download progress survives returning to the task screen', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final queue = _FixtureQueueController();
    final client = _FixtureClient();
    final downloader = _FixtureDownloader();
    final statuses = <DwarfTransferStatus>[];
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => navigatorKey.currentState!.push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => DwarfDevicePage(
                    queueController: queue,
                    downloader: downloader,
                    client: client,
                    networkService: _FixtureNetworkService(),
                    onTransferStatus: statuses.add,
                  ),
                ),
              ),
              child: const Text('Open DWARF'),
            ),
          ),
        ),
        const Locale('en'),
        navigatorKey: navigatorKey,
      ),
    );
    await tester.tap(find.text('Open DWARF'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect to device'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download selected panoramas'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dwarf-download-status')), findsOneWidget);
    expect(statuses.last.state, DwarfDownloadState.downloading);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(downloader.cancelCalled, isFalse);
    expect(statuses.last.state, DwarfDownloadState.downloading);

    downloader.transfer.complete(
      _withState(downloader.lastBatch!, DwarfDownloadState.paused),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(statuses.last.state, DwarfDownloadState.paused);
    expect(queue.admitted, isEmpty);
    queue.dispose();
  });

  testWidgets('completed download selects the first queued task after return', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final queue = _FixtureQueueController();
    final downloader = _FixtureDownloader();
    final openedTasks = <String>[];
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => navigatorKey.currentState!.push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => DwarfDevicePage(
                    queueController: queue,
                    downloader: downloader,
                    client: _FixtureClient(),
                    networkService: _FixtureNetworkService(),
                    onTaskReady: (taskId) async => openedTasks.add(taskId),
                  ),
                ),
              ),
              child: const Text('Open DWARF'),
            ),
          ),
        ),
        const Locale('en'),
        navigatorKey: navigatorKey,
      ),
    );
    await tester.tap(find.text('Open DWARF'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect to device'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download selected panoramas'));
    await tester.pump();
    await tester.pump();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    downloader.transfer.complete(completed(downloader.lastBatch!));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    expect(queue.admitted, hasLength(1));
    expect(openedTasks, ['task-${queue.admitted.single.id}']);
    queue.dispose();
  });

  testWidgets(
    'keeps download errors visible at the top in English and Chinese',
    (tester) async {
      for (final locale in [const Locale('en'), const Locale('zh')]) {
        final queue = BatchQueueController(api: _NoopJobApi());
        final downloader = _FixtureDownloader()
          ..downloadFailure = StateError('Duplicate original filename');
        await tester.pumpWidget(
          _app(
            DwarfDevicePage(
              queueController: queue,
              downloader: downloader,
              client: _FixtureClient(),
              networkService: _FixtureNetworkService(),
            ),
            locale,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(locale.languageCode == 'zh' ? '连接设备' : 'Connect to device'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(CheckboxListTile).first);
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(
            locale.languageCode == 'zh'
                ? '下载所选全景'
                : 'Download selected panoramas',
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('dwarf-device-error-banner')),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            locale.languageCode == 'zh'
                ? '重复的原片文件名'
                : 'Duplicate original filename',
          ),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        queue.dispose();
      }
    },
  );

  testWidgets('restores a paused offline transfer with Resume action', (
    tester,
  ) async {
    final queue = _FixtureQueueController();
    final saved = DwarfDownloadBatch(
      id: 'saved-panorama',
      directory: 'fixture-download-root/saved',
      state: DwarfDownloadState.paused,
      files: const [
        DwarfDownloadFile(
          original: DwarfOriginal(
            id: 'original',
            name: 'one.jpg',
            url: 'http://camera/one.jpg',
            size: 12,
          ),
          path: 'fixture-download-root/saved/one.jpg',
          bytes: 5,
        ),
      ],
      metadata: const {'title': 'Saved panorama', 'host': '192.168.88.1'},
    );
    final downloader = _FixtureDownloader(saved: [saved]);
    String? openedTaskId;
    await tester.pumpWidget(
      _app(
        DwarfDevicePage(
          queueController: queue,
          downloader: downloader,
          networkService: _FixtureNetworkService(),
          onTaskReady: (taskId) => openedTaskId = taskId,
        ),
        const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Saved panorama'), findsOneWidget);
    expect(find.text('Resume download'), findsOneWidget);
    await tester.tap(find.text('Resume download'));
    await tester.pumpAndSettle();
    expect(downloader.resumeStarted, isTrue);
    expect(queue.admitted, hasLength(1));
    expect(openedTaskId, 'task-saved-panorama');

    await tester.pumpWidget(const SizedBox.shrink());
    queue.dispose();
  });
}
