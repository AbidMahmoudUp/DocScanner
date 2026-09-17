import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'data/local/app_database.dart';
import 'data/local/file_storage.dart';
import 'data/repositories/document_repository.dart';
import 'services/cv/cv_worker.dart';
import 'services/export/export_service.dart';
import 'services/import/image_import_service.dart';
import 'viewmodels/library_viewmodel.dart';
import 'viewmodels/scan_session_viewmodel.dart';
import 'viewmodels/settings_viewmodel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    // The crop editor and the camera overlay both assume a portrait frame.
    DeviceOrientation.portraitUp,
  ]);

  final database = await AppDatabase.open();
  final storage = await FileStorage.create();
  // Raw captures from a session that was killed mid-scan are dead weight.
  await storage.clearStaleCaptures();
  final worker = await CvWorker.spawn();

  final repository = DocumentRepository(
    database: database,
    storage: storage,
    worker: worker,
  );

  runApp(
    MultiProvider(
      providers: [
        Provider<FileStorage>.value(value: storage),
        Provider<CvWorker>.value(value: worker),
        Provider<DocumentRepository>.value(value: repository),
        Provider<ExportService>(create: (_) => ExportService(storage)),
        Provider<ImageImportService>(create: (_) => ImageImportService(storage)),
        ChangeNotifierProvider(create: (_) => SettingsViewModel()),
        ChangeNotifierProvider(
          create: (_) => LibraryViewModel(repository)..load(),
        ),
        ChangeNotifierProvider(
          create: (_) => ScanSessionViewModel(repository: repository, storage: storage),
        ),
      ],
      child: const DocScannerApp(),
    ),
  );
}
