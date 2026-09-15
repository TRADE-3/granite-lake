import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'core/services/time_sync_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait — forensic capture apps operate in portrait only.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Use a neutral status bar default; themed app bars override per theme.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarBrightness: Brightness.dark,
    ),
  );

  // Must run before anything reads TimeSyncService.nowUtc() — never throws,
  // even with no connectivity on a first cold launch (see the class doc).
  await TimeSyncService.initializeAtStartup();

  runApp(const GraniteLakeApp());
}
