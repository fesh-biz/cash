import 'package:cash/data/models.dart';
import 'package:cash/data/store.dart';

/// Тарифы из исходной таблицы счётчиков.
const tableTariffs = UtilityTariffs(
  waterSubIn: 27.3,
  waterSubOut: 23.58,
  cubeIn: 36.9,
  cubeOut: 58.2,
  kwh: 4.32,
  housing: 700,
);

/// Данные исходной таблицы для тестов (в приложении их больше нет —
/// пользователь вводит всё сам): период 10.10.2026 – 09.11.2026, доход
/// 740 € по курсу 51, квартира, коммуналка, кредиты, траты за 10–13 октября
/// и показания счётчиков 12.2025–09.2026 (снимаются 28-го).
/// Id фиксированные, поэтому загрузка на двух устройствах не создаёт дублей.
Period loadSample(Store store) {
  final start = DateTime(2026, 10, 10);
  final p = Period(
    id: Store.periodIdFor(start),
    start: start,
    end: DateTime(2026, 11, 9),
    income: 740,
    currency: 'EUR',
    rate: 51,
    creditPlan: 10000,
  );
  store.batch(() {
    store.savePeriod(p);
    final fixed = [
      ('Квартира', 10000.0, FixedKind.manual),
      ('Комуналка', 4000.0, FixedKind.utilities),
    ];
    for (var i = 0; i < fixed.length; i++) {
      store.saveFixed(FixedExpense(
        id: '${p.id}-fx-$i',
        periodId: p.id,
        name: fixed[i].$1,
        amount: fixed[i].$2,
        order: i,
        kind: fixed[i].$3,
      ));
    }
    final credits = [('Кредит 1', 1850.0), ('Кредит 2', 666.0), ('Кредит 3', 640.0), ('Відсотки', 700.0)];
    for (var i = 0; i < credits.length; i++) {
      final id = '${p.id}-cr-$i';
      store.put(RecType.credit, id,
          CreditItem(id: id, periodId: p.id, name: credits[i].$1, amount: credits[i].$2, order: i).toData());
    }
    store.saveDeposit(CreditDeposit(id: '${p.id}-dep-sample', periodId: p.id, date: start, amount: 8000));
    for (final (day, amount) in [(10, 1500.0), (11, 500.0), (12, 500.0), (13, 1750.0)]) {
      final id = '${p.id}-ex-sample-$day';
      store.put(RecType.expense, id, Expense(id: id, date: DateTime(2026, 10, day), amount: amount, created: day).toData());
    }
    const rows = [
      // год, месяц, ванна, кухня, эл, отопление
      (2025, 12, 665.0, 78.0, 26381.0, 0.0),
      (2026, 1, 666.0, 78.0, 26820.0, 2540.0),
      (2026, 2, 668.0, 79.0, 27075.0, 2500.0),
      (2026, 3, 670.0, 79.0, 27321.0, 1200.0),
      (2026, 4, 673.0, 80.0, 27724.0, 0.0),
      (2026, 5, 675.0, 81.0, 28116.0, 0.0),
      (2026, 6, 677.0, 81.0, 28383.0, 0.0),
      (2026, 7, 680.0, 81.0, 28623.0, 0.0),
      (2026, 8, 683.0, 82.0, 28894.0, 0.0),
      (2026, 9, 685.0, 82.0, 29154.0, 0.0),
    ];
    for (final (y, mo, bath, kitchen, el, heating) in rows) {
      store.saveReading(MeterReading(
        date: DateTime(y, mo, 28),
        bath: bath,
        kitchen: kitchen,
        el: el,
        heating: heating,
        tariffs: tableTariffs,
      ));
    }
  });
  return p;
}
