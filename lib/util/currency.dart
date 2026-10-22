// Валюты дохода. Бюджет ведётся в гривнах; доход можно задать в любой
// валюте — тогда он пересчитывается по курсу периода.

/// Гривна — валюта бюджета.
const uah = 'UAH';

/// Валюта из списка выбора.
class Currency {
  const Currency(this.code, this.symbol, this.name);

  final String code;
  final String symbol;
  final String name;
}

/// Частые валюты. Любую другую можно ввести своим кодом.
const currencies = [
  Currency('UAH', '₴', 'Гривня'),
  Currency('EUR', '€', 'Євро'),
  Currency('USD', r'$', 'Долар США'),
  Currency('PLN', 'zł', 'Польський злотий'),
  Currency('GBP', '£', 'Фунт стерлінгів'),
  Currency('CHF', 'CHF', 'Швейцарський франк'),
  Currency('CZK', 'Kč', 'Чеська крона'),
];

Currency? _known(String code) {
  for (final c in currencies) {
    if (c.code == code) return c;
  }
  return null;
}

/// Нормализует введённый код: «usd » → «USD».
String normalizeCurrency(String code) => code.trim().toUpperCase();

/// Знак валюты: «€», «$»; для неизвестной — сам код.
String currencySymbol(String code) => _known(code)?.symbol ?? code;

/// «Євро (EUR)»; для неизвестной — код.
String currencyLabel(String code) {
  final c = _known(code);
  return c == null ? code : '${c.name} (${c.code})';
}

/// Валюта, в которой доход не нужно пересчитывать.
bool isUah(String code) => code == uah;
