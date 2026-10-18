import 'package:flutter/foundation.dart';
import '../models/app_settings.dart';
import 'settings_repository.dart';

class SettingsController extends ChangeNotifier {
  SettingsController({
    SettingsRepository? repository,
    AppSettings? initial,
    AppSettings defaults = const AppSettings(),
  }) : _repository = repository ?? SettingsRepository(defaults: defaults),
       _settings = initial ?? defaults {
    ready = initial == null ? _load() : Future.value();
  }
  final SettingsRepository _repository;
  AppSettings _settings;
  AppSettings get settings => _settings;
  late final Future<void> ready;
  String? error;
  int _revision = 0;
  bool _disposed = false;

  Future<void> _load() async {
    final revision = _revision;
    final loaded = await _repository.load();
    if (_revision == revision && !_disposed) {
      _settings = loaded;
      notifyListeners();
    }
  }

  Future<void> update(AppSettings value) async {
    final revision = ++_revision;
    _settings = value;
    error = null;
    notifyListeners();
    try {
      await _repository.save(value);
    } catch (e) {
      if (_disposed || revision != _revision) return;
      error = e.toString();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> updateWith(AppSettings Function(AppSettings) change) =>
      update(change(_settings));
}
