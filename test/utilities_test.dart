import 'package:cash/data/models.dart';
import 'package:cash/data/store.dart';
import 'package:cash/logic/budget.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sample_data.dart';

/// Коммуналка: расчёт совпадает с таблицей счётчиков, план → факт по показаниям.
void main() {
  late Store store;

  setUp(() {
    store = Store.inMemory();
    loadSample(store); // период 10.10–09.11.2026 + показания 12.2025–09.2026
  });

  Period oct() => store.periods.single;

  double fixedTotal(Period p) => PeriodSummary.compute(
        p,
        store.fixedOf(p.id),
        store.expensesBetween(p.start, p.end),
        DateTime(2026, 10, 14),
      ).fixedTotal;

  test('суммы за 2026 год совпадают с таблицей (столбцы H, I, K)', () {
    // месяц: (за воду, за эл, сумма)
    const expected = {
      1: (145.98, 1896.48, 5282.46),
      2: (336.18, 1101.6, 4637.78),
      3: (241.08, 1062.72, 3203.8),
      4: (431.28, 1740.96, 2872.24),
      5: (336.18, 1693.44, 2729.62),
      6: (241.08, 1153.44, 2094.52),
      7: (336.18, 1036.8, 2072.98),
      8: (431.28, 1170.72, 2302.0),
      9: (241.08, 1123.2, 2064.28),
    };
    final readings = store.meterReadings;
    expect(readings.length, 10);
    expect(store.billFor(readings.first), isNull, reason: 'декабрь 2025 — только база');
    for (final m in readings.skip(1)) {
      final b = store.billFor(m)!;
      final e = expected[m.date.month]!;
      expect(m.date.year, 2026);
      expect(b.water, closeTo(e.$1, 0.001), reason: 'вода, месяц ${m.date.month}');
      expect(b.electricity, closeTo(e.$2, 0.001), reason: 'свет, месяц ${m.date.month}');
      expect(b.total, closeTo(e.$3, 0.001), reason: 'сумма, месяц ${m.date.month}');
    }
  });

  test('до показаний в периоде стоит план, после — факт', () {
    final p = oct();
    var s = store.utilityStatus(p);
    expect(s.isActual, isFalse);
    expect(s.dueDate, DateTime(2026, 10, 28));
    expect(s.amount, 4000); // план ещё не задан — сумма из самого периода
    expect(fixedTotal(p), 14000);

    store.saveUtilityConfig(store.utilityConfig.copyWith(plan: 2000));
    expect(store.utilityStatus(p).amount, 2000);
    expect(fixedTotal(p), 12000);

    expect(store.utilityStatus(p).isDue(DateTime(2026, 10, 27, 20)), isFalse);
    expect(store.utilityStatus(p).isDue(DateTime(2026, 10, 28, 9)), isTrue);

    store.saveReading(MeterReading(
      date: DateTime(2026, 10, 28),
      bath: 687,
      kitchen: 83,
      el: 29400,
      tariffs: store.utilityConfig.tariffs,
    ));
    s = store.utilityStatus(p);
    expect(s.isActual, isTrue);
    expect(s.isDue(DateTime(2026, 10, 29)), isFalse);
    // (2 + 1) × 95.10 + 50.88 = 336.18; 246 × 4.32 = 1062.72; + 700
    expect(s.amount, closeTo(2098.90, 0.001));
    expect(fixedTotal(p), closeTo(12098.90, 0.001));
    final item = store.fixedOf(p.id).firstWhere((f) => f.isUtilities);
    expect(item.isActual, isTrue);
    expect(item.readingDate, DateTime(2026, 10, 28));
  });

  test('показания за месяц — одна запись, смена месяца переносит её', () {
    final m = MeterReading(date: DateTime(2026, 10, 28), bath: 687, kitchen: 83, el: 29400);
    store.saveReading(m);
    store.saveReading(m.copyWith(date: DateTime(2026, 10, 29), el: 29401));
    expect(store.meterReadings.where((x) => x.date.year == 2026 && x.date.month == 10).length, 1);
    store.saveReading(m.copyWith(date: DateTime(2026, 11, 1)), previousId: m.id);
    expect(store.readingById('meter-2026-10'), isNull);
    expect(store.readingById('meter-2026-11'), isNotNull);
  });

  test('новые тарифы не меняют прошлые месяцы', () {
    final sep = store.meterReadings.last;
    store.saveUtilityConfig(store.utilityConfig.copyWith(
      tariffs: store.utilityConfig.tariffs.copyWith(kwh: 5),
    ));
    expect(store.billFor(sep)!.total, closeTo(2064.28, 0.001));
  });

  test('следующий период: коммуналка снова по плану', () {
    store.saveUtilityConfig(store.utilityConfig.copyWith(plan: 4500));
    final next = store.createNextPeriod(oct());
    final f = store.fixedOf(next.id).firstWhere((f) => f.isUtilities);
    expect(f.kind, FixedKind.utilities);
    expect(f.isActual, isFalse);
    expect(f.amount, 4500);
    expect(store.utilityStatus(next).dueDate, DateTime(2026, 11, 28));
  });

  test('старая строка «Коммуналка» без вида подключается сама, ручная — нет', () {
    final p = oct();
    final raw = store.fixedOf(p.id).firstWhere((f) => f.isUtilities);
    store.saveFixed(FixedExpense(id: raw.id, periodId: p.id, name: 'Коммуналка', amount: 3000, order: 1));
    expect(store.fixedOf(p.id).firstWhere((f) => f.id == raw.id).isUtilities, isTrue);

    store.saveFixed(FixedExpense(
        id: raw.id, periodId: p.id, name: 'Коммуналка', amount: 3000, order: 1, kind: FixedKind.manual));
    expect(store.utilitiesItemOf(p.id), isNull);
    expect(fixedTotal(p), 13000);

    store.attachUtilities(p);
    expect(store.utilitiesItemOf(p.id)?.id, raw.id);
    expect(store.fixedOf(p.id).length, 2);
  });
}
