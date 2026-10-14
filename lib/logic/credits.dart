import 'dart:math';

import '../data/models.dart';
import '../util/format.dart';

/// Дата платежа номер [index] (с нуля): тот же день месяца, что и первый
/// платёж; если такого дня в месяце нет (31-е в ноябре) — последний день месяца.
DateTime installmentDate(DateTime first, int index) {
  final month = first.month + index;
  final lastDay = DateTime(first.year, month + 1, 0).day;
  return DateTime(first.year, month, min(first.day, lastDay));
}

/// Состояние рассрочки на дату.
class InstallmentInfo {
  InstallmentInfo._({
    required this.total,
    required this.paid,
    required this.monthly,
    required this.first,
    required this.next,
    required this.last,
  });

  factory InstallmentInfo.of(CreditItem c, DateTime now) {
    final n = c.payments ?? 0;
    final first = c.firstDate ?? dateOnly(now);
    final t = dateOnly(now);
    var paid = 0;
    while (paid < n && installmentDate(first, paid).isBefore(t)) {
      paid++;
    }
    return InstallmentInfo._(
      total: n,
      paid: paid,
      monthly: c.amount,
      first: first,
      next: paid < n ? installmentDate(first, paid) : null,
      last: n > 0 ? installmentDate(first, n - 1) : first,
    );
  }

  /// Всего платежей.
  final int total;

  /// Сколько платежей уже прошло (дата платежа раньше сегодняшней;
  /// в день платежа он ещё считается предстоящим).
  final int paid;

  /// Ежемесячный платёж.
  final double monthly;

  final DateTime first;

  /// Дата следующего платежа; null — рассрочка выплачена.
  final DateTime? next;

  /// Дата последнего платежа.
  final DateTime last;

  int get left => total - paid;

  bool get finished => left <= 0;

  /// Общая сумма рассрочки.
  double get totalSum => monthly * total;

  /// Уже выплачено.
  double get paidSum => monthly * paid;

  /// Осталось выплатить.
  double get leftSum => monthly * left;

  /// День месяца, в который идёт платёж.
  int get dayOfMonth => first.day;

  double get progress => total > 0 ? paid / total : 0;
}

/// Есть ли у платежа [c] оплата в пределах периода [start]..[end].
/// Обычные (не рассрочка) платежи считаются ежемесячными — всегда да.
bool hasPaymentIn(CreditItem c, DateTime start, DateTime end) {
  if (!c.isInstallment) return true;
  for (var i = 0; i < c.payments!; i++) {
    final d = installmentDate(c.firstDate!, i);
    if (d.isAfter(end)) return false;
    if (!d.isBefore(start)) return true;
  }
  return false;
}
