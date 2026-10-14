import 'package:flutter/widgets.dart';

import '../data/store.dart';
import '../sync/sync_service.dart';

/// Даёт доступ к хранилищу и синхронизации из любого виджета.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.store, required this.sync, required super.child});

  final Store store;
  final SyncService sync;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope не найден');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => store != oldWidget.store || sync != oldWidget.sync;
}
