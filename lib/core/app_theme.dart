import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ScanFlow design tokens — indigo primary, amber shutter accent.
/// Kept in one place so both themes stay in sync with the prototype.
abstract final class AppColors {
  static const primaryDark = Color(0xFF5B6BFF);
  static const primaryLight = Color(0xFF4351E8);
  static const shutter = Color(0xFFFFB547);

  static const bgDark = Color(0xFF0A0E1A);
  static const surfDark = Color(0xFF11162A);
  static const surf2Dark = Color(0xFF1A2140);
  static const surf3Dark = Color(0xFF2A3250);
  static const lineDark = Color(0xFF3D4670);
  static const fgDark = Color(0xFFF2F1ED);
  static const fg2Dark = Color(0xFFA8AEC4);
  static const fg3Dark = Color(0xFF6E7596);
  static const errorDark = Color(0xFFFF5BA3);
  static const errorContainerDark = Color(0xFF3D1226);
  static const onErrorContainerDark = Color(0xFFFFC2DA);

  static const bgLight = Color(0xFFF2F1ED);
  static const surfLight = Color(0xFFFFFFFF);
  static const surf2Light = Color(0xFFE8E7E2);
  static const surf3Light = Color(0xFFDEDDD7);
  static const lineLight = Color(0xFFD4D3CD);
  static const fgLight = Color(0xFF0A0E1A);
  static const fg2Light = Color(0xFF3D4252);
  static const fg3Light = Color(0xFF6B7185);
  static const errorLight = Color(0xFFC42C74);
  static const errorContainerLight = Color(0xFFFFDDEC);
  static const onErrorContainerLight = Color(0xFF5C0B33);

  /// Camera chrome is always dark, regardless of the app theme.
  static const cameraBg = Color(0xFF07090F);
}

/// Extra roles Material's [ColorScheme] has no slot for.
@immutable
class AppTones extends ThemeExtension<AppTones> {
  const AppTones({
    required this.shutter,
    required this.fg2,
    required this.fg3,
    required this.line,
    required this.surf2,
    required this.surf3,
  });

  final Color shutter;
  final Color fg2;
  final Color fg3;
  final Color line;
  final Color surf2;
  final Color surf3;

  @override
  AppTones copyWith({
    Color? shutter,
    Color? fg2,
    Color? fg3,
    Color? line,
    Color? surf2,
    Color? surf3,
  }) => AppTones(
    shutter: shutter ?? this.shutter,
    fg2: fg2 ?? this.fg2,
    fg3: fg3 ?? this.fg3,
    line: line ?? this.line,
    surf2: surf2 ?? this.surf2,
    surf3: surf3 ?? this.surf3,
  );

  @override
  AppTones lerp(covariant AppTones? other, double t) {
    if (other == null) return this;
    return AppTones(
      shutter: Color.lerp(shutter, other.shutter, t)!,
      fg2: Color.lerp(fg2, other.fg2, t)!,
      fg3: Color.lerp(fg3, other.fg3, t)!,
      line: Color.lerp(line, other.line, t)!,
      surf2: Color.lerp(surf2, other.surf2, t)!,
      surf3: Color.lerp(surf3, other.surf3, t)!,
    );
  }
}

extension AppThemeX on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  AppTones get tones => Theme.of(this).extension<AppTones>()!;
  TextTheme get texts => Theme.of(this).textTheme;
}

abstract final class AppTheme {
  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    scheme: const ColorScheme.dark(
      primary: AppColors.primaryDark,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFF232E78),
      onPrimaryContainer: Color(0xFFC9CEFF),
      // Chips, segmented buttons and filter selections read from the
      // secondary roles. Left at Material's defaults they come out teal,
      // which fights the indigo the rest of the app is built on.
      secondary: AppColors.primaryDark,
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFF232E78),
      onSecondaryContainer: Color(0xFFC9CEFF),
      tertiary: AppColors.shutter,
      onTertiary: Color(0xFF2A1B02),
      surface: AppColors.bgDark,
      onSurface: AppColors.fgDark,
      surfaceContainer: AppColors.surfDark,
      surfaceContainerHigh: AppColors.surf3Dark,
      outline: AppColors.lineDark,
      error: AppColors.errorDark,
      onError: Color(0xFF2A0A17),
      errorContainer: AppColors.errorContainerDark,
      onErrorContainer: AppColors.onErrorContainerDark,
    ),
    tones: const AppTones(
      shutter: AppColors.shutter,
      fg2: AppColors.fg2Dark,
      fg3: AppColors.fg3Dark,
      line: AppColors.lineDark,
      surf2: AppColors.surf2Dark,
      surf3: AppColors.surf3Dark,
    ),
  );

  static ThemeData light() => _build(
    brightness: Brightness.light,
    scheme: const ColorScheme.light(
      primary: AppColors.primaryLight,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFDFE2FF),
      onPrimaryContainer: Color(0xFF1B2372),
      secondary: AppColors.primaryLight,
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFDFE2FF),
      onSecondaryContainer: Color(0xFF1B2372),
      tertiary: AppColors.shutter,
      onTertiary: Color(0xFF2A1B02),
      surface: AppColors.bgLight,
      onSurface: AppColors.fgLight,
      surfaceContainer: AppColors.surfLight,
      surfaceContainerHigh: AppColors.surf3Light,
      outline: AppColors.lineLight,
      error: AppColors.errorLight,
      onError: Colors.white,
      errorContainer: AppColors.errorContainerLight,
      onErrorContainer: AppColors.onErrorContainerLight,
    ),
    tones: const AppTones(
      shutter: AppColors.shutter,
      fg2: AppColors.fg2Light,
      fg3: AppColors.fg3Light,
      line: AppColors.lineLight,
      surf2: AppColors.surf2Light,
      surf3: AppColors.surf3Light,
    ),
  );

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme scheme,
    required AppTones tones,
  }) {
    final base = ThemeData(brightness: brightness, colorScheme: scheme, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      extensions: [tones],
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tones.surf2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: tones.surf2,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
    );
  }
}
