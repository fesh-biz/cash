import '../util/format.dart';
import 'record.dart';

/// Типы записей.
abstract final class RecType {
  static const period = 'period';
  static const fixed = 'fixed';
  static const expense = 'expense';
  static const credit = 'credit';
  static const deposit = 'deposit';

  /// Показания счётчиков за месяц.
  static const meter = 'meter';

  /// Тарифы коммуналки и сумма по умолчанию (одна запись на все устройства).
  static const utilConfig = 'utilConfig';
}

/// Вид обязательного расхода.
abstract final class FixedKind {
  /// Сумма вводится вручную.
  static const manual = 'manual';

  /// Коммуналка: сумма по показаниям счётчиков, а до них — план по умолчанию.
  static const utilities = 'utilities';
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
    this.kind = '',
    this.isActual = false,
    this.readingDate,
  });

  final String id;
  final String periodId;
  final String name;

  /// Сумма. Для коммуналки — уже посчитанная: факт по показаниям или план.
  final double amount;
  final int order;

  /// [FixedKind]; пусто — старая запись (коммуналка узнаётся по названию).
  final String kind;

  /// Коммуналка: сумма посчитана по показаниям (а не план по умолчанию).
  final bool isActual;

  /// Коммуналка: дата показаний, по которым посчитана сумма.
  final DateTime? readingDate;

  bool get isUtilities =>
      kind == FixedKind.utilities || (kind.isEmpty && name.toLowerCase().contains('коммунал'));

  FixedExpense resolved({required double amount, required bool isActual, DateTime? readingDate}) => FixedExpense(
        id: id,
        periodId: periodId,
        name: name,
        amount: amount,
        order: order,
        kind: kind,
        isActual: isActual,
        readingDate: readingDate,
      );

  static FixedExpense fromRecord(SyncRecord r) => FixedExpense(
        id: r.id,
        periodId: _s(r.data['periodId']),
        name: _s(r.data['name']),
        amount: _d(r.data['amount']),
        order: _i(r.data['order']),
        kind: _s(r.data['kind']),
      );

  Map<String, dynamic> toData() => {
        'periodId': periodId,
        'name': name,
        'amount': amount,
        'order': order,
        if (kind.isNotEmpty) 'kind': kind,
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

double? _dn(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// Тарифы коммуналки (столбцы L–P исходной таблицы).
class UtilityTariffs {
  const UtilityTariffs({
    required this.waterSubIn,
    required this.waterSubOut,
    required this.cubeIn,
    required this.cubeOut,
    required this.kwh,
    required this.housing,
  });

  /// Абонплата за подачу воды («Абон вход»), в месяц.
  final double waterSubIn;

  /// Абонплата за водоотведение («Абон выход»), в месяц.
  final double waterSubOut;

  /// За 1 м³ воды («Куб вход»).
  final double cubeIn;

  /// За 1 м³ водоотведения («Куб выход»).
  final double cubeOut;

  /// За 1 кВт·ч.
  final double kwh;

  /// Абонплата ЖКХ, в месяц.
  final double housing;

  /// Тарифы из таблицы.
  static const initial = UtilityTariffs(
    waterSubIn: 27.3,
    waterSubOut: 23.58,
    cubeIn: 36.9,
    cubeOut: 58.2,
    kwh: 4.32,
    housing: 700,
  );

  UtilityTariffs copyWith({
    double? waterSubIn,
    double? waterSubOut,
    double? cubeIn,
    double? cubeOut,
    double? kwh,
    double? housing,
  }) =>
      UtilityTariffs(
        waterSubIn: waterSubIn ?? this.waterSubIn,
        waterSubOut: waterSubOut ?? this.waterSubOut,
        cubeIn: cubeIn ?? this.cubeIn,
        cubeOut: cubeOut ?? this.cubeOut,
        kwh: kwh ?? this.kwh,
        housing: housing ?? this.housing,
      );

  bool sameAs(UtilityTariffs o) =>
      waterSubIn == o.waterSubIn &&
      waterSubOut == o.waterSubOut &&
      cubeIn == o.cubeIn &&
      cubeOut == o.cubeOut &&
      kwh == o.kwh &&
      housing == o.housing;

  /// Отсутствующие значения берутся из [fallback].
  static UtilityTariffs fromJson(Object? j, {UtilityTariffs fallback = initial}) {
    if (j is! Map) return fallback;
    return UtilityTariffs(
      waterSubIn: _dn(j['waterSubIn']) ?? fallback.waterSubIn,
      waterSubOut: _dn(j['waterSubOut']) ?? fallback.waterSubOut,
      cubeIn: _dn(j['cubeIn']) ?? fallback.cubeIn,
      cubeOut: _dn(j['cubeOut']) ?? fallback.cubeOut,
      kwh: _dn(j['kwh']) ?? fallback.kwh,
      housing: _dn(j['housing']) ?? fallback.housing,
    );
  }

  Map<String, dynamic> toJson() => {
        'waterSubIn': waterSubIn,
        'waterSubOut': waterSubOut,
        'cubeIn': cubeIn,
        'cubeOut': cubeOut,
        'kwh': kwh,
        'housing': housing,
      };
}

/// Настройки коммуналки: текущие тарифы и сумма по умолчанию.
class UtilityConfig {
  const UtilityConfig({this.tariffs = UtilityTariffs.initial, this.plan});

  static const id = 'utilities-config';

  /// Тарифы для новых показаний.
  final UtilityTariffs tariffs;

  /// Сумма коммуналки по умолчанию — пока не внесены показания за период.
  /// null — ещё не задана (тогда берётся сумма, записанная в самом периоде).
  final double? plan;

  UtilityConfig copyWith({UtilityTariffs? tariffs, double? plan}) =>
      UtilityConfig(tariffs: tariffs ?? this.tariffs, plan: plan ?? this.plan);

  static UtilityConfig fromRecord(SyncRecord? r) {
    if (r == null || r.deleted) return const UtilityConfig();
    return UtilityConfig(
      tariffs: UtilityTariffs.fromJson(r.data['tariffs']),
      plan: _dn(r.data['plan']),
    );
  }

  Map<String, dynamic> toData() => {
        'tariffs': tariffs.toJson(),
        if (plan != null) 'plan': plan,
      };
}

/// Показания счётчиков за месяц (снимаются 28-го).
///
/// Одна запись на месяц: id вида `meter-2026-10`, поэтому показания за один
/// месяц, введённые на двух устройствах, не задваиваются.
class MeterReading {
  MeterReading({
    required this.date,
    required this.bath,
    required this.kitchen,
    required this.el,
    this.heating = 0,
    this.tariffs = UtilityTariffs.initial,
  });

  /// Дата снятия показаний.
  final DateTime date;

  /// Счётчик воды в ванной, м³.
  final double bath;

  /// Счётчик воды на кухне, м³.
  final double kitchen;

  /// Электросчётчик, кВт·ч.
  final double el;

  /// Отопление за месяц, ₴ (вводится вручную, 0 — не было).
  final double heating;

  /// Тарифы, действовавшие на момент показаний. Смена тарифов в настройках
  /// не пересчитывает старые месяцы.
  final UtilityTariffs tariffs;

  String get id => idFor(date);

  static String idFor(DateTime date) =>
      'meter-${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';

  MeterReading copyWith({
    DateTime? date,
    double? bath,
    double? kitchen,
    double? el,
    double? heating,
    UtilityTariffs? tariffs,
  }) =>
      MeterReading(
        date: date ?? this.date,
        bath: bath ?? this.bath,
        kitchen: kitchen ?? this.kitchen,
        el: el ?? this.el,
        heating: heating ?? this.heating,
        tariffs: tariffs ?? this.tariffs,
      );

  static MeterReading? fromRecord(SyncRecord r) {
    final date = tryParseDateKey(r.data['date']);
    if (date == null) return null;
    return MeterReading(
      date: date,
      bath: _d(r.data['bath']),
      kitchen: _d(r.data['kitchen']),
      el: _d(r.data['el']),
      heating: _d(r.data['heating']),
      tariffs: UtilityTariffs.fromJson(r.data['tariffs']),
    );
  }

  Map<String, dynamic> toData() => {
        'date': dateKey(date),
        'bath': bath,
        'kitchen': kitchen,
        'el': el,
        'heating': heating,
        'tariffs': tariffs.toJson(),
      };
}
