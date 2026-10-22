import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/currency.dart';
import '../util/format.dart';
import 'app_scope.dart';
import 'common.dart';

/// Форма нового периода: даты, доход (в выбранной валюте), курс, кредиты.
/// Ничего не подставляется заранее — все значения задаёт пользователь.
Future<Period?> showNewPeriodForm(BuildContext context) =>
    showAdaptiveSheet<Period>(context, (ctx) => const _NewPeriodForm());

class _NewPeriodForm extends StatefulWidget {
  const _NewPeriodForm();

  @override
  State<_NewPeriodForm> createState() => _NewPeriodFormState();
}

class _NewPeriodFormState extends State<_NewPeriodForm> {
  DateTimeRange? _dates;
  String? _currency;
  final _income = TextEditingController();
  final _rate = TextEditingController();
  final _credit = TextEditingController();

  @override
  void initState() {
    super.initState();
    for (final c in [_income, _rate, _credit]) {
      c.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    for (final c in [_income, _rate, _credit]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _foreign => _currency != null && !isUah(_currency!);

  /// Пустое поле кредитов — 0 (кредитов нет).
  double? get _creditValue => _credit.text.trim().isEmpty ? 0 : parseAmount(_credit.text);

  String? _overlapError() {
    final d = _dates;
    if (d == null) return null;
    final o = AppScope.of(context).store.overlapping(dateOnly(d.start), dateOnly(d.end));
    return o.isEmpty ? null : 'Перетинається з періодом ${fmtRange(o.first.start, o.first.end)}';
  }

  bool get _valid {
    final income = parseAmount(_income.text);
    final rate = parseAmount(_rate.text);
    final credit = _creditValue;
    return _dates != null &&
        _overlapError() == null &&
        _currency != null &&
        income != null &&
        income >= 0 &&
        (!_foreign || (rate != null && rate > 0)) &&
        credit != null &&
        credit >= 0;
  }

  Future<void> _pickDates() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _dates,
      currentDate: today(),
      helpText: 'Дати періоду',
      saveText: 'Готово',
    );
    if (r != null && mounted) setState(() => _dates = r);
  }

  void _save() {
    if (!_valid) return;
    final store = AppScope.of(context).store;
    final p = store.createPeriod(
      start: _dates!.start,
      end: _dates!.end,
      income: parseAmount(_income.text)!,
      currency: _currency!,
      rate: _foreign ? parseAmount(_rate.text)! : 0,
      creditPlan: _creditValue!,
    );
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = _dates;
    final overlap = _overlapError();
    final sym = _currency == null ? '' : currencySymbol(_currency!);
    final income = parseAmount(_income.text);
    final rate = parseAmount(_rate.text);

    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(text, style: t.textTheme.titleSmall),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Новий період', style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Зазвичай — від зарплати до дня перед наступною.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          label('Дати'),
          OutlinedButton.icon(
            icon: const Icon(Icons.date_range_outlined),
            label: Text(d == null
                ? 'Обрати дати'
                : '${fmtDate(d.start)} – ${fmtDate(d.end)} · ${daysStr(daysBetween(d.start, d.end) + 1)}'),
            onPressed: _pickDates,
          ),
          if (overlap != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(overlap, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
            ),
          const SizedBox(height: 20),
          label('Валюта доходу'),
          CurrencyChips(selected: _currency, onSelected: (c) => setState(() => _currency = c)),
          const SizedBox(height: 16),
          AmountField(
            controller: _income,
            label: 'Дохід за період',
            suffix: sym.isEmpty ? ' ' : sym,
          ),
          if (_foreign) ...[
            const SizedBox(height: 12),
            AmountField(controller: _rate, label: 'Курс, ₴ за 1 $sym'),
            if (income != null && rate != null && rate > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('У гривнях: ${money(income * rate)}', style: t.textTheme.bodyMedium),
              ),
          ],
          const SizedBox(height: 12),
          AmountField(controller: _credit, label: 'Плачу на кредити за період'),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Якщо кредитів немає — залиште порожнім. Обов’язкові витрати (житло, комуналка) '
              'додаються потім на вкладці «Період».',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _valid ? _save : null, child: const Text('Створити')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Выбор валюты: частые валюты и «Інша…» со своим кодом.
class CurrencyChips extends StatelessWidget {
  const CurrencyChips({super.key, required this.selected, required this.onSelected});

  final String? selected;
  final ValueChanged<String> onSelected;

  Future<void> _other(BuildContext context) async {
    final known = currencies.any((c) => c.code == selected);
    final v = await showTextDialog(
      context,
      title: 'Інша валюта',
      label: 'Код валюти',
      initial: selected == null || known ? '' : selected!,
      help: 'Трилітерний код, наприклад SEK, CAD або TRY.',
    );
    if (v == null) return;
    final code = normalizeCurrency(v);
    if (code.isNotEmpty) onSelected(code);
  }

  @override
  Widget build(BuildContext context) {
    final sel = selected;
    final custom = sel != null && !currencies.any((c) => c.code == sel);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in currencies)
          ChoiceChip(
            label: Text('${c.symbol} ${c.code}'),
            tooltip: c.name,
            selected: sel == c.code,
            onSelected: (_) => onSelected(c.code),
          ),
        ChoiceChip(
          label: Text(custom ? sel : 'Інша…'),
          selected: custom,
          onSelected: (_) => _other(context),
        ),
      ],
    );
  }
}

/// Диалог выбора валюты дохода для существующего периода.
Future<String?> pickCurrency(BuildContext context, String current) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Валюта доходу'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Бюджет ведеться в гривнях. Дохід в іншій валюті перераховується за курсом періоду.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            CurrencyChips(selected: current, onSelected: (c) => Navigator.pop(ctx, c)),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Скасувати'))],
    ),
  );
}
