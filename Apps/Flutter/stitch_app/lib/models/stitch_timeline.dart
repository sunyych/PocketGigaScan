import 'dart:convert';

/// A timestamped lifecycle or native rendering transition.
class StitchTimelineEvent {
  const StitchTimelineEvent({
    required this.id,
    required this.timestampUtc,
    required this.kind,
    this.stage,
    this.state,
    this.operation,
  });

  final String id;
  final DateTime timestampUtc;
  final String kind;
  final String? stage;
  final String? state;
  final String? operation;

  Map<String, Object?> toJson() => {
    'id': id,
    'timestampUtc': timestampUtc.toUtc().toIso8601String(),
    'kind': kind,
    'stage': stage,
    'state': state,
    'operation': operation,
  };

  factory StitchTimelineEvent.fromJson(Map<String, Object?> json) =>
      StitchTimelineEvent(
        id: json['id']?.toString() ?? '',
        timestampUtc: DateTime.parse(json['timestampUtc']! as String).toUtc(),
        kind: json['kind'] as String? ?? 'legacy',
        stage: json['stage'] as String?,
        state: json['state'] as String?,
        operation: json['operation'] as String?,
      );
}

/// Timeline timing is explicitly wall clock, so a pause is part of its duration.
class StitchTimelineSummary {
  const StitchTimelineSummary({
    required this.startedAtUtc,
    required this.finishedAtUtc,
    required this.wallClockDuration,
    required this.latestOperationDuration,
    required this.isInProgress,
  });

  final DateTime? startedAtUtc;
  final DateTime? finishedAtUtc;
  final Duration? wallClockDuration;
  final Duration? latestOperationDuration;
  final bool isInProgress;

  bool get hasKnownStart => startedAtUtc != null;
}

/// Immutable, ordered timeline with id based deduplication.
class StitchTimeline {
  const StitchTimeline({this.events = const []});

  final List<StitchTimelineEvent> events;

  StitchTimeline mergeNativeBatch(
    List<Map<String, Object?>> batch, {
    required String jobId,
  }) {
    final additions = <StitchTimelineEvent>[];
    for (final event in batch) {
      try {
        final rawTime = event['timestampUtc'];
        final time = rawTime is num
            ? DateTime.fromMillisecondsSinceEpoch(rawTime.toInt(), isUtc: true)
            : DateTime.parse(rawTime! as String).toUtc();
        final rawId = event['id'];
        if (rawId == null) continue;
        additions.add(
          StitchTimelineEvent(
            id: 'native:$jobId:$rawId',
            timestampUtc: time,
            kind: event['kind'] as String? ?? 'native-transition',
            stage: event['stage'] as String?,
            state: event['state'] as String?,
            operation: event['operation'] as String?,
          ),
        );
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      } on RangeError {
        continue;
      }
    }
    return _merge(additions);
  }

  StitchTimeline mergeUiEvent({
    required String id,
    required String kind,
    DateTime? timestampUtc,
    String? stage,
    String? state,
    String? operation,
  }) => _merge([
    StitchTimelineEvent(
      id: id,
      timestampUtc: (timestampUtc ?? DateTime.now()).toUtc(),
      kind: kind,
      stage: stage,
      state: state,
      operation: operation,
    ),
  ]);

  StitchTimeline _merge(Iterable<StitchTimelineEvent> incoming) {
    final byId = <String, StitchTimelineEvent>{
      for (final event in events) event.id: event,
    };
    for (final event in incoming) {
      final existing = byId[event.id];
      if (existing == null) {
        byId[event.id] = event;
      } else if (!_sameEvent(existing, event)) {
        var suffix = 2;
        while (byId.containsKey('${event.id}#$suffix') &&
            !_sameEvent(byId['${event.id}#$suffix']!, event)) {
          suffix++;
        }
        if (!byId.containsKey('${event.id}#$suffix')) {
          byId['${event.id}#$suffix'] = StitchTimelineEvent(
            id: '${event.id}#$suffix',
            timestampUtc: event.timestampUtc,
            kind: event.kind,
            stage: event.stage,
            state: event.state,
            operation: event.operation,
          );
        }
      }
    }
    final indexed = byId.values.toList().asMap().entries.toList()
      ..sort((left, right) {
        final a = left.value;
        final b = right.value;
        final time = a.timestampUtc.compareTo(b.timestampUtc);
        if (time != 0) return time;
        final aSequence = int.tryParse(a.id.split(':').last);
        final bSequence = int.tryParse(b.id.split(':').last);
        final aSeparator = a.id.lastIndexOf(':');
        final bSeparator = b.id.lastIndexOf(':');
        if (aSeparator >= 0 &&
            bSeparator >= 0 &&
            aSequence != null &&
            bSequence != null &&
            a.id.substring(0, aSeparator) == b.id.substring(0, bSeparator)) {
          return aSequence.compareTo(bSequence);
        }
        return left.key.compareTo(right.key);
      });
    return StitchTimeline(
      events: List.unmodifiable(indexed.map((entry) => entry.value)),
    );
  }

  StitchTimeline merge(StitchTimeline other) => _merge(other.events);

  bool _sameEvent(StitchTimelineEvent a, StitchTimelineEvent b) =>
      a.timestampUtc.isAtSameMomentAs(b.timestampUtc) &&
      a.kind == b.kind &&
      a.stage == b.stage &&
      a.state == b.state &&
      a.operation == b.operation;

  Map<String, Object?> toJson() => {
    'events': events.map((event) => event.toJson()).toList(),
  };

  StitchTimelineSummary summary({
    bool autoExportExpected = false,
    DateTime? now,
  }) {
    const activeStates = {
      'queued',
      'running',
      'pausing',
      'paused',
      'exporting',
    };
    const terminalStates = {'completed', 'failed', 'cancelled'};
    final startCandidates = events.where(
      (event) =>
          event.kind == 'started' ||
          (event.operation == 'render' && event.state == 'queued'),
    );
    final started = startCandidates.isEmpty
        ? null
        : startCandidates.first.timestampUtc;
    final lifecycle = events
        .where(
          (event) =>
              event.state != null ||
              const {
                'started',
                'finished',
                'failed',
                'cancelled',
              }.contains(event.kind),
        )
        .toList();
    final latest = lifecycle.isEmpty ? null : lifecycle.last;
    var inProgress =
        latest != null &&
        (activeStates.contains(latest.state) ||
            latest.kind == 'started' ||
            latest.kind.endsWith('-started'));
    if (autoExportExpected &&
        latest?.state == 'completed' &&
        latest?.operation == 'render') {
      inProgress = true;
    }
    DateTime? finished;
    if (!inProgress &&
        latest != null &&
        (terminalStates.contains(latest.state) || latest.kind == 'finished')) {
      finished = latest.timestampUtc;
    }

    StitchTimelineEvent? latestOperationEvent;
    for (final event in events.reversed) {
      if (event.operation != null) {
        latestOperationEvent = event;
        break;
      }
    }
    DateTime? operationStart;
    DateTime? operationFinish;
    final operationEvent = latestOperationEvent;
    if (operationEvent != null) {
      final operationEvents = events
          .where((event) => event.operation == operationEvent.operation)
          .toList();
      var attemptStartIndex = 0;
      final latestIsTerminal = terminalStates.contains(operationEvent.state);
      for (
        var i = operationEvents.length - (latestIsTerminal ? 2 : 1);
        i >= 0;
        i--
      ) {
        if (terminalStates.contains(operationEvents[i].state)) {
          attemptStartIndex = i + 1;
          break;
        }
      }
      for (var i = attemptStartIndex; i < operationEvents.length; i++) {
        final event = operationEvents[i];
        if (operationStart == null && activeStates.contains(event.state)) {
          operationStart = event.timestampUtc;
        }
        if (terminalStates.contains(event.state)) {
          operationFinish = event.timestampUtc;
        }
      }
      if (operationFinish != null &&
          !terminalStates.contains(operationEvent.state)) {
        operationFinish = null;
      }
    }
    final end = inProgress ? (now ?? DateTime.now()).toUtc() : finished;
    final operationEnd =
        operationFinish ??
        (inProgress ? (now ?? DateTime.now()).toUtc() : finished);
    Duration? elapsed(DateTime? start, DateTime? end) =>
        start == null || end == null || end.isBefore(start)
        ? null
        : end.difference(start);
    return StitchTimelineSummary(
      startedAtUtc: started,
      finishedAtUtc: finished,
      wallClockDuration: elapsed(started, end),
      latestOperationDuration: elapsed(operationStart, operationEnd),
      isInProgress: inProgress,
    );
  }

  factory StitchTimeline.fromJson(Map<String, Object?>? json) {
    if (json == null) return const StitchTimeline();
    final values = json['events'] as List<Object?>? ?? const [];
    final valid = <StitchTimelineEvent>[];
    for (final value in values) {
      try {
        valid.add(StitchTimelineEvent.fromJson(value as Map<String, Object?>));
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    return StitchTimeline()._merge(valid);
  }

  String encode() => jsonEncode(toJson());
}
