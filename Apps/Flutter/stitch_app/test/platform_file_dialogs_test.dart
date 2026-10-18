import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/services/platform_file_dialogs.dart';

class _FakeFileSelector extends FileSelectorPlatform {
  List<XFile> files = [];
  List<XTypeGroup>? acceptedTypeGroups;
  FileDialogOptions? directoryOptions;
  String? directory;
  Object? failure;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    if (failure case final error?) throw error;
    this.acceptedTypeGroups = acceptedTypeGroups;
    return files;
  }

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) async {
    if (failure case final error?) throw error;
    directoryOptions = options;
    return directory;
  }
}

class _FakeFilePicker extends FilePicker {
  FilePickerResult? result;
  FileType? type;
  List<String>? allowedExtensions;
  bool? allowMultiple;
  bool? withData;
  bool? withReadStream;
  Object? failure;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    @Deprecated('allowCompression is deprecated') bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    if (failure case final error?) throw error;
    this.type = type;
    this.allowedExtensions = allowedExtensions;
    this.allowMultiple = allowMultiple;
    this.withData = withData;
    this.withReadStream = withReadStream;
    return result;
  }
}

void main() {
  late Directory temporary;
  late FileSelectorPlatform originalSelector;
  late FilePicker originalPicker;
  late _FakeFileSelector selector;
  late _FakeFilePicker picker;
  late XFile firstFile;
  late XFile secondFile;

  setUp(() async {
    FilePickerIO.registerWith();
    originalPicker = FilePicker.platform;
    originalSelector = FileSelectorPlatform.instance;
    selector = _FakeFileSelector();
    picker = _FakeFilePicker();
    FileSelectorPlatform.instance = selector;
    FilePicker.platform = picker;

    temporary = await Directory.systemTemp.createTemp('file-dialog-test-');
    final firstPath = '${temporary.path}${Platform.pathSeparator}照片 你好.jpg';
    final secondPath = '${temporary.path}${Platform.pathSeparator}second.jpeg';
    await File(firstPath).writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);
    await File(secondPath).writeAsBytes([1, 2, 3, 4, 5]);
    firstFile = XFile(firstPath);
    secondFile = XFile(secondPath);
  });

  tearDown(() async {
    FileSelectorPlatform.instance = originalSelector;
    FilePicker.platform = originalPicker;
    await temporary.delete(recursive: true);
  });

  for (final count in [37, 1025]) {
    test(
      'Windows adapter preserves $count files and source metadata',
      () async {
        selector.files = List<XFile>.generate(
          count,
          (index) => index.isEven ? firstFile : secondFile,
        );

        final result = await PlatformFileDialogs(isWindows: true).pickJpegs();

        expect(result, hasLength(count));
        expect(selector.acceptedTypeGroups, hasLength(1));
        expect(selector.acceptedTypeGroups!.single.label, 'JPEG');
        expect(selector.acceptedTypeGroups!.single.extensions, ['jpg', 'jpeg']);
        expect(result![0].name, '照片 你好.jpg');
        expect(result[0].path, firstFile.path);
        expect(result[0].size, 4);
        expect(result[1].name, 'second.jpeg');
        expect(result[1].path, secondFile.path);
        expect(result[1].size, 5);
        expect(result[0].bytes, isNull);
        expect(result[0].readStream, isNull);
        expect(
          result.last.path,
          count.isOdd ? firstFile.path : secondFile.path,
        );
      },
    );
  }

  test('Windows dialog cancellation returns null', () async {
    selector.files = [];

    expect(await PlatformFileDialogs(isWindows: true).pickJpegs(), isNull);
  });

  test('Windows picker errors propagate to the import handler', () async {
    selector.failure = const FileSystemException('dialog failed');

    await expectLater(
      PlatformFileDialogs(isWindows: true).pickJpegs(),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('Windows folder picker forwards options and cancellation', () async {
    final result = await PlatformFileDialogs(
      isWindows: true,
    ).getDirectoryPath(confirmButtonText: 'Choose folder');

    expect(result, isNull);
    expect(selector.directoryOptions?.confirmButtonText, 'Choose folder');
  });

  test('non-Windows picker preserves streamed multi-select options', () async {
    final input = PlatformFile(
      name: firstFile.name,
      path: firstFile.path,
      size: 4,
      readStream: Stream<List<int>>.value([0xff, 0xd8]),
    );
    picker.result = FilePickerResult([input]);

    final result = await PlatformFileDialogs(isWindows: false).pickJpegs();

    expect(identical(result!.single, input), isTrue);
    expect(picker.type, FileType.custom);
    expect(picker.allowedExtensions, ['jpg', 'jpeg']);
    expect(picker.allowMultiple, isTrue);
    expect(picker.withData, isFalse);
    expect(picker.withReadStream, isTrue);
    expect(result.single.readStream, isNotNull);
  });

  test('non-Windows picker cancellation returns null', () async {
    picker.result = null;

    expect(await PlatformFileDialogs(isWindows: false).pickJpegs(), isNull);
  });
}
