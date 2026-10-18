import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/performance_options.dart';

void main() {
  test('legacy four-neighbor setting is readable but requests fixed eight', () {
    final legacy = PerformanceOptions.fromJson({
      'fourNeighborFirst': true,
      'parallelMatching': false,
    });
    expect(legacy.fourNeighborFirst, isTrue);
    expect(legacy.toJson()['fourNeighborFirst'], isTrue);
    expect(legacy.neighborMode, 'eight');
    expect(legacy.parallelMatching, isFalse);
  });

  test('new defaults use the fixed eight-neighbor contract', () {
    const options = PerformanceOptions();
    expect(options.neighborMode, 'eight');
    expect(options.toJson()['fourNeighborFirst'], isFalse);
  });
}
