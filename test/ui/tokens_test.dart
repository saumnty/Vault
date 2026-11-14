import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/theme/app_colors.dart';
import 'package:vault/core/theme/app_spacing.dart';

/// Archivos de UI (todo lib/ salvo el sistema de diseño).
List<File> _uiFiles() {
  final files = <File>[File('lib/main.dart')];
  for (final dir in ['lib/features', 'lib/shared']) {
    files.addAll(
      Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
    );
  }
  return files;
}

String _relative(File f) => f.path.replaceAll(r'\', '/');

double _luminance(Color c) => c.computeLuminance();

double _contrast(Color a, Color b) {
  final l1 = math.max(_luminance(a), _luminance(b));
  final l2 = math.min(_luminance(a), _luminance(b));
  return (l1 + 0.05) / (l2 + 0.05);
}

void main() {
  group('Tokens: nada hardcodeado fuera de lib/core/theme', () {
    final rules = <String, RegExp>{
      'Color(0x...)': RegExp(r'Color\(\s*0x'),
      'Colors.<algo> (salvo transparent)': RegExp(
        r'\bColors\.(?!transparent\b)\w+',
      ),
      'CupertinoColors.': RegExp(r'CupertinoColors\.'),
      'fontSize literal': RegExp(r'fontSize\s*:'),
      'EdgeInsets con número literal': RegExp(
        r'EdgeInsets\.(all|symmetric|only|fromLTRB)\([^)]*\b[1-9]\d*(\.\d+)?\b',
      ),
      'BorderRadius.circular(número)': RegExp(r'BorderRadius\.circular\(\s*\d'),
      'Radius.circular(número)': RegExp(r'Radius\.circular\(\s*\d'),
      'SizedBox con tamaño numérico': RegExp(
        r'SizedBox\((width|height)\s*:\s*\d',
      ),
    };

    for (final rule in rules.entries) {
      test('sin ${rule.key}', () {
        final offenders = <String>[];
        for (final file in _uiFiles()) {
          final lines = file.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            final line = lines[i];
            if (line.trimLeft().startsWith('//')) continue;
            if (rule.value.hasMatch(line)) {
              offenders.add('${_relative(file)}:${i + 1}: ${line.trim()}');
            }
          }
        }
        expect(offenders, isEmpty, reason: offenders.join('\n'));
      });
    }

    test('el detector funciona (canario)', () {
      expect(
        rules['Color(0x...)']!.hasMatch('const Color(0xFF000000)'),
        isTrue,
      );
      expect(
        rules['fontSize literal']!.hasMatch('TextStyle(fontSize: 14)'),
        isTrue,
      );
      expect(
        rules['Colors.<algo> (salvo transparent)']!.hasMatch('Colors.red'),
        isTrue,
      );
      expect(
        rules['Colors.<algo> (salvo transparent)']!.hasMatch(
          'Colors.transparent',
        ),
        isFalse,
      );
    });
  });

  group('Contraste (WCAG)', () {
    test('texto principal y secundario sobre el fondo >= 4.5:1', () {
      expect(_contrast(AppColors.textPrimary, AppColors.background), ge(4.5));
      expect(_contrast(AppColors.textSecondary, AppColors.background), ge(4.5));
      expect(_contrast(AppColors.textSecondary, AppColors.surface), ge(4.5));
    });

    test('texto de acento claro sobre fondo y superficies >= 4.5:1', () {
      expect(_contrast(AppColors.accentLight, AppColors.background), ge(4.5));
      expect(_contrast(AppColors.accentLight, AppColors.surface), ge(4.5));
    });

    test('texto blanco sobre botones (acento y peligro) >= 4.5:1', () {
      expect(_contrast(AppColors.onAccent, AppColors.accent), ge(4.5));
      expect(_contrast(AppColors.onAccent, AppColors.dangerFill), ge(4.5));
    });

    test('colores semánticos legibles sobre el fondo >= 3:1 (íconos)', () {
      for (final c in [
        AppColors.success,
        AppColors.warning,
        AppColors.danger,
        AppColors.info,
      ]) {
        expect(_contrast(c, AppColors.background), ge(3));
      }
    });

    test('identidad: fondo OLED y acento morado', () {
      expect(AppColors.background, const Color(0xFF0B0B0E));
      expect(AppColors.accent, const Color(0xFF7C3AED));
    });
  });

  test('área táctil mínima es 44', () {
    expect(AppSizes.minTouch, 44);
    expect(AppSizes.keypadKey, greaterThanOrEqualTo(44));
    expect(AppSizes.fabMini, greaterThanOrEqualTo(44));
  });
}

Matcher ge(num n) => greaterThanOrEqualTo(n);
