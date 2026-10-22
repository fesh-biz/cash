import 'package:cash/data/models.dart';
import 'package:cash/data/record.dart';
import 'package:cash/data/store.dart';
import 'package:cash/logic/budget.dart';
import 'package:cash/logic/utilities.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sample_data.dart';

/// Значения задаёт пользователь: ничего не подставляется заранее;
/// доход — в любой валюте.
void main() {
  test('новая установка: тарифы, сумма и день показаний не заданы', () {
    final store = Store.inMemory();
    final c = store.utilityConfig;
    expect(c.tariffs.isEmpty, isTrue);
    expect(c.plan, isNull);
    expect(c.meterDay, isNull);
    expect(store.periods, isEmpty);
    expect(store.meterReadings, isEmpty);
  });

  test('новый период — только то, что ввёл пользователь', () {
    final store = Store.inMemory();
    final p = store.createPeriod(
      start: DateTime(2026, 11, 1),
      end: DateTime(2026, 11, 30),
      income: 30000,
      currency: 'UAH',
    );
    expect(store.fixedOf(p.id), isEmpty);
    expect(store.creditsOf(p.id), isEmpty);
    final back = store.periodById(p.id)!;
    expect(back.currency, 'UAH');
    expect(back.incomeUah, 30000, reason: 'гривна не пересчитывается, курс не нужен');
    final s = PeriodSummary.compute(back, store.fixedOf(p.id), const [], DateTime(2026, 11, 5));
    expect(s.perDay, 1000);
    expect(store.utilityStatus(back).dueDate, isNull, reason: 'день показаний не задан');
  });

  test('доход в долларах пересчитывается по курсу, валюта переходит в следующий период', () {
    final store = Store.inMemory();
    final p = store.createPeriod(
      start: DateTime(2026, 11, 1),
      end: DateTime(2026, 11, 30),
      income: 1000,
      currency: 'USD',
      rate: 41.5,
      creditPlan: 500,
    );
    expect(store.periodById(p.id)!.incomeUah, 41500);
    final next = store.createNextPeriod(store.periodById(p.id)!);
    expect(next.currency, 'USD');
    expect(next.income, 1000);
    expect(next.rate, 41.5);
    expect(next.creditPlan, 500);
    expect(store.overlapping(DateTime(2026, 11, 20), DateTime(2026, 12, 5)).length, 2);
  });

  test('периоды старых версий: доход в евро', () {
    final r = SyncRecord(id: 'p', type: RecType.period, hlc: '', data: {
      'start': '2026-10-10',
      'end': '2026-11-09',
      'rate': 51,
      'incomeEur': 740,
      'creditPlan': 10000,
    });
    final p = Period.fromRecord(r)!;
    expect(p.currency, 'EUR');
    expect(p.income, 740);
    expect(p.incomeUah, 37740);
    // Евро по-прежнему понятны старым версиям.
    expect(p.toData()['incomeEur'], 740);
    expect(p.copyWith(currency: 'UAH').toData().containsKey('incomeEur'), isFalse);
  });

  test('старые данные без настроек: тарифы и день — из последних показаний', () {
    final store = Store.inMemory();
    loadSample(store);
    final c = store.utilityConfig;
    expect(c.tariffs.sameAs(tableTariffs), isTrue);
    expect(c.meterDay, 28);
    // После сохранения настроек значения записаны явно.
    store.saveUtilityConfig(c.copyWith(plan: 2000));
    final saved = UtilityConfig.fromRecord(
      SyncRecord(id: UtilityConfig.id, type: RecType.utilConfig, hlc: '', data: store.utilityConfig.toData()),
    );
    expect(saved.meterDay, 28);
    expect(saved.tariffs.sameAs(tableTariffs), isTrue);
  });

  test('день показаний: свой день и последний день короткого месяца', () {
    final store = Store.inMemory();
    final p = store.createPeriod(start: DateTime(2027, 2, 1), end: DateTime(2027, 2, 28), income: 1, currency: 'UAH');
    expect(meterDateIn(p, 15), DateTime(2027, 2, 15));
    expect(meterDateIn(p, 31), DateTime(2027, 2, 28));
    expect(meterDateIn(p, null), isNull);
    store.saveUtilityConfig(store.utilityConfig.copyWith(meterDay: 5));
    expect(store.utilityStatus(p).dueDate, DateTime(2027, 2, 5));
  });
}
