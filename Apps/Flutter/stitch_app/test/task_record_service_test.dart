import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/export_fingerprint.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/performance_options.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/models/stitch_timeline.dart';
import 'package:stitch_app/services/task_record_service.dart';
import 'package:stitch_app/services/task_repository.dart';

String nativePath(String path) {
  if (!p.windows.isAbsolute(path)) return path;
  if (path.startsWith('\\\\')) {
    return '\\\\?\\UNC\\${path.substring(2).toUpperCase()}';
  }
  return '\\\\?\\${path.toUpperCase()}';
}

void main() {
  late Directory temp;
  late Directory root;
  late Directory output;
  late File source;
  late StitchTask task;
  late TaskRepository repository;
  late TaskRecordService service;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('task-record-service-');
    root = Directory(p.join(temp.path, 'tasks'));
    output = Directory(p.join(temp.path, 'output'))..createSync();
    source = File(p.join(temp.path, 'photo.jpg'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    final photo = ImportedPhoto(
      originalName: 'photo.jpg',
      storedPath: source.path,
      sha256: sha256.convert([1, 2, 3, 4]).toString(),
      width: 64,
      height: 32,
      originalOrder: 0,
    );
    task = StitchTask(
      id: '123459-abcd04',
      createdAt: DateTime.utc(2026, 10, 6),
      sourceDirectory: temp.path,
      outputDirectory: output.path,
      photos: [photo],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 256,
      workers: 3,
      phase: StitchPhase.completed,
    );
    repository = TaskRepository(rootDirectory: root);
    service = TaskRecordService(repository);
    await repository.save(task);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<String> taskDirectory() async =>
      (await repository.directoryFor(task.id)).path;

  test(
    'schema v2 snapshot retains task fields and current requested parameters',
    () async {
      final snapshot = await service.loadRecord(task.id);
      expect(snapshot, isNotNull);
      expect(snapshot!.schemaVersion, 2);
      expect(snapshot.task.outputDirectory, task.outputDirectory);
      expect(snapshot.record['photos'], hasLength(1));
      expect(
        (snapshot.record['algorithm'] as Map)['parameters'],
        containsPair('workers', 3),
      );
      expect((snapshot.record['outputs'] as Map)['colorAdjustment'], {
        'status': 'notApplied',
        'gains': null,
      });
      final stored =
          jsonDecode(
                await File(
                  p.join(await taskDirectory(), 'task.json'),
                ).readAsString(),
              )
              as Map<String, Object?>;
      expect(stored['schemaVersion'], 2);
      expect(stored['photos'], task.toJson()['photos']);
    },
  );

  test(
    'legacy v1 remains readable and refresh migrates the same master file',
    () async {
      final dir = await taskDirectory();
      final file = File(p.join(dir, 'task.json'));
      await file.writeAsString(jsonEncode(task.toJson()));

      final loaded = await service.loadRecord(task.id);
      expect(loaded?.schemaVersion, 2);
      final refreshed = await service.refreshRecord(task.id);
      expect(refreshed.schemaVersion, 2);
      expect(
        (jsonDecode(await file.readAsString()) as Map)['schemaVersion'],
        2,
      );
    },
  );

  test(
    'layout geometry is reconciled only with matching source hashes',
    () async {
      task = task.copyWith(
        performanceOptions: const PerformanceOptions(fastRegistration: true),
      );
      await repository.save(task);
      final manifest = {
        'schemaVersion': 1,
        'width': 120,
        'height': 60,
        'sourceHashes': {nativePath(source.path): task.photos.single.sha256},
        'requestHash': 'request-hash',
        'rendererStats': {'algorithmVersion': 1},
      };
      final layout = {
        'schemaVersion': 1,
        'renderBlendMode': 'feather',
        'tiles': [
          {
            'row': 0,
            'column': 0,
            'path': nativePath(source.path),
            'cameraToWorld': List<double>.filled(9, 0),
            'positionSource': 'visual',
            'forceGrid': false,
            'directVisualEvidence': true,
            'visualComponentId': 0,
            'visualConnectedToReference': true,
            'gridBridgeRequired': false,
            'fx': 30.0,
            'fy': 31.0,
            'cx': 32.0,
            'cy': 16.0,
            'width': 64,
            'height': 32,
          },
        ],
        'report': {
          'qualityStatus': 'needs-visual-review',
          'worstMeasuredEdges': [],
          'globalRayReprojectionRmsPx': 0.4,
          'registrationMegapixels': 2.0,
          'requestedRegistrationMegapixels': 0.6,
          'actualRegistrationMegapixels': 2.0,
          'precisionRecovery': {
            'enabled': true,
            'eligible': true,
            'attempted': true,
            'status': 'recovered',
            'requestedRegistrationMegapixels': 0.6,
            'actualRegistrationMegapixels': 2.0,
            'attempts': [
              {
                'registrationMegapixels': 0.6,
                'status': 'reprojectionQualityFailed',
              },
              {'registrationMegapixels': 2.0, 'status': 'completed'},
            ],
          },
          'edgeDiagnostics': [],
        },
      };
      final layoutJson = jsonEncode(layout);
      await File(
        p.join(output.path, 'manifest.json'),
      ).writeAsString(jsonEncode(manifest));
      await File(p.join(output.path, 'layout.json')).writeAsString(layoutJson);
      await File(p.join(output.path, 'job-state.json')).writeAsString(
        jsonEncode({
          'request_hash': 'request-hash',
          'source_hashes': manifest['sourceHashes'],
          'layout_hash': sha256.convert(utf8.encode(layoutJson)).toString(),
        }),
      );

      final snapshot = await service.loadRecord(task.id);
      final tile = (snapshot!.record['photos'] as List).single as Map;
      expect(tile['geometryStatus'], 'reconciled');
      expect(tile['positionSource'], 'visual');
      expect(tile['directVisualEvidence'], isTrue);
      expect(tile['visualConnectedToReference'], isTrue);
      expect(
        (snapshot.record['outputs'] as Map)['sourceManifestAssociation'],
        'verified',
      );
      expect(
        (snapshot.record['outputs'] as Map)['layoutStateAssociation'],
        'verified',
      );
      expect((snapshot.record['algorithm'] as Map)['version'], 1);
      final algorithm = snapshot.record['algorithm'] as Map;
      final adopted = algorithm['adoptedParameters'] as Map;
      expect(adopted['requestedRegistrationMegapixels'], 0.6);
      expect(adopted['actualRegistrationMegapixels'], 2.0);
      expect((adopted['precisionRecovery'] as Map)['status'], 'recovered');
      expect(
        ((adopted['precisionRecovery'] as Map)['attempts'] as List),
        hasLength(2),
      );
      expect(
        ((algorithm['parameters'] as Map)['performanceOptions']
            as Map)['fastRegistration'],
        isTrue,
      );
      expect(await service.verifyArtifactRef(snapshot, kind: 'layout'), isTrue);

      await File(
        p.join(output.path, 'layout.json'),
      ).writeAsString('$layoutJson ');
      await service.refreshRecord(task.id);
      final changed = (await service.loadRecord(task.id))!;
      final changedPhoto = (changed.record['photos'] as List).single as Map;
      expect(changedPhoto['geometryStatus'], 'uncomputed');
      expect(changedPhoto['cameraToWorld'], isNull);
      expect(
        ((changed.record['algorithm'] as Map)['adoptedParameters']),
        isNull,
      );
      expect(
        (changed.record['outputs'] as Map)['layoutStateAssociation'],
        'mismatch',
      );
      expect(
        (changed.record['outputs'] as Map)['sourceManifestAssociation'],
        'mismatch',
      );
    },
  );

  test(
    'completed repository save persists native geometry without viewer access',
    () async {
      final hashes = {nativePath(source.path): task.photos.single.sha256};
      await File(p.join(output.path, 'manifest.json')).writeAsString(
        jsonEncode({
          'width': 120,
          'height': 60,
          'requestHash': 'auto-persist-request',
          'sourceHashes': hashes,
        }),
      );
      final layout = {
        'tiles': [
          {
            'row': 0,
            'column': 0,
            'path': nativePath(source.path),
            'cameraToWorld': [1, 0, 0, 0, 1, 0, 0, 0, 1],
            'positionSource': 'visual',
            'placementConstraint': {
              'kind': 'gridPrior',
              'origin': 'systemFallback',
            },
            'directVisualEvidence': true,
            'visualConnectedToReference': true,
            'gridBridgeRequired': false,
            'fx': 30,
            'fy': 31,
            'cx': 32,
            'cy': 16,
            'width': 64,
            'height': 32,
          },
        ],
        'report': {'registrationMegapixels': 1.25},
      };
      final layoutJson = jsonEncode(layout);
      await File(p.join(output.path, 'layout.json')).writeAsString(layoutJson);
      await File(p.join(output.path, 'job-state.json')).writeAsString(
        jsonEncode({
          'request_hash': 'auto-persist-request',
          'source_hashes': hashes,
          'layout_hash': sha256.convert(utf8.encode(layoutJson)).toString(),
        }),
      );

      await repository.save(task.copyWith(phase: StitchPhase.completed));

      final envelope =
          jsonDecode(
                await File(
                  p.join(await taskDirectory(), 'task.json'),
                ).readAsString(),
              )
              as Map<String, Object?>;
      final record = envelope['record'] as Map;
      expect(
        ((record['photos'] as List).single as Map)['geometryStatus'],
        'reconciled',
      );
      expect(
        (record['outputs'] as Map)['sourceManifestAssociation'],
        'verified',
      );
      final adopted = (record['algorithm'] as Map)['adoptedParameters'] as Map;
      expect(adopted['requestedRegistrationMegapixels'], isNull);
      expect(adopted['actualRegistrationMegapixels'], 1.25);
      expect(adopted['precisionRecovery'], isNull);
    },
  );

  test(
    'late diagnostic write keeps the latest task timeline and export fields',
    () async {
      final staleRecord = TaskRecordService.initialRecord(task);
      final latestEvent = StitchTimelineEvent(
        id: 'latest-event',
        timestampUtc: DateTime.utc(2026, 10, 6, 12),
        kind: 'native-complete',
        state: 'completed',
      );
      final latestTask = task.copyWith(
        timeline: StitchTimeline(events: [latestEvent]),
        exportPath: p.join(temp.path, 'latest.jxl'),
      );
      await repository.save(latestTask);

      await repository.writeRecord(task.id, staleRecord);

      final envelope =
          jsonDecode(
                await File(
                  p.join(await taskDirectory(), 'task.json'),
                ).readAsString(),
              )
              as Map<String, Object?>;
      expect(envelope['timeline'], latestTask.timeline.toJson());
      expect(
        (envelope['record'] as Map)['outputs']['timeline'],
        latestTask.timeline.toJson(),
      );
      expect(
        (envelope['record'] as Map)['outputs']['exportPath'],
        latestTask.exportPath,
      );
    },
  );

  test(
    'registration failure evidence is bound by failed job state and survives record removal',
    () async {
      final hashes = {nativePath(source.path): task.photos.single.sha256};
      final failure = File(p.join(output.path, 'registration-failure.json'));
      await failure.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'code': 'REGISTRATION_FAILED',
          'message': 'weak registration evidence',
          'diagnostics': {
            'worstEdgeRmsPx': 55.01,
            'features': List.filled(8, 'evidence'),
          },
        }),
      );
      await File(p.join(output.path, 'job-state.json')).writeAsString(
        jsonEncode({
          'state': 'failed',
          'operation': 'render',
          'stage': 'registration-failed',
          'request_hash': 'failure-request',
          'source_hashes': hashes,
          'error': {
            'code': 'REGISTRATION_FAILED',
            'message': 'weak registration evidence',
            'diagnosticsPath': 'registration-failure.json',
          },
        }),
      );
      await repository.save(task.copyWith(phase: StitchPhase.failed));

      final saved =
          jsonDecode(
                await File(
                  p.join(await taskDirectory(), 'task.json'),
                ).readAsString(),
              )
              as Map<String, Object?>;
      final record = saved['record'] as Map;
      final nativeFailure = record['nativeFailure'] as Map;
      final failureRef =
          (record['diagnostics'] as Map)['registrationFailureRef'] as Map;
      expect(nativeFailure['code'], 'REGISTRATION_FAILED');
      expect(nativeFailure['state'], 'failed');
      expect(nativeFailure['stage'], 'registration-failed');
      expect(nativeFailure['relativePath'], 'registration-failure.json');
      expect(failureRef['sha256'], isNotEmpty);
      expect(failureRef['sizeBytes'], await failure.length());
      expect(
        ((record['photos'] as List).single as Map)['geometryStatus'],
        'uncomputed',
      );
      expect(
        ((record['photos'] as List).single as Map)['cameraToWorld'],
        isNull,
      );

      await repository.removeTaskRecord(task.id);

      expect(
        await File(p.join(await taskDirectory(), 'task.json')).exists(),
        isFalse,
      );
      expect(await failure.exists(), isTrue);
      expect(
        jsonDecode(await failure.readAsString())['code'],
        'REGISTRATION_FAILED',
      );
    },
  );

  test('generic failure cannot claim registration-failure evidence', () async {
    final failure = File(p.join(output.path, 'registration-failure.json'))
      ..writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'code': 'REGISTRATION_FAILED',
          'message': 'old evidence',
        }),
      );
    await File(p.join(output.path, 'job-state.json')).writeAsString(
      jsonEncode({
        'state': 'failed',
        'operation': 'render',
        'stage': 'render-failed',
        'request_hash': 'generic-failure-request',
        'source_hashes': {nativePath(source.path): task.photos.single.sha256},
        'error': {
          'code': 'JOB_FAILED',
          'message': 'render failed for another reason',
          'diagnosticsPath': 'registration-failure.json',
        },
      }),
    );
    await repository.save(task.copyWith(phase: StitchPhase.failed));

    final snapshot = (await service.loadRecord(task.id))!;

    expect(snapshot.record['nativeFailure'], isNull);
    expect(
      ((snapshot.record['diagnostics'] as Map)['registrationFailureRef']
          as Map)['integrityStatus'],
      'unassociated',
    );
    expect(await failure.exists(), isTrue);
  });

  test(
    'changed source hashes clear old geometry rather than presenting stale pose',
    () async {
      final manifest = {
        'width': 120,
        'height': 60,
        'sourceHashes': {source.path: 'wrong-hash'},
      };
      final layout = {
        'tiles': [
          {
            'row': 0,
            'column': 0,
            'path': source.path,
            'cameraToWorld': List<double>.filled(9, 0),
            'positionSource': 'visual',
          },
        ],
      };
      await File(
        p.join(output.path, 'manifest.json'),
      ).writeAsString(jsonEncode(manifest));
      await File(
        p.join(output.path, 'layout.json'),
      ).writeAsString(jsonEncode(layout));
      await File(p.join(output.path, 'job-state.json')).writeAsString(
        jsonEncode({
          'request_hash': 'different-request',
          'source_hashes': manifest['sourceHashes'],
        }),
      );

      final snapshot = await service.loadRecord(task.id);
      final tile = (snapshot!.record['photos'] as List).single as Map;
      expect(tile['geometryStatus'], 'uncomputed');
      expect(tile['cameraToWorld'], isNull);
      expect(
        (snapshot.record['outputs'] as Map)['sourceManifestAssociation'],
        'unknown',
      );
      expect(
        (snapshot.record['outputs'] as Map)['layoutStateAssociation'],
        'unknown',
      );
    },
  );

  test(
    'incident edges follow native layout tile indices when tile order is reversed',
    () async {
      final second = File(p.join(temp.path, 'photo-2.jpg'))
        ..writeAsBytesSync([8, 7, 6]);
      final firstPhoto = task.photos.single;
      final secondPhoto = ImportedPhoto(
        originalName: 'photo-2.jpg',
        storedPath: second.path,
        sha256: sha256.convert([8, 7, 6]).toString(),
        width: 64,
        height: 32,
        originalOrder: 1,
      );
      final twoPhotoTask = task.copyWith(
        photos: [firstPhoto, secondPhoto],
        grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 2),
      );
      await repository.save(twoPhotoTask);
      await File(p.join(output.path, 'manifest.json')).writeAsString(
        jsonEncode({
          'width': 240,
          'height': 60,
          'sourceHashes': {
            source.path: firstPhoto.sha256,
            second.path: secondPhoto.sha256,
          },
          'requestHash': 'two-photo-hash',
        }),
      );
      final hashes = {
        source.path: firstPhoto.sha256,
        second.path: secondPhoto.sha256,
      };
      final layout = {
        'tiles': [
          {
            'row': 0,
            'column': 1,
            'path': second.path,
            'cameraToWorld': [2],
          },
          {
            'row': 0,
            'column': 0,
            'path': source.path,
            'cameraToWorld': [1],
          },
        ],
        'report': {
          'edgeDiagnostics': [
            {'from': 0, 'to': 1, 'reason': 'test-edge'},
          ],
        },
      };
      final layoutJson = jsonEncode(layout);
      await File(p.join(output.path, 'layout.json')).writeAsString(layoutJson);
      await File(p.join(output.path, 'job-state.json')).writeAsString(
        jsonEncode({
          'request_hash': 'two-photo-hash',
          'source_hashes': hashes.map(
            (path, digest) => MapEntry(nativePath(path), digest),
          ),
          'layout_hash': sha256.convert(utf8.encode(layoutJson)).toString(),
        }),
      );

      final snapshot = await service.loadRecord(task.id);
      final photos = snapshot!.record['photos'] as List;
      expect((photos[0] as Map)['cameraToWorld'], [1]);
      expect((photos[1] as Map)['cameraToWorld'], [2]);
      expect((photos[0] as Map)['incidentEdges'], hasLength(1));
      expect((photos[1] as Map)['incidentEdges'], hasLength(1));
      expect(
        ((photos[1] as Map)['incidentEdges'] as List).single['reason'],
        'test-edge',
      );
    },
  );

  test('artifact verification rejects edited layout bytes', () async {
    final layout = File(p.join(output.path, 'layout.json'))
      ..writeAsStringSync('{"tiles":[]}');
    await service.refreshRecord(task.id);
    final snapshot = (await service.loadRecord(task.id))!;
    await layout.writeAsString('{"tiles":[1]}');

    expect(await service.verifyArtifactRef(snapshot, kind: 'layout'), isFalse);
  });

  test(
    'oversized diagnostic stays on disk and is not decoded into the cache',
    () async {
      final oversized = jsonEncode({
        'diagnostics': List.filled(128, 'x').join(),
      });
      final layout = File(p.join(output.path, 'layout.json'))
        ..writeAsStringSync(oversized);
      final serviceWithSmallLimit = TaskRecordService(
        repository,
        maxDiagnosticBytes: 64,
        parsedCacheBudgetBytes: 32,
      );

      final snapshot = (await serviceWithSmallLimit.loadRecord(task.id))!;

      expect(await layout.readAsString(), oversized);
      expect(
        (snapshot.record['diagnostics'] as Map)['layoutRef']['integrityStatus'],
        'tooLarge',
      );
      expect(
        ((snapshot.record['photos'] as List).single as Map)['geometryStatus'],
        'uncomputed',
      );
    },
  );

  test(
    'JXL digest is exposed only with a matching completed native export receipt',
    () async {
      final destination = File(p.join(temp.path, 'published.jxl'))
        ..writeAsBytesSync([9, 8, 7, 6]);
      final stat = await destination.stat();
      final exportTask = task.copyWith(
        exportPath: destination.path,
        exportFingerprint: ExportFileFingerprint(
          sizeBytes: stat.size,
          modifiedAtMicros: stat.modified.microsecondsSinceEpoch,
        ),
      );
      await repository.save(exportTask);
      final hashes = {source.path: task.photos.single.sha256};
      await File(p.join(output.path, 'manifest.json')).writeAsString(
        jsonEncode({
          'width': 120,
          'height': 60,
          'requestHash': 'export-request',
          'sourceHashes': hashes,
        }),
      );
      final layout = {
        'tiles': [
          {
            'row': 0,
            'column': 0,
            'path': source.path,
            'cameraToWorld': [1],
          },
        ],
        'report': {},
      };
      final layoutJson = jsonEncode(layout);
      await File(p.join(output.path, 'layout.json')).writeAsString(layoutJson);
      await File(p.join(output.path, 'job-state.json')).writeAsString(
        jsonEncode({
          'state': 'completed',
          'operation': 'export',
          'export_destination': nativePath(destination.path),
          'width': 120,
          'height': 60,
          'request_hash': 'export-request',
          'source_hashes': hashes.map(
            (path, digest) => MapEntry(nativePath(path), digest),
          ),
          'layout_hash': sha256.convert(utf8.encode(layoutJson)).toString(),
        }),
      );

      final verified = (await service.loadRecord(task.id))!;
      final outputs = verified.record['outputs'] as Map;
      expect(outputs['exportDigestStatus'], 'verifiedProducerReceipt');
      expect(outputs['exportSha256'], sha256.convert([9, 8, 7, 6]).toString());
      expect((outputs['producerReceipt'] as Map)['format'], 'jxl');
      expect(
        (outputs['producerReceipt'] as Map)['layoutSha256'],
        isA<String>(),
      );

      final changedState =
          jsonDecode(
                await File(
                  p.join(output.path, 'job-state.json'),
                ).readAsString(),
              )
              as Map<String, Object?>;
      changedState['export_destination'] = nativePath(
        p.join(temp.path, 'other.jxl'),
      );
      await File(
        p.join(output.path, 'job-state.json'),
      ).writeAsString(jsonEncode(changedState));
      final refused =
          (await service.loadRecord(task.id))!.record['outputs'] as Map;
      expect(refused['exportSha256'], isNull);
      expect(refused['exportDigestStatus'], 'notComputed');
      expect(refused['producerReceipt'], isNull);
    },
  );

  test(
    'PNG and TIFF saves retain stat metadata without hashing encoded exports',
    () async {
      final hashes = {source.path: task.photos.single.sha256};
      await File(p.join(output.path, 'manifest.json')).writeAsString(
        jsonEncode({
          'width': 120,
          'height': 60,
          'requestHash': 'export-request',
          'sourceHashes': hashes,
        }),
      );
      final layout = {
        'tiles': [
          {
            'row': 0,
            'column': 0,
            'path': source.path,
            'cameraToWorld': [1],
          },
        ],
        'report': {},
      };
      final layoutJson = jsonEncode(layout);
      await File(p.join(output.path, 'layout.json')).writeAsString(layoutJson);
      final layoutHash = sha256.convert(utf8.encode(layoutJson)).toString();

      for (final extension in ['png', 'tif']) {
        final destination = File(p.join(temp.path, 'published.$extension'))
          ..writeAsBytesSync(List<int>.generate(64, (index) => index));
        final stat = await destination.stat();
        final exportTask = task.copyWith(
          exportPath: destination.path,
          exportFingerprint: ExportFileFingerprint(
            sizeBytes: stat.size,
            modifiedAtMicros: stat.modified.microsecondsSinceEpoch,
          ),
        );
        await repository.save(exportTask);
        await File(p.join(output.path, 'job-state.json')).writeAsString(
          jsonEncode({
            'state': 'completed',
            'operation': 'export',
            'export_destination': nativePath(destination.path),
            'width': 120,
            'height': 60,
            'request_hash': 'export-request',
            'source_hashes': hashes.map(
              (path, digest) => MapEntry(nativePath(path), digest),
            ),
            'layout_hash': layoutHash,
          }),
        );

        final outputs =
            (await service.loadRecord(task.id))!.record['outputs'] as Map;
        expect(outputs['exportPath'], destination.path);
        expect(outputs['exportFingerprint']['sizeBytes'], stat.size);
        expect(outputs['exportSha256'], isNull);
        expect(outputs['exportDigestStatus'], 'notComputed');
        expect(outputs['producerReceipt'], isNull);
      }
    },
  );
}
