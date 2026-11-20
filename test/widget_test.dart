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

    expect(find.text('Учёт финансов'), findsOneWidget);
    expect(find.text('Перенести данные из таблицы'), findsNothing);
    await tester.tap(find.text('Создать первый период'));
    await tester.pumpAndSettle();

    expect(find.text('Новый период'), findsOneWidget);
    expect(find.text('Выбрать даты'), findsOneWidget);
    FilledButton create() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Создать'));
    expect(create().onPressed, isNull, reason: 'без дат, валюты и дохода создать нельзя');

    // Курс нужен только для иностранной валюты.
    await tester.tap(find.text('€ EUR'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Курс, ₴ за 1 €'), findsOneWidget);
    await tester.tap(find.text('₴ UAH'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Курс, ₴ за 1 ₴'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Доход за период'), '30000');
    await tester.pumpAndSettle();
    expect(create().onPressed, isNull, reason: 'даты ещё не выбраны');

    await tester.tap(find.text('Отмена').last);
    await tester.pumpAndSettle();
    expect(store.periods, isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('вкладки с данными открываются', (tester) async {
    final store = Store.inMemory();
    loadSample(store);
    final sync = SyncService(store);
    await tester.pumpWidget(CashApp(store: store, sync: sync));
    await tester.pumpAndSettle();
    expect(find.text('Потрачено'), findsWidgets);

    // Переход по вкладкам не падает.
    for (final tab in ['Кредиты', 'Период', 'Коммуналка', 'Синхронизация', 'Бюджет']) {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.byTooltip(tab)));
      await tester.pumpAndSettle();
      // Название вкладки — в заголовке страницы.
      expect(find.descendant(of: find.byType(AppBar), matching: find.text(tab)), findsOneWidget);
    }

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.byTooltip('Период')));
    await tester.pumpAndSettle();
    expect(find.text('Евро (EUR)'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.byTooltip('Коммуналка')));
    await tester.pumpAndSettle();
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('28-го'), findsOneWidget);

    // Сбрасываем таймер отложенного сохранения.
    await tester.pump(const Duration(seconds: 1));
  });
}
