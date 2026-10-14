import 'package:cash/data/store.dart';
import 'package:cash/main.dart';
import 'package:cash/sync/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('первый запуск и перенос данных из таблицы', (tester) async {
    final store = Store.inMemory();
    final sync = SyncService(store); // без запуска сети
    await tester.pumpWidget(CashApp(store: store, sync: sync));
    await tester.pumpAndSettle();

    expect(find.text('Учёт финансов'), findsOneWidget);
    await tester.tap(find.text('Перенести данные из таблицы'));
    await tester.pumpAndSettle();

    expect(store.periods.length, 1);
    expect(find.text('Потрачено'), findsWidgets);

    // Переход по вкладкам не падает.
    for (final tab in ['Кредиты', 'Период', 'Коммуналка', 'Синхронизация', 'Бюджет']) {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
      await tester.pumpAndSettle();
    }

    // Вкладка «Коммуналка»: показания из таблицы на месте.
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Коммуналка')));
    await tester.pumpAndSettle();
    expect(store.meterReadings.length, 10);
    expect(find.text('Сумма по умолчанию'), findsOneWidget);
    expect(find.byType(Scaffold), findsWidgets);

    // Сбрасываем таймер отложенного сохранения.
    await tester.pump(const Duration(seconds: 1));
  });
}
