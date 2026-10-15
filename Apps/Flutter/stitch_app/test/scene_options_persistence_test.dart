import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/services/spherical_request.dart';
import 'package:stitch_app/services/scene_model_service.dart';

void main() {
  test(
    'scene options default off and survive settings, task, and queue storage',
    () {
      expect(const AppSettings().protectPeople, isFalse);
      expect(const AppSettings().smoothWater, isFalse);
      expect(AppSettings.fromJson({'language': 'en'}).protectPeople, isFalse);
      expect(AppSettings.fromJson({'language': 'en'}).smoothWater, isFalse);

      final settings = const AppSettings(
        protectPeople: true,
        smoothWater: true,
      );
      final encodedSettings = jsonEncode(settings.toJson());
      expect(AppSettings.decode(encodedSettings).protectPeople, isTrue);
      expect(AppSettings.decode(encodedSettings).smoothWater, isTrue);

      final task = StitchTask(
        id: 'task',
        createdAt: DateTime.utc(2026),
        sourceDirectory: 'input',
        outputDirectory: 'output',
        photos: const [],
        grid: const GridOptions(),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 512,
        workers: 4,
        phase: StitchPhase.imported,
        protectPeople: true,
        smoothWater: true,
      );
      final restored = StitchTask.fromJson(task.toJson());
      expect(restored.protectPeople, isTrue);
      expect(restored.smoothWater, isTrue);
      expect(restored.copyWith(protectPeople: false).smoothWater, isTrue);

      final queue = BatchQueue(
        id: 'queue',
        createdAt: DateTime.utc(2026),
        parentDirectory: 'parent',
        outputDirectory: 'output',
        items: const [],
        protectPeople: true,
        smoothWater: true,
      );
      final roundTrip = BatchQueue.fromJson(queue.toJson());
      expect(roundTrip.protectPeople, isTrue);
      expect(roundTrip.smoothWater, isTrue);
    },
  );

  test(
    'native request sends four independent flag combinations and Windows metadata',
    () {
      final photo = _photo();
      for (final people in [false, true]) {
        for (final water in [false, true]) {
          final task = _task(photo, people, water);
          final mobileRequest = buildSphericalRequest(
            task,
            supportsSceneModel: false,
          );
          expect(mobileRequest['protectPeople'], isFalse);
          expect(mobileRequest['smoothWater'], isFalse);
          expect(mobileRequest.containsKey('sceneModelPath'), isFalse);

          final metadata = SceneModelMetadata(
            modelPath: r'C:\cache\scene-model-v1.onnx',
            sha256: 'a' * 64,
            cacheDirectory: r'C:\cache\scene-cache',
          );
          final request = buildSphericalRequest(
            task,
            supportsSceneModel: true,
            sceneModel: people || water ? metadata : null,
          );
          expect(request['protectPeople'], people);
          expect(request['smoothWater'], water);
          expect(request.containsKey('sceneModelPath'), people || water);
          if (people || water) {
            expect(request['sceneModelPath'], metadata.modelPath);
            expect(request['sceneModelSha256'], metadata.sha256);
            expect(request['sceneCacheDir'], metadata.cacheDirectory);
          }
        }
      }
    },
  );
}

StitchTask _task(ImportedPhoto photo, bool people, bool water) => StitchTask(
  id: 'task',
  createdAt: DateTime.utc(2026),
  sourceDirectory: 'input',
  outputDirectory: 'output',
  photos: [photo],
  grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
  horizontalFovDegrees: 45,
  memoryBudgetMiB: 512,
  workers: 4,
  phase: StitchPhase.imported,
  protectPeople: people,
  smoothWater: water,
);

ImportedPhoto _photo() => const ImportedPhoto(
  originalName: 'photo.jpg',
  storedPath: 'photo.jpg',
  sha256: 'a',
  width: 100,
  height: 80,
  originalOrder: 0,
);
