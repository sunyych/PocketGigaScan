import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/services/usb_dwarf_import_service.dart';

void main() {
  group('USB DWARF discovery', () {
    test(
      'prefers removable Panorarma source and pins it across remounts',
      () async {
        final root = await Directory.systemTemp.createTemp('usb-discovery-');
        addTearDown(() => root.delete(recursive: true));
        final fixed = Directory(p.join(root.path, 'D'));
        final removable = Directory(p.join(root.path, 'G'));
        final remounted = Directory(p.join(root.path, 'H'));
        await _addPanorama(fixed, 'DWARF_PANORAMA_2026-10-23-14-01-48-371');
        await _addPanorama(removable, 'DWARF_PANORAMA_2026-10-23-14-01-48-371');
        await _addPanorama(remounted, 'DWARF_PANORAMA_2026-10-23-14-01-48-371');
        final support = Directory(p.join(root.path, 'support'));

        Future<List<Directory>> roots = Future.value([fixed, removable]);
        String volumeFor(String path) => switch (p.basename(path)) {
          'D' => 'fixed-volume',
          'G' || 'H' => 'camera-volume-guid',
          _ => 'unknown',
        };
        final initial = UsbDwarfImportService(
          supportDirectory: () => support,
          mountRoots: () => roots,
          volumeIdentity: (path) async => volumeFor(path),
          removableCheck: (path) async => p.basename(path) != 'D',
        );

        final first = await initial.discover();
        expect(first, hasLength(1));
        expect(first.single.volumeId, 'camera-volume-guid');
        expect(first.single.directory, contains('Panorarma'));
        final firstIdentity = first.single.identity;

        // Once selected, the fixed-drive duplicate must not become the default
        // when the camera is disconnected.
        roots = Future.value([fixed]);
        final disconnected = UsbDwarfImportService(
          supportDirectory: () => support,
          mountRoots: () => roots,
          volumeIdentity: (path) async => volumeFor(path),
          removableCheck: (path) async => false,
        );
        expect(await disconnected.discover(), isEmpty);

        // A new drive letter with the same volume identity is the same source.
        roots = Future.value([remounted]);
        final reconnected = UsbDwarfImportService(
          supportDirectory: () => support,
          mountRoots: () => roots,
          volumeIdentity: (path) async => volumeFor(path),
          removableCheck: (path) async => true,
        );
        final afterRemount = await reconnected.discover();
        expect(afterRemount, hasLength(1));
        expect(afterRemount.single.identity, firstIdentity);
      },
    );
  });
}

Future<void> _addPanorama(Directory volume, String name) async {
  final root = Directory(p.join(volume.path, 'Panorarma'));
  await Directory(p.join(root.path, name)).create(recursive: true);
}
