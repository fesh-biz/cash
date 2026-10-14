// Форматирование денег и дат, разбор введённых сумм.

const _monthsShort = [
  'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
  'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
];
const _monthsGen = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
];
const _weekdaysShort = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
const _weekdaysLong = [
  'Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье',
];

const _nbsp = ' ';

String _two(int v) => v.toString().padLeft(2, '0');

String _groupDigits(String digits) {
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(_nbsp);
    buf.write(digits[i]);
  }
  return buf.toString();
}

/// 13740 -> "13 740 ₴", -2477 -> "−2 477 ₴". Округляет до целых.
String money(num value, {bool currency = true, bool plusSign = false}) {
  final r = value.round();
  var out = _groupDigits(r.abs().toString());
  if (r < 0) {
    out = '−$out';
  } else if (plusSign && r > 0) {
    out = '+$out';
  }
  return currency ? '$out$_nbsp₴' : out;
}

/// Число без лишних нулей: 51 -> "51", 41.5 -> "41.5", 41.25 -> "41.25".
String numStr(num value) {
  if (value == value.roundToDouble()) {
    final r = value.round();
    return (r < 0 ? '−' : '') + _groupDigits(r.abs().toString());
  }
  var s = value.toStringAsFixed(2);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  s = s.replaceFirst(RegExp(r'\.$'), '');
  return s;
}

/// Число для поля ввода (без пробелов и знака валюты).
String editStr(num value) {
  if (value == value.roundToDouble()) return value.round().toString();
  var s = value.toStringAsFixed(2);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  s = s.replaceFirst(RegExp(r'\.$'), '');
  return s;
}

/// Разбирает сумму. Понимает запятую, пробелы и простые выражения: "500+250-30".
double? parseAmount(String input) {
  final s = input
      .replaceAll(RegExp(r'[\s  ₴€]'), '')
      .replaceAll(',', '.')
      .replaceAll('−', '-');
  if (s.isEmpty) return null;
  final re = RegExp(r'([+-]?)(\d+(?:\.\d+)?|\.\d+)');
  var total = 0.0;
  var pos = 0;
  var first = true;
  for (final m in re.allMatches(s)) {
    if (m.start != pos) return null;
    final sign = m.group(1)!;
    if (!first && sign.isEmpty) return null;
    final v = double.parse(m.group(2)!);
    total += sign == '-' ? -v : v;
    pos = m.end;
    first = false;
  }
  if (first || pos != s.length) return null;
  return total;
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime today() => dateOnly(DateTime.now());

DateTime addDays(DateTime d, int days) => DateTime(d.year, d.month, d.day + days);

/// Количество дней от [a] до [b] (b - a), без учёта времени и перехода на летнее время.
int daysBetween(DateTime a, DateTime b) => DateTime.utc(b.year, b.month, b.day)
    .difference(DateTime.utc(a.year, a.month, a.day))
    .inDays;

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// "2026-10-13"
String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

DateTime parseDateKey(String s) {
  final p = s.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

DateTime? tryParseDateKey(Object? s) {
  if (s is! String) return null;
  try {
    return parseDateKey(s);
  } catch (_) {
    return null;
  }
}

/// "13 окт"
String fmtDay(DateTime d) => '${d.day} ${_monthsShort[d.month - 1]}';

/// "13 октября"
String fmtDayLong(DateTime d) => '${d.day} ${_monthsGen[d.month - 1]}';

/// "13.10.2026"
String fmtDate(DateTime d) => '${_two(d.day)}.${_two(d.month)}.${d.year}';

/// "13.10"
String fmtDateShort(DateTime d) => '${_two(d.day)}.${_two(d.month)}';

/// "Пн"
String fmtWeekday(DateTime d) => _weekdaysShort[d.weekday - 1];

/// "Понедельник"
String fmtWeekdayLong(DateTime d) => _weekdaysLong[d.weekday - 1];

/// "10.10 – 09.11.2026" (год у первой даты, если отличается)
String fmtRange(DateTime a, DateTime b) {
  final left = a.year == b.year ? fmtDateShort(a) : fmtDate(a);
  return '$left – ${fmtDate(b)}';
}

/// "23:51" сегодня, иначе "12 окт 23:51"
String fmtTimeAgo(DateTime t) {
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  if (sameDay(t, DateTime.now())) return hm;
  return '${fmtDay(t)} $hm';
}

/// plural(5, 'день', 'дня', 'дней') -> 'дней'
String plural(int n, String one, String few, String many) {
  final a = n.abs() % 100;
  final b = a % 10;
  if (a >= 11 && a <= 14) return many;
  if (b == 1) return one;
  if (b >= 2 && b <= 4) return few;
  return many;
}

String daysStr(int n) => '$n ${plural(n, 'день', 'дня', 'дней')}';
