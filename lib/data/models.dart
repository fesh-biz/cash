import '../util/format.dart';
import 'record.dart';

/// Типы записей.
abstract final class RecType {
  static const period = 'period';
  static const fixed = 'fixed';
  static const expense = 'expense';
  static const credit = 'credit';
  static const deposit = 'deposit';
}

double _d(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

int _i(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _s(Object? v) => v is String ? v : '';

/// Бюджетный период (например, с 10.10 по 09.11 — от зарплаты до зарплаты).
class Period {
  Period({
    required this.id,
    required this.start,
    required this.end,
    required this.rate,
    required this.incomeEur,
    required this.creditPlan,
  });

  final String id;
  final DateTime start;
  final DateTime end;

  /// Курс гривны к евро («Курс»).
  final double rate;

  /// Доход в евро за период («В месяц €»).
  final double incomeEur;

  /// Сколько в этом периоде отдаю на кредиты («Плачу»).
  final double creditPlan;

  int get days => daysBetween(start, end) + 1;

  double get incomeUah => incomeEur * rate;

  bool contains(DateTime d) {
    final x = dateOnly(d);
    return !x.isBefore(start) && !x.isAfter(end);
  }

  Period copyWith({
    DateTime? start,
    DateTime? end,
    double? rate,
    double? incomeEur,
    double? creditPlan,
  }) =>
      Period(
        id: id,
        start: start ?? this.start,
        end: end ?? this.end,
        rate: rate ?? this.rate,
        incomeEur: incomeEur ?? this.incomeEur,
        creditPlan: creditPlan ?? this.creditPlan,
      );

  static Period? fromRecord(SyncRecord r) {
    final start = tryParseDateKey(r.data['start']);
    final end = tryParseDateKey(r.data['end']);
    if (start == null || end == null) return null;
    return Period(
      id: r.id,
      start: start,
      end: end.isBefore(start) ? start : end,
      rate: _d(r.data['rate']),
      incomeEur: _d(r.data['incomeEur']),
      creditPlan: _d(r.data['creditPlan']),
    );
  }

  Map<String, dynamic> toData() => {
        'start': dateKey(start),
        'end': dateKey(end),
        'rate': rate,
        'incomeEur': incomeEur,
        'creditPlan': creditPlan,
      };
}

/// Обязательный расход периода (квартира, коммуналка…).
class FixedExpense {
  FixedExpense({
    required this.id,
    required this.periodId,
    required this.name,
    required this.amount,
    this.order = 0,
  });

  final String id;
  final String periodId;
  final String name;
  final double amount;
  final int order;

  static FixedExpense fromRecord(SyncRecord r) => FixedExpense(
        id: r.id,
        periodId: _s(r.data['periodId']),
        name: _s(r.data['name']),
        amount: _d(r.data['amount']),
        order: _i(r.data['order']),
      );

  Map<String, dynamic> toData() => {
        'periodId': periodId,
        'name': name,
        'amount': amount,
        'order': order,
      };
}

/// Ежедневный расход.
class Expense {
  Expense({
    required this.id,
    required this.date,
    required this.amount,
    this.note = '',
    required this.created,
  });

  final String id;
  final DateTime date;
  final double amount;
  final String note;

  /// Время создания (мс) — для порядка внутри дня.
  final int created;

  static Expense? fromRecord(SyncRecord r) {
    final date = tryParseDateKey(r.data['date']);
    if (date == null) return null;
    return Expense(
      id: r.id,
      date: date,
      amount: _d(r.data['amount']),
      note: _s(r.data['note']),
      created: _i(r.data['created']),
    );
  }

  Map<String, dynamic> toData() => {
        'date': dateKey(date),
        'amount': amount,
        'note': note,
        'created': created,
      };
}

/// Платёж по кредиту за период (в т.ч. «Проценты»).
///
/// Если заданы [payments] и [firstDate] — это рассрочка: ежемесячный платёж
/// [amount], всего [payments] платежей, первый — [firstDate], дальше в тот же
/// день каждого месяца. По ним считается, сколько платежей уже прошло.
class CreditItem {
  CreditItem({
    required this.id,
    required this.periodId,
    required this.name,
    required this.amount,
    this.order = 0,
    this.payments,
    this.firstDate,
    String? key,
  }) : key = (key == null || key.isEmpty) ? id : key;

  final String id;
  final String periodId;
  final String name;

  /// Ежемесячный платёж.
  final double amount;
  final int order;

  /// Всего платежей (для рассрочки).
  final int? payments;

  /// Дата первого платежа (для рассрочки).
  final DateTime? firstDate;

  /// Общий ключ копий одного кредита в разных периодах.
  final String key;

  bool get isInstallment => payments != null && payments! > 0 && firstDate != null;

  CreditItem copyWith({
    String? id,
    String? periodId,
    String? name,
    double? amount,
    int? order,
  }) =>
      CreditItem(
        id: id ?? this.id,
        periodId: periodId ?? this.periodId,
        name: name ?? this.name,
        amount: amount ?? this.amount,
        order: order ?? this.order,
        payments: payments,
        firstDate: firstDate,
        key: key,
      );

  static CreditItem fromRecord(SyncRecord r) {
    final p = _i(r.data['payments']);
    return CreditItem(
      id: r.id,
      periodId: _s(r.data['periodId']),
      name: _s(r.data['name']),
      amount: _d(r.data['amount']),
      order: _i(r.data['order']),
      payments: p > 0 ? p : null,
      firstDate: tryParseDateKey(r.data['firstDate']),
      key: _s(r.data['key']),
    );
  }

  Map<String, dynamic> toData() => {
        'periodId': periodId,
        'name': name,
        'amount': amount,
        'order': order,
        'key': key,
        if (payments != null) 'payments': payments,
        if (firstDate != null) 'firstDate': dateKey(firstDate!),
      };
}

/// Внесённые на кредит деньги («Внес»).
class CreditDeposit {
  CreditDeposit({
    required this.id,
    required this.periodId,
    required this.date,
    required this.amount,
    this.note = '',
  });

  final String id;
  final String periodId;
  final DateTime date;
  final double amount;
  final String note;

  static CreditDeposit? fromRecord(SyncRecord r) {
    final date = tryParseDateKey(r.data['date']);
    if (date == null) return null;
    return CreditDeposit(
      id: r.id,
      periodId: _s(r.data['periodId']),
      date: date,
      amount: _d(r.data['amount']),
      note: _s(r.data['note']),
    );
  }

  Map<String, dynamic> toData() => {
        'periodId': periodId,
        'date': dateKey(date),
        'amount': amount,
        'note': note,
      };
}
