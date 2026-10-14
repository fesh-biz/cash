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
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2E7D32),
      brightness: brightness,
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
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru'), Locale('uk'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const HomeShell(),
      ),
    );
  }
}
