import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/registration_issues.dart';

void main() {
  late Directory temp;
  late Directory output;
  late List<ImportedPhoto> photos;

  Future<void> writeState(List<Map<String, Object?>> tiles) async {
    await File(p.join(output.path, 'job-state.json')).writeAsString(
      jsonEncode({
        'job_id': output.path,
        'request': {'tiles': tiles},
      }),
    );
  }

  Future<void> writeFailure(Map<String, Object?> diagnostics) async {
    await File(
      p.join(output.path, 'registration-failure.json'),
    ).writeAsString(jsonEncode({'diagnostics': diagnostics}));
  }

  Map<String, Object?> tile(int row, int column, String path) => {
    'row': row,
    'column': column,
    'path': path,
  };

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('registration-issues-');
    output = Directory(p.join(temp.path, 'output'));
    await output.create();
    photos = [
      _photo(p.join(temp.path, 'a.jpg'), 'a.jpg', 0),
      _photo(p.join(temp.path, 'b.jpg'), 'b.jpg', 1),
      _photo(p.join(temp.path, 'c.jpg'), 'c.jpg', 2),
      _photo(p.join(temp.path, 'd.jpg'), 'd.jpg', 3),
    ];
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('maps sorted native indexes back to shuffled current photos', () async {
    final nativeJobId = Platform.isWindows
        ? '\\\\?\\${output.path}'
        : output.path;
    final task = _task(photos).copyWith(nativeJobId: nativeJobId);
    await writeState([
      tile(0, 0, photos[0].storedPath),
      tile(1, 0, photos[1].storedPath),
      tile(0, 1, photos[2].storedPath),
      tile(1, 1, photos[3].storedPath),
    ]);
    await writeFailure({
      'diagnosticTilePoses': [
        {'index': 0, 'row': 0, 'column': 0},
        {'index': 1, 'row': 0, 'column': 1},
        {'index': 2, 'row': 1, 'column': 0},
        {'index': 3, 'row': 1, 'column': 1},
      ],
      'maximumEdgeReprojectionRmsLimitPx': 10,
      'worstEdges': [
        {'from': 0, 'to': 1, 'rmsPx': 30},
        {'from': 2, 'to': 3, 'rmsPx': 20},
        {'from': 3, 'to': 2, 'rmsPx': 19},
        {'from': 1, 'to': 2, 'rmsPx': 7},
      ],
    });

    final issues = await loadRegistrationIssues(task);
    expect(issues.map((issue) => issue.rmsPx), [30, 20]);
    expect(issues.first.fromPhotoPath, photos[0].storedPath);
    expect(issues.first.toPhotoPath, photos[2].storedPath);
    expect(issues.first.fromName, 'a.jpg');
    expect(issues.first.toName, 'c.jpg');
    expect(issues.every((issue) => issue.exceedsLimit), isTrue);
  });

  test(
    'fails closed when job state no longer matches task photo paths',
    () async {
      final task = _task(photos);
      await writeState([
        tile(0, 0, photos[0].storedPath),
        tile(1, 0, photos[1].storedPath),
        tile(0, 1, photos[2].storedPath),
        tile(1, 1, p.join(temp.path, 'replaced.jpg')),
      ]);
      await writeFailure({
        'worstEdges': [
          {'from': 0, 'to': 3, 'rmsPx': 30},
        ],
      });

      expect(await loadRegistrationIssues(task), isEmpty);
    },
  );

  test(
    'fails closed for worstEdges-only artifacts without source bindings',
    () async {
      final task = _task(photos);
      await writeFailure({
        'worstEdges': [
          {'from': 0, 'to': 3, 'rmsPx': 13},
        ],
      });

      expect(await loadRegistrationIssues(task), isEmpty);
    },
  );

  test('refuses unsafe diagnostic paths', () async {
    final task = _task(
      photos,
      resultStats: {'registrationFailurePath': '../outside.json'},
    );
    await File(p.join(temp.path, 'outside.json')).writeAsString(
      jsonEncode({
        'diagnostics': {
          'worstEdges': [
            {'from': 0, 'to': 1, 'rmsPx': 99},
          ],
        },
      }),
    );
    expect(await loadRegistrationIssues(task), isEmpty);
  });

  test(
    'filters malformed edges and keeps only the highest duplicate RMS',
    () async {
      final normalTask = _task(photos);
      await writeState([
        tile(0, 0, photos[0].storedPath),
        tile(1, 0, photos[1].storedPath),
        tile(0, 1, photos[2].storedPath),
        tile(1, 1, photos[3].storedPath),
      ]);
      await File(
        p.join(output.path, 'registration-failure.json'),
      ).writeAsString(
        '{"diagnostics":{"maximumEdgeReprojectionRmsLimitPx":10,'
        '"worstEdges":[{"from":0,"to":1,"rmsPx":19},'
        '{"from":1,"to":0,"rmsPx":21},{"from":0,"to":2,"rmsPx":8},'
        '{"from":0,"to":0,"rmsPx":50},{"from":0,"to":99,"rmsPx":50},'
        '{"from":1,"to":2,"rmsPx":-1},{"from":2,"to":3,"rmsPx":1e999}]}}',
      );
      final issues = await loadRegistrationIssues(normalTask);
      expect(issues, hasLength(1));
      expect(issues.single.rmsPx, 21);
      expect(issues.single.fromPhotoPath, photos[2].storedPath);
      expect(issues.single.toPhotoPath, photos[0].storedPath);
    },
  );

  test('returns empty for damaged JSON instead of throwing', () async {
    await File(
      p.join(output.path, 'registration-failure.json'),
    ).writeAsString('{broken');
    expect(await loadRegistrationIssues(_task(photos)), isEmpty);
  });
}

ImportedPhoto _photo(String path, String name, int order) => ImportedPhoto(
  originalName: name,
  storedPath: path,
  sha256: 'hash-$order',
  width: 100,
  height: 50,
  originalOrder: order,
);

StitchTask _task(
  List<ImportedPhoto> photos, {
  Map<String, Object?>? resultStats,
}) => StitchTask(
  id: 'task-id',
  createdAt: DateTime.utc(2026),
  sourceDirectory: p.dirname(photos.first.storedPath),
  outputDirectory: p.join(p.dirname(photos.first.storedPath), 'output'),
  photos: photos,
  grid: const GridOptions(
    mode: GridMode.sequence,
    rows: 2,
    columns: 2,
    axis: TraversalAxis.column,
  ),
  horizontalFovDegrees: 45,
  memoryBudgetMiB: 128,
  workers: 2,
  phase: StitchPhase.failed,
  resultStats: resultStats,
);
