import 'package:cash/data/store.dart';
import 'package:cash/logic/budget.dart';
import 'package:cash/util/format.dart';
import 'package:flutter_test/flutter_test.dart';

/// Проверяем, что расчёты совпадают с исходной таблицей (table.jpg).
void main() {
  late Store store;
  late PeriodSummary s;

  PeriodSummary summaryAt(DateTime now) {
    final p = store.periods.single;
    return PeriodSummary.compute(p, store.fixedOf(p.id), store.expensesBetween(p.start, p.end), now);
  }

  setUp(() {
    store = Store.inMemory();
    store.loadSample();
    s = summaryAt(DateTime(2026, 10, 13, 12));
  });

  test('шапка таблицы: курс, гривны, остаток, в день', () {
    final p = s.period;
    expect(p.days, 31);
    expect(p.incomeUah, 37740);
    expect(s.fixedTotal, 14000);
    expect(s.available, 13740);
    expect(s.perDay.round(), 443);
    expect(s.spent, 4250);
    expect(s.left, 9490);
  });

  test('столбец «Остаток» по дням', () {
    final expected = <int, int>{
      10: -1057, 11: -1114, 12: -1170, 13: -2477, 14: -2034, 15: -1591, 16: -1147,
      17: -704, 18: -261, 19: 182, 20: 625, 21: 1069, 22: 1512, 23: 1955, 24: 2398,
      25: 2842, 26: 3285, 27: 3728, 28: 4171, 29: 4615, 30: 5058, 31: 5501,
    };
    for (final r in s.rows.where((r) => r.date.month == 10)) {
      expect(r.balance.round(), expected[r.date.day], reason: 'день ${r.date.day}');
    }
    final nov = {1: 5944, 2: 6387, 3: 6831, 4: 7274, 5: 7717, 6: 8160, 7: 8604, 8: 9047, 9: 9490};
    for (final r in s.rows.where((r) => r.date.month == 11)) {
      expect(r.balance.round(), nov[r.date.day], reason: 'ноябрь ${r.date.day}');
    }
  });

  test('сегодня, выход в плюс и лимит с учётом трат', () {
    expect(s.state, PeriodState.active);
    expect(s.todayBalance.round(), -2477);
    expect(s.backToPlusDate, DateTime(2026, 10, 19));
    expect(s.daysToPlus, 6);
    expect(s.daysLeft, 28);
    // (13740 − 2500 потрачено до 13-го) / 28 дней
    expect(s.perDayFromToday.round(), 401);
  });

  test('кредиты из таблицы', () {
    final p = s.period;
    final due = store.creditsOf(p.id).fold<double>(0, (a, c) => a + c.amount);
    final paid = store.depositsOf(p.id).fold<double>(0, (a, d) => a + d.amount);
    expect(due, 3856);
    expect(paid, 8000);
    expect(paid - due, 4144);
    expect(p.creditPlan, 10000);
  });

  test('следующий период копирует настройки', () {
    final p = store.periods.single;
    final next = store.createNextPeriod(p);
    expect(next.start, DateTime(2026, 11, 10));
    expect(next.end, DateTime(2026, 12, 9));
    expect(store.fixedOf(next.id).length, 2);
    expect(store.creditsOf(next.id).length, 4);
    expect(store.depositsOf(next.id), isEmpty);
  });

  test('разбор сумм', () {
    expect(parseAmount('1500'), 1500);
    expect(parseAmount('1 500,50'), 1500.5);
    expect(parseAmount('500+250-30'), 720);
    expect(parseAmount('abc'), isNull);
    expect(parseAmount('5..'), isNull);
    expect(money(-2477.2), '−2 477 ₴');
  });
}
