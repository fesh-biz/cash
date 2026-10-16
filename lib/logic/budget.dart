import '../data/models.dart';
import '../util/format.dart';

/// Строка таблицы по дням.
class DayRow {
  DayRow({
    required this.index,
    required this.date,
    required this.spent,
    required this.count,
    required this.balance,
  });

  final int index;
  final DateTime date;

  /// Потрачено за день.
  final double spent;

  /// Сколько записей расходов за день.
  final int count;

  /// Накопленный остаток на конец дня («Остаток» в таблице):
  /// лимит_в_день × (номер дня) − всё потраченное с начала периода.
  final double balance;
}

enum PeriodState { notStarted, active, finished }

/// Все расчёты по периоду — то же, что считала таблица, плюс подсказки.
class PeriodSummary {
  PeriodSummary._({
    required this.period,
    required this.fixedTotal,
    required this.available,
    required this.perDay,
    required this.spent,
    required this.rows,
    required this.todayIndex,
    required this.state,
  });

  factory PeriodSummary.compute(
    Period period,
    List<FixedExpense> fixed,
    List<Expense> expenses,
    DateTime now,
  ) {
    final days = period.days;
    final fixedTotal = fixed.fold<double>(0, (s, f) => s + f.amount);
    final available = period.incomeUah - fixedTotal - period.creditPlan;
    final perDay = days > 0 ? available / days : 0.0;

    final spentByDay = List<double>.filled(days, 0);
    final countByDay = List<int>.filled(days, 0);
    for (final e in expenses) {
      final i = daysBetween(period.start, e.date);
      if (i < 0 || i >= days) continue;
      spentByDay[i] += e.amount;
      countByDay[i]++;
    }

    final rows = <DayRow>[];
    var cum = 0.0;
    for (var i = 0; i < days; i++) {
      cum += spentByDay[i];
      rows.add(DayRow(
        index: i,
        date: addDays(period.start, i),
        spent: spentByDay[i],
        count: countByDay[i],
        balance: perDay * (i + 1) - cum,
      ));
    }

    final ti = daysBetween(period.start, dateOnly(now));
    final PeriodState state;
    if (ti < 0) {
      state = PeriodState.notStarted;
    } else if (ti >= days) {
      state = PeriodState.finished;
    } else {
      state = PeriodState.active;
    }

    return PeriodSummary._(
      period: period,
      fixedTotal: fixedTotal,
      available: available,
      perDay: perDay,
      spent: cum,
      rows: rows,
      todayIndex: state == PeriodState.active ? ti : null,
      state: state,
    );
  }

  final Period period;

  /// Сумма обязательных расходов (квартира, коммуналка…).
  final double fixedTotal;

  /// «Остаток» — сколько можно потратить за период.
  final double available;

  /// «В день».
  final double perDay;

  /// «Потрачено».
  final double spent;

  final List<DayRow> rows;

  /// Индекс сегодняшнего дня, если период идёт сейчас.
  final int? todayIndex;

  final PeriodState state;

  /// «Осталось».
  double get left => available - spent;

  /// Остаток на сегодня (накопленный). Для завершённого периода — итог.
  double get todayBalance => switch (state) {
        PeriodState.active => rows[todayIndex!].balance,
        PeriodState.finished => rows.isEmpty ? 0.0 : rows.last.balance,
        PeriodState.notStarted => 0.0,
      };

  double get spentToday => todayIndex == null ? 0 : rows[todayIndex!].spent;

  /// Сколько дней осталось, включая сегодня.
  int get daysLeft => switch (state) {
        PeriodState.active => period.days - todayIndex!,
        PeriodState.finished => 0,
        PeriodState.notStarted => period.days,
      };

  /// Лимит в день на оставшиеся дни с учётом уже сделанных трат
  /// (траты сегодняшнего дня не учитываются — они входят в этот лимит).
  double get perDayFromToday {
    if (state != PeriodState.active) return perDay;
    var before = 0.0;
    for (var i = 0; i < todayIndex!; i++) {
      before += rows[i].spent;
    }
    final d = daysLeft;
    return d > 0 ? (available - before) / d : 0;
  }

  /// Если сегодня минус — с какого дня остаток станет неотрицательным,
  /// если больше ничего не тратить. null — если не в минусе или не успеет.
  DateTime? get backToPlusDate {
    final k = daysToPlus;
    return k == null ? null : addDays(period.start, todayIndex! + k);
  }

  /// Через сколько дней остаток станет неотрицательным, если больше ничего
  /// не тратить. null — если не в минусе или не успеет до конца периода.
  int? get daysToPlus {
    if (state != PeriodState.active) return null;
    final b = todayBalance;
    if (b >= 0 || perDay <= 0) return null;
    // Небольшой допуск, чтобы −0.0001 из-за округления не давал лишний день.
    final k = ((-b - 1e-6) / perDay).ceil();
    if (todayIndex! + k >= period.days) return null;
    return k;
  }
}
