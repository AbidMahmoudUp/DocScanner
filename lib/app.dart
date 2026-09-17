import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_theme.dart';
import 'viewmodels/settings_viewmodel.dart';
import 'views/home/home_view.dart';

class DocScannerApp extends StatelessWidget {
  const DocScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.select<SettingsViewModel, ThemeMode>((s) => s.themeMode);
    return MaterialApp(
      title: 'ScanFlow',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: const HomeView(),
    );
  }
}
