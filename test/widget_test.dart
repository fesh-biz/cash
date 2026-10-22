import 'package:cash/data/store.dart';
import 'package:cash/main.dart';
import 'package:cash/sync/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sample_data.dart';

void main() {
  testWidgets('первый запуск: форма периода ничего не подставляет', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.inMemory();
    final sync = SyncService(store); // без запуска сети
    await tester.pumpWidget(CashApp(store: store, sync: sync));
    await tester.pumpAndSettle();

    expect(find.text('Облік фінансів'), findsOneWidget);
    expect(find.text('Перенести дані з таблиці'), findsNothing);
    await tester.tap(find.text('Створити перший період'));
    await tester.pumpAndSettle();

    expect(find.text('Новий період'), findsOneWidget);
    expect(find.text('Обрати дати'), findsOneWidget);
    FilledButton create() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Створити'));
    expect(create().onPressed, isNull, reason: 'без дат, валюти й доходу створити не можна');

    // Курс потрібен лише для іноземної валюти.
    await tester.tap(find.text('€ EUR'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Курс, ₴ за 1 €'), findsOneWidget);
    await tester.tap(find.text('₴ UAH'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Курс, ₴ за 1 ₴'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Дохід за період'), '30000');
    await tester.pumpAndSettle();
    expect(create().onPressed, isNull, reason: 'дати ще не обрано');

    await tester.tap(find.text('Скасувати').last);
    await tester.pumpAndSettle();
    expect(store.periods, isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('вкладки з даними відкриваються', (tester) async {
    final store = Store.inMemory();
    loadSample(store);
    final sync = SyncService(store);
    await tester.pumpWidget(CashApp(store: store, sync: sync));
    await tester.pumpAndSettle();
    expect(find.text('Витрачено'), findsWidgets);

    // Переход по вкладкам не падает.
    for (final tab in ['Кредити', 'Період', 'Комуналка', 'Синхронізація', 'Бюджет']) {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.byTooltip(tab)));
      await tester.pumpAndSettle();
      // Название вкладки — в заголовке страницы.
      expect(find.descendant(of: find.byType(AppBar), matching: find.text(tab)), findsOneWidget);
    }

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.byTooltip('Період')));
    await tester.pumpAndSettle();
    expect(find.text('Євро (EUR)'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.byTooltip('Комуналка')));
    await tester.pumpAndSettle();
    expect(find.text('Налаштування'), findsOneWidget);
    expect(find.text('28-го'), findsOneWidget);

    // Сбрасываем таймер отложенного сохранения.
    await tester.pump(const Duration(seconds: 1));
  });
}
