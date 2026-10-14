import '../data/models.dart';
import '../util/format.dart';

/// День месяца, когда снимаются показания и оплачивается коммуналка.
const meterDay = 28;

double _r2(double v) => (v * 100).roundToDouble() / 100;

/// Счёт за месяц — то, что считала таблица в столбцах E–K.
class UtilityBill {
  UtilityBill._({
    required this.reading,
    required this.previous,
    required this.bathUsed,
    required this.kitchenUsed,
    required this.elUsed,
    required this.water,
    required this.electricity,
    required this.heating,
    required this.housing,
  });

  /// Счёт по показаниям [cur] относительно прошлого месяца [prev].
  ///
  /// Вода  = (Δванна + Δкухня) × (куб вход + куб выход) + абон вход + абон выход
  /// Свет  = Δэл × тариф
  /// Итого = вода + свет + отопление + абонплата ЖКХ
  factory UtilityBill.of(MeterReading cur, MeterReading prev) {
    final t = cur.tariffs;
    final bath = _r2(cur.bath - prev.bath);
    final kitchen = _r2(cur.kitchen - prev.kitchen);
    final el = _r2(cur.el - prev.el);
    return UtilityBill._(
      reading: cur,
      previous: prev,
      bathUsed: bath,
      kitchenUsed: kitchen,
      elUsed: el,
      water: _r2((bath + kitchen) * (t.cubeIn + t.cubeOut) + t.waterSubIn + t.waterSubOut),
      electricity: _r2(el * t.kwh),
      heating: _r2(cur.heating),
      housing: _r2(t.housing),
    );
  }

  final MeterReading reading;
  final MeterReading previous;

  /// «Дельта ванна», «Дельта кухня», «Дельта Эл».
  final double bathUsed;
  final double kitchenUsed;
  final double elUsed;

  /// «За воду».
  final double water;

  /// «За Эл».
  final double electricity;

  /// «Отопление».
  final double heating;

  /// Абонплата ЖКХ.
  final double housing;

  double get waterUsed => _r2(bathUsed + kitchenUsed);

  /// «Сумма».
  double get total => _r2(water + electricity + heating + housing);

  /// Показания меньше прошлых — скорее всего, опечатка.
  bool get hasNegative => bathUsed < 0 || kitchenUsed < 0 || elUsed < 0;
}

/// Коммуналка в конкретном периоде.
class UtilityStatus {
  UtilityStatus({
    required this.amount,
    required this.plan,
    required this.dueDate,
    this.bill,
    this.reading,
  });

  /// Сумма, которая идёт в бюджет периода: факт, если есть, иначе план.
  final double amount;

  /// Сумма по умолчанию.
  final double plan;

  /// Когда снимать показания в этом периоде (28-е число внутри периода).
  final DateTime? dueDate;

  /// Счёт по показаниям, если они уже внесены.
  final UtilityBill? bill;

  /// Показания внутри периода (у самых первых показаний счёта нет).
  final MeterReading? reading;

  bool get isActual => bill != null;

  /// Пора вносить показания: дата наступила, а их ещё нет.
  bool isDue(DateTime now) => !isActual && dueDate != null && !dateOnly(now).isBefore(dueDate!);
}

/// Первое [meterDay]-е число внутри периода (у периода 10.10–09.11 это 28.10).
DateTime? meterDateIn(Period p) {
  var d = DateTime(p.start.year, p.start.month, meterDay);
  if (d.isBefore(p.start)) d = DateTime(p.start.year, p.start.month + 1, meterDay);
  return p.contains(d) ? d : null;
}
