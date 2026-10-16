import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/store.dart';
import 'sync/sync_service.dart';
import 'ui/app_scope.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.open();
  final sync = SyncService(store);
  unawaited(sync.start());
  runApp(CashApp(store: store, sync: sync));
}

class CashApp extends StatefulWidget {
  const CashApp({super.key, required this.store, required this.sync});

  final Store store;
  final SyncService sync;

  @override
  State<CashApp> createState() => _CashAppState();
}

class _CashAppState extends State<CashApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => widget.sync.onResume(),
      onInactive: () => widget.store.flush(),
      onPause: () => widget.store.flush(),
      onExitRequested: () async {
        await widget.store.flush();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    // Остальные оттенки (фон, поверхности, рамки) выводятся из основного голубого.
    final base = ColorScheme.fromSeed(
      seedColor: _Blue.c6,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    final scheme = dark
        ? base.copyWith(
            primary: _Blue.c9,
            onPrimary: _Blue.c1,
            primaryContainer: _Blue.c4,
            onPrimaryContainer: _Blue.c10,
            secondary: _Blue.c8,
            onSecondary: _Blue.c1,
            secondaryContainer: _Blue.c5,
            onSecondaryContainer: const Color(0xFFE3F2F7),
            tertiary: _Blue.c10,
            onTertiary: _Blue.c1,
            tertiaryContainer: _Blue.c2,
            onTertiaryContainer: _Blue.c10,
          )
        : base.copyWith(
            primary: _Blue.c3,
            onPrimary: Colors.white,
            primaryContainer: _Blue.c10,
            onPrimaryContainer: _Blue.c1,
            secondary: _Blue.c6,
            onSecondary: Colors.white,
            secondaryContainer: _Blue.c9,
            onSecondaryContainer: _Blue.c1,
            tertiary: _Blue.c5,
            onTertiary: Colors.white,
            tertiaryContainer: _Blue.c8,
            onTertiaryContainer: _Blue.c1,
          );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      store: widget.store,
      sync: widget.sync,
      child: MaterialApp(
        title: 'Cash',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ThemeMode.system,
        locale: const Locale('uk'),
        supportedLocales: const [Locale('ru'), Locale('uk'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const HomeShell(),
      ),
    );
  }
}

/// Палитра приложения: от тёмно-синего к светло-голубому.
abstract final class _Blue {
  static const c1 = Color(0xFF012A4A);
  static const c2 = Color(0xFF013A63);
  static const c3 = Color(0xFF01497C);
  static const c4 = Color(0xFF014F86);
  static const c5 = Color(0xFF2A6F97);
  static const c6 = Color(0xFF2C7DA0);
  static const c7 = Color(0xFF468FAF);
  static const c8 = Color(0xFF61A5C2);
  static const c9 = Color(0xFF89C2D9);
  static const c10 = Color(0xFFA9D6E5);
}
