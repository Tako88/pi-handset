// The launcher icon has no other gate. A missing density, a dangling
// adaptive-icon reference, art that spills outside the mask, or a splash window
// that flashes white are all invisible to flutter analyze and to every widget
// test: they only show up on a device, after install. These are file-level
// properties, so they are checked here instead.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// flutter test runs with cwd at the package root (app/).
const String _res = 'android/app/src/main/res';

/// Android's density bucket -> the px size a launcher icon must be.
const Map<String, int> _legacySizes = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

/// An adaptive icon's canvas is 108dp; the launcher shows the central 72dp and
/// only guarantees a 66dp circle. Art outside that is clipped.
const double _adaptiveCanvasDp = 108;
const double _safeZoneDp = 66;
const double _safeInsetDp = (_adaptiveCanvasDp - _safeZoneDp) / 2;
const double _safeMaxDp = _adaptiveCanvasDp - _safeInsetDp;

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'missing $path');
  return file.readAsStringSync();
}

/// The width/height from a PNG's IHDR chunk, so no image package is needed.
(int, int) _pngSize(String path) {
  final bytes = File(path).readAsBytesSync();
  final header = Uint8List.sublistView(bytes, 0, 24);
  expect(
    header.sublist(1, 4),
    orderedEquals(<int>[0x50, 0x4E, 0x47]), // "PNG"
    reason: '$path is not a PNG',
  );
  int be32(int i) =>
      (header[i] << 24) | (header[i + 1] << 16) | (header[i + 2] << 8) | header[i + 3];
  return (be32(16), be32(20));
}

void main() {
  // Both halves are required: minSdk is 24, so API 24-25 devices (and any
  // launcher that ignores the adaptive icon) fall back to the bitmap.
  for (final entry in _legacySizes.entries) {
    final density = entry.key;
    final px = entry.value;

    test('the $density legacy launcher icon is a square $px px bitmap', () {
      final (width, height) = _pngSize('$_res/mipmap-$density/ic_launcher.png');
      expect((width, height), (px, px));
    });

    test('the $density round launcher icon is a square $px px bitmap', () {
      final (width, height) = _pngSize('$_res/mipmap-$density/ic_launcher_round.png');
      expect((width, height), (px, px));
    });
  }

  test('the manifest asks for the round icon, not just the square one', () {
    final manifest = _read('android/app/src/main/AndroidManifest.xml');
    expect(
      manifest,
      contains('android:roundIcon="@mipmap/ic_launcher_round"'),
      reason: 'a launcher that draws a circle picks ic_launcher_round; without '
          'it the square bitmap gets masked instead',
    );
  });

  for (final name in const <String>['ic_launcher', 'ic_launcher_round']) {
    test('the $name adaptive icon references resources that exist', () {
      final xml = _read('$_res/mipmap-anydpi-v26/$name.xml');
      for (final ref in const <String>[
        '@drawable/ic_launcher_foreground',
        '@drawable/ic_launcher_monochrome',
        '@color/ic_launcher_background',
      ]) {
        expect(xml, contains(ref), reason: '$name.xml should reference $ref');
      }
      _read('$_res/drawable/ic_launcher_foreground.xml');
      _read('$_res/drawable/ic_launcher_monochrome.xml');
      expect(
        _read('$_res/values/colors.xml'),
        contains('ic_launcher_background'),
        reason: 'the adaptive icon names a colour resource that must exist',
      );
    });
  }

  for (final layer in const <String>[
    'drawable/ic_launcher_foreground.xml',
    'drawable/ic_launcher_monochrome.xml',
  ]) {
    final label = layer.split('/').last;
    test('$label draws inside the adaptive safe zone', () {
      final xml = _read('$_res/$layer');
      double attr(String name) {
        final match = RegExp('android:$name="([0-9.]+)"').firstMatch(xml);
        expect(match, isNotNull, reason: '$layer has no android:$name');
        return double.parse(match!.group(1)!);
      }

      final canvas = attr('viewportWidth');
      expect(canvas, attr('viewportHeight'), reason: 'the adaptive canvas is square');

      final pathData = RegExp('android:pathData="([^"]+)"').firstMatch(xml);
      expect(pathData, isNotNull, reason: '$layer has no path data');
      final numbers = RegExp(r'-?\d+(?:\.\d+)?')
          .allMatches(pathData!.group(1)!)
          .map((m) => double.parse(m.group(0)!))
          .toList();
      expect(numbers, isNotEmpty, reason: '$layer has no path data');

      // Cheaper and stricter than it looks: a curve's control points lie inside
      // the shape's convex hull, so checking every number checks the figure.
      double toDp(double v) => v / canvas * _adaptiveCanvasDp;
      final lowest = toDp(numbers.reduce((a, b) => a < b ? a : b));
      final highest = toDp(numbers.reduce((a, b) => a > b ? a : b));

      expect(
        lowest,
        greaterThanOrEqualTo(_safeInsetDp),
        reason: 'art reaches $lowest dp; the launcher may clip everything '
            'outside $_safeInsetDp..$_safeMaxDp dp',
      );
      expect(
        highest,
        lessThanOrEqualTo(_safeMaxDp),
        reason: 'art reaches $highest dp; the launcher may clip everything '
            'outside $_safeInsetDp..$_safeMaxDp dp',
      );
      expect(
        highest - lowest,
        greaterThan(_safeZoneDp * 0.4),
        reason: 'art is too small to read once the launcher has masked it',
      );
    });
  }

  test('the cold-start window is not a white flash', () {
    for (final path in const <String>[
      '$_res/drawable/launch_background.xml',
      '$_res/drawable-v21/launch_background.xml',
    ]) {
      final xml = _read(path);
      expect(
        xml,
        isNot(contains('@android:color/white')),
        reason: '$path starts a dark app on a hardcoded white window',
      );
      expect(
        xml,
        isNot(contains('?android:')),
        reason: '$path leans on a platform default, which is white under '
            'Theme.Light.NoTitleBar',
      );
      expect(
        xml,
        contains('@color/pi_page_bg'),
        reason: '$path should paint the app background',
      );
    }
  });

  test('the night start-up theme is a dark platform theme', () {
    // A Light parent on a night device hands the platform's light window and
    // status-bar attributes to exactly the devices that are dark.
    for (final path in const <String>[
      '$_res/values-night/styles.xml',
      '$_res/values-night-v31/styles.xml',
    ]) {
      final xml = _read(path);
      expect(xml, contains('Theme.Black.NoTitleBar'), reason: path);
      expect(xml, isNot(contains('Theme.Light')), reason: path);
    }
  });

  test('Android 12+ is told which background to start on', () {
    // Android 12 ignores android:windowBackground while the splash is up; it
    // reads windowSplashScreenBackground, which defaults to the theme's
    // colorBackground - white, under Theme.Light.NoTitleBar.
    final v31 = _read('$_res/values-v31/styles.xml');
    expect(v31, contains('windowSplashScreenBackground'));
    expect(v31, contains('@color/pi_page_bg'));
    expect(_read('$_res/values-night-v31/styles.xml'), contains('@color/pi_page_bg'));
    expect(_read('$_res/values/colors.xml'), contains('pi_page_bg'));
  });
}
