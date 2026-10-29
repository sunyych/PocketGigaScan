import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/services/usb_dwarf_import_service.dart';

void main() {
  group('USB DWARF import safety', () {
    test(
      'same-name JPEG selection prefers pixel area over byte size',
      () async {
        final root = await Directory.systemTemp.createTemp('usb-dwarf-area-');
        addTearDown(() => root.delete(recursive: true));
        final panorama = Directory(p.join(root.path, 'DWARF_PANORAMA_test'));
        final smallCopy = Directory(p.join(panorama.path, '1'));
        await smallCopy.create(recursive: true);

        final lowResolution = File(p.join(panorama.path, 'same.jpg'));
        final highResolution = File(p.join(smallCopy.path, 'same.jpg'));
        await lowResolution.writeAsBytes(
          _jpegHeader(width: 100, height: 100, padding: 2048),
        );
        await highResolution.writeAsBytes(_jpegHeader(width: 200, height: 200));
        expect(
          await lowResolution.length(),
          greaterThan(await highResolution.length()),
        );

        final selected = await UsbDwarfImportService().selectMaximumPhotos(
          panorama.path,
        );
        expect(selected, hasLength(1));
        expect(
          p.normalize(selected.single.file.path),
          p.normalize(highResolution.path),
        );
      },
    );

    test(
      'source signature is stable when duplicate-name candidates are reordered',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'usb-dwarf-signature-order-',
        );
        addTearDown(() => root.delete(recursive: true));
        final service = UsbDwarfImportService();
        final firstRoot = await _duplicateNameFixture(
          root,
          'first',
          createOneFirst: true,
        );
        final secondRoot = await _duplicateNameFixture(
          root,
          'second',
          createOneFirst: false,
        );
        final first = service.sourceFor(
          volumeId: 'fixture-volume',
          identity: 'fixture-volume/first',
          directory: firstRoot.path,
          mountPath: root.path,
        );
        final second = service.sourceFor(
          volumeId: 'fixture-volume',
          identity: 'fixture-volume/second',
          directory: secondRoot.path,
          mountPath: root.path,
        );

        expect(
          await service.sourceSignature(first),
          await service.sourceSignature(second),
          reason:
              'A reordering of the same candidate set must not look like active capture writes',
        );
      },
    );

    test(
      'stale and unreadable later sources fail without source deletion or history',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'usb-dwarf-copy-failure-',
        );
        addTearDown(() => root.delete(recursive: true));
        final service = UsbDwarfImportService(
          supportDirectory: () => Directory(p.join(root.path, 'support')),
        );
        final panorama = Directory(p.join(root.path, 'panorama'));
        await panorama.create();
        final first = File(p.join(panorama.path, 'a.jpg'));
        final second = File(p.join(panorama.path, 'b.jpg'));
        await first.writeAsBytes(_jpegHeader(width: 120, height: 90));
        await second.writeAsBytes(_jpegHeader(width: 121, height: 91));
        final selected = await service.selectMaximumPhotos(panorama.path);
        expect(selected, hasLength(2));

        // A changed size after selection must stop the copy. The earlier file
        // may have a verified local copy, but neither USB source is removed and
        // no imported-identity marker is written by the copier.
        await second.writeAsBytes([
          ...await second.readAsBytes(),
          0x55,
        ], flush: true);
        final staleDestination = Directory(p.join(root.path, 'stale-copy'));
        await expectLater(
          service.copyVerified(
            sources: selected,
            destinationDirectory: staleDestination.path,
            deleteSources: false,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await first.exists(), isTrue);
        expect(await second.exists(), isTrue);
        expect(
          await File(p.join(staleDestination.path, 'a.jpg')).exists(),
          isTrue,
        );
        expect(await service.loadImportedIdentities(), isEmpty);

        // Removing a later source after enumeration simulates a card becoming
        // unreadable mid-run after an earlier file has already been copied.
        final freshSelection = await service.selectMaximumPhotos(panorama.path);
        expect(freshSelection, hasLength(2));
        await second.delete();
        final missingDestination = Directory(p.join(root.path, 'missing-copy'));
        await expectLater(
          service.copyVerified(
            sources: freshSelection,
            destinationDirectory: missingDestination.path,
            deleteSources: false,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await first.exists(), isTrue);
        expect(
          await second.exists(),
          isFalse,
          reason:
              'The test itself removed this source to simulate disappearance',
        );
        expect(
          await File(p.join(missingDestination.path, 'a.jpg')).exists(),
          isTrue,
        );
        expect(await service.loadImportedIdentities(), isEmpty);
      },
    );

    test(
      'delete preflights every hash before removing any selected source',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'usb-dwarf-delete-preflight-',
        );
        addTearDown(() => root.delete(recursive: true));
        final service = UsbDwarfImportService(
          supportDirectory: () => Directory(p.join(root.path, 'support')),
        );
        final panorama = Directory(p.join(root.path, 'panorama'));
        await panorama.create();
        final first = File(p.join(panorama.path, 'a.jpg'));
        final second = File(p.join(panorama.path, 'b.jpg'));
        final preview = File(p.join(panorama.path, 'panorama_thumbnail.jpg'));
        final html = File(p.join(panorama.path, 'index.html'));
        final adjacent = File(p.join(panorama.path, 'notes.bin'));
        await first.writeAsBytes(_jpegHeader(width: 120, height: 90));
        await second.writeAsBytes(_jpegHeader(width: 121, height: 91));
        await preview.writeAsBytes(_jpegHeader(width: 32, height: 16));
        await html.writeAsString('<html>camera metadata</html>');
        await adjacent.writeAsBytes([1, 2, 3, 4]);
        final sources = await service.selectMaximumPhotos(panorama.path);
        final firstHash = (await sha256.bind(first.openRead()).first)
            .toString();

        // B's mismatch must retain A too: deletion is an all-or-nothing group
        // operation. Sidecars are never part of this source list.
        UsbSourceCleanupResult? cleanup;
        try {
          cleanup = await service.deleteVerifiedSources(
            sources: [
              sources.singleWhere(
                (source) => p.basename(source.file.path) == 'a.jpg',
              ),
              sources.singleWhere(
                (source) => p.basename(source.file.path) == 'b.jpg',
              ),
            ],
            expectedHashesByName: {'a.jpg': firstHash, 'b.jpg': 'wrong-hash'},
          );
        } on Object {
          // An explicit rejection is also fail-closed, provided no member was
          // removed before the mismatch was detected.
        }
        expect(
          await first.exists(),
          isTrue,
          reason: 'Matching A must survive B’s failed group preflight',
        );
        expect(await second.exists(), isTrue);
        expect(await preview.exists(), isTrue);
        expect(await html.exists(), isTrue);
        expect(await adjacent.exists(), isTrue);
        if (cleanup != null) {
          expect(cleanup.deleted, isEmpty);
          expect(cleanup.retained, containsAll([first.path, second.path]));
        }
      },
    );

    test(
      'corrupt import-history markers fail closed instead of looking empty',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'usb-dwarf-bad-history-',
        );
        addTearDown(() => root.delete(recursive: true));
        final service = UsbDwarfImportService(
          supportDirectory: () => Directory(p.join(root.path, 'support')),
        );
        final history = await service.historyRoot();
        await service.markImported('fixture-corrupt-marker');
        final markers = <File>[];
        await for (final entity in history.list(followLinks: false)) {
          if (entity is File &&
              RegExp(
                r'^[a-f0-9]{64}\.json$',
              ).hasMatch(p.basename(entity.path))) {
            markers.add(entity);
          }
        }
        expect(markers, hasLength(1));
        await markers.single.writeAsString('{bad json');
        await expectLater(
          service.loadImportedIdentities(),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'file symlink cannot be scanned, copied, or used to delete its target',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'usb-dwarf-file-link-',
        );
        addTearDown(() => root.delete(recursive: true));
        final panorama = Directory(p.join(root.path, 'panorama'));
        final outside = Directory(p.join(root.path, 'outside'));
        await panorama.create();
        await outside.create();
        final target = File(p.join(outside.path, 'outside.jpg'));
        await target.writeAsBytes(_jpegHeader(width: 400, height: 300));
        final link = Link(p.join(panorama.path, 'linked.jpg'));
        await _createLinkOrSkip(link, target.path, 'file symlink');

        final service = UsbDwarfImportService(
          supportDirectory: () => Directory(p.join(root.path, 'support')),
        );
        expect(await service.selectMaximumPhotos(panorama.path), isEmpty);
        final targetStat = await target.stat();
        final linkedSource = UsbPhotoSource(
          file: File(link.path),
          length: targetStat.size,
          modified: targetStat.modified,
        );
        final destination = Directory(p.join(root.path, 'link-copy'));
        await expectLater(
          service.copyVerified(
            sources: [linkedSource],
            destinationDirectory: destination.path,
            deleteSources: false,
          ),
          throwsA(anything),
          reason:
              'Public copier must refuse a caller-supplied link instead of reading its target',
        );
        expect(
          await File(p.join(destination.path, 'linked.jpg')).exists(),
          isFalse,
        );
        final targetHash = (await sha256.bind(target.openRead()).first)
            .toString();
        final cleanup = await service.deleteVerifiedSources(
          sources: [linkedSource],
          expectedHashesByName: {'linked.jpg': targetHash},
        );
        expect(cleanup.deleted, isEmpty);
        expect(cleanup.retained, contains(link.path));
        expect(await target.exists(), isTrue);
        expect(await link.exists(), isTrue);
        expect(await service.loadImportedIdentities(), isEmpty);
      },
    );

    test(
      'directory symlink cannot expose JPEGs outside a panorama root',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'usb-dwarf-dir-link-',
        );
        addTearDown(() => root.delete(recursive: true));
        final panorama = Directory(p.join(root.path, 'panorama'));
        final outside = Directory(p.join(root.path, 'outside'));
        await panorama.create();
        await outside.create();
        final externalPhoto = File(p.join(outside.path, 'escaped.jpg'));
        await externalPhoto.writeAsBytes(_jpegHeader(width: 400, height: 300));
        final junction = Link(p.join(panorama.path, '1'));
        await _createLinkOrSkip(
          junction,
          outside.path,
          'directory symlink/junction',
        );

        final service = UsbDwarfImportService(
          supportDirectory: () => Directory(p.join(root.path, 'support')),
        );
        expect(
          await service.selectMaximumPhotos(panorama.path),
          isEmpty,
          reason:
              'One-level numeric copies must not follow a directory reparse point',
        );
        expect(await externalPhoto.exists(), isTrue);
        expect(await service.loadImportedIdentities(), isEmpty);
      },
    );
  });
}

Future<void> _createLinkOrSkip(
  Link link,
  String target,
  String description,
) async {
  try {
    await link.create(target);
  } on FileSystemException catch (error) {
    final code = error.osError?.errorCode;
    final permissionDenied =
        code == 5 ||
        code == 1314 ||
        code == 1 ||
        error.message.toLowerCase().contains('privilege') ||
        error.message.toLowerCase().contains('permission');
    if (Platform.isWindows && permissionDenied) {
      markTestSkipped(
        'SKIPPED $description: Windows denied link creation ($error)',
      );
    }
    rethrow;
  }
}

List<int> _jpegHeader({
  required int width,
  required int height,
  int padding = 0,
}) => [
  0xff, 0xd8, // SOI
  0xff, 0xc0, 0x00, 0x0b, // baseline SOF, segment length
  0x08, height >> 8, height & 0xff, width >> 8, width & 0xff,
  0x01, 0x01, 0x11, 0x00,
  ...List<int>.filled(padding, 0x42),
];

Future<Directory> _duplicateNameFixture(
  Directory root,
  String name, {
  required bool createOneFirst,
}) async {
  final panorama = Directory(p.join(root.path, name));
  final one = Directory(p.join(panorama.path, '1'));
  final two = Directory(p.join(panorama.path, '2'));
  await panorama.create();
  if (createOneFirst) {
    await one.create();
    await two.create();
  } else {
    await two.create();
    await one.create();
  }
  final high = _jpegHeader(width: 640, height: 480, padding: 15);
  final low = _jpegHeader(width: 160, height: 120, padding: 3);
  final first = File(p.join(one.path, 'same.jpg'));
  final second = File(p.join(two.path, 'same.jpg'));
  await first.writeAsBytes(high);
  await second.writeAsBytes(low);
  await first.setLastModified(DateTime.utc(2024, 1, 1, 10));
  await second.setLastModified(DateTime.utc(2024, 1, 1, 11));
  return panorama;
}
