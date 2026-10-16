import 'package:flutter/material.dart';

import '../data/models.dart';
import '../logic/utilities.dart';
import '../util/format.dart';
import 'app_scope.dart';
import 'common.dart';

/// Форма ввода показаний счётчиков за месяц.
Future<void> showReadingEditor(BuildContext context, {MeterReading? existing, DateTime? date}) async {
  await showAdaptiveSheet<void>(
    context,
    (ctx) => _ReadingForm(existing: existing, date: existing?.date ?? date ?? today()),
  );
}

class _ReadingForm extends StatefulWidget {
  const _ReadingForm({this.existing, required this.date});

  final MeterReading? existing;
  final DateTime date;

  @override
  State<_ReadingForm> createState() => _ReadingFormState();
}

class _ReadingFormState extends State<_ReadingForm> {
  late DateTime _date = widget.date;
  late final TextEditingController _bath = _ctl(widget.existing?.bath);
  late final TextEditingController _kitchen = _ctl(widget.existing?.kitchen);
  late final TextEditingController _el = _ctl(widget.existing?.el);
  late final TextEditingController _heating =
      _ctl(widget.existing == null || widget.existing!.heating == 0 ? null : widget.existing!.heating);
  bool _useCurrentTariffs = false;

  static TextEditingController _ctl(double? v) => TextEditingController(text: v == null ? '' : editStr(v));

  @override
  void initState() {
    super.initState();
    for (final c in [_bath, _kitchen, _el, _heating]) {
      c.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    for (final c in [_bath, _kitchen, _el, _heating]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Показания из полей; null — если что-то не заполнено.
  MeterReading? _build(UtilityTariffs current) {
    final bath = parseAmount(_bath.text);
    final kitchen = parseAmount(_kitchen.text);
    final el = parseAmount(_el.text);
    final heatingText = _heating.text.trim();
    final heating = heatingText.isEmpty ? 0.0 : parseAmount(heatingText);
    if (bath == null || kitchen == null || el == null || heating == null) return null;
    final ex = widget.existing;
    final tariffs = (ex == null || _useCurrentTariffs) ? current : ex.tariffs;
    return MeterReading(
      date: dateOnly(_date),
      bath: bath,
      kitchen: kitchen,
      el: el,
      heating: heating,
      tariffs: tariffs,
    );
  }

  Future<void> _save() async {
    final store = AppScope.of(context).store;
    final m = _build(store.utilityConfig.tariffs);
    if (m == null) return;
    final ex = widget.existing;
    // В одном месяце — одни показания.
    if (ex == null || ex.id != m.id) {
      final other = store.readingById(m.id);
      if (other != null) {
        final ok = await confirm(
          context,
          'Замінити показники?',
          'За ${_monthName(m.date)} уже є показники від ${fmtDate(other.date)}. Замінити їх новими?',
          action: 'Замінити',
        );
        if (!ok || !mounted) return;
      }
    }
    store.saveReading(m, previousId: ex?.id);
    if (!mounted) return;
    final bill = store.billFor(m);
    final messengerContext = Navigator.of(context).context;
    Navigator.pop(context);
    showSnack(
      messengerContext,
      bill == null ? 'Показники збережено' : 'Комуналка за ${_monthName(m.date)}: ${moneyCents(bill.total)}',
    );
  }

  Future<void> _delete() async {
    final ex = widget.existing;
    if (ex == null) return;
    final ok = await confirm(context, 'Видалити показники?', 'Показники від ${fmtDate(ex.date)} буде видалено.');
    if (!ok || !mounted) return;
    final store = AppScope.of(context).store;
    final messengerContext = Navigator.of(context).context;
    store.remove(ex.id);
    Navigator.pop(context);
    showSnack(messengerContext, 'Показники видалено', undo: () => store.restore(ex.id));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final store = AppScope.of(context).store;
    final current = store.utilityConfig.tariffs;
    final ex = widget.existing;
    final prev = store.readingBefore(dateOnly(_date));
    final m = _build(current);
    final bill = (m != null && prev != null) ? UtilityBill.of(m, prev) : null;
    final period = store.periodFor(_date);
    final tariffsDiffer = ex != null && !ex.tariffs.sameAs(current);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(ex == null ? 'Показники лічильників' : 'Показники за ${_monthName(ex.date)}',
              style: t.textTheme.titleLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.event_outlined),
                label: Text(fmtDate(_date)),
                onPressed: () async {
                  final d = await pickDate(context, _date);
                  if (d != null && mounted) setState(() => _date = d);
                },
              ),
              if (period != null)
                Text('період ${fmtRange(period.start, period.end)}',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _MeterField(
                  controller: _bath,
                  label: 'Ванна',
                  suffix: 'м³',
                  previous: prev?.bath,
                  autofocus: ex == null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MeterField(controller: _kitchen, label: 'Кухня', suffix: 'м³', previous: prev?.kitchen),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _MeterField(controller: _el, label: 'Електроенергія', suffix: 'кВт·год', previous: prev?.el),
          const SizedBox(height: 12),
          _MeterField(
            controller: _heating,
            label: 'Опалення (якщо нараховано)',
            suffix: '₴',
            helper: prev != null && prev.heating > 0 ? 'минулого разу ${moneyCents(prev.heating)}' : null,
          ),
          if (tariffsDiffer)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _useCurrentTariffs,
              onChanged: (v) => setState(() => _useCurrentTariffs = v ?? false),
              title: const Text('Перерахувати за поточними тарифами'),
              subtitle: const Text('Зараз суму пораховано за тарифами на момент показників'),
            ),
          const SizedBox(height: 16),
          if (prev == null)
            Text(
              'Це перші показники — з ними порівнюватимуться наступні. '
              'Сума за цей місяць не рахується.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            )
          else if (bill != null)
            _BillView(bill: bill)
          else
            Text(
              'Заповніть показники — сума порахується сама.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (ex != null)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
                  onPressed: _delete,
                  child: const Text('Видалити'),
                ),
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
              const SizedBox(width: 8),
              FilledButton(onPressed: m == null ? null : _save, child: const Text('Зберегти')),
            ],
          ),
        ],
      ),
    );
  }
}

class _MeterField extends StatelessWidget {
  const _MeterField({
    required this.controller,
    required this.label,
    required this.suffix,
    this.previous,
    this.helper,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final String suffix;
  final double? previous;
  final String? helper;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final text = controller.text.trim();
    final v = text.isEmpty ? null : parseAmount(text);
    String? error;
    String? help = helper;
    if (text.isNotEmpty && v == null) {
      error = 'Не схоже на число';
    } else if (previous != null) {
      if (v != null && v < previous!) {
        error = 'Менше за минулі (${numStr(previous!)})';
      } else if (v != null) {
        help = 'було ${numStr(previous!)} · +${numStr(v - previous!)}';
      } else {
        help = 'було ${numStr(previous!)}';
      }
    }
    return TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textInputAction: TextInputAction.next,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontFeatures: tabular),
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        helperText: help,
        errorText: error,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// Расшифровка суммы за месяц.
class _BillView extends StatelessWidget {
  const _BillView({required this.bill});

  final UtilityBill bill;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tr = bill.reading.tariffs;
    return Material(
      color: t.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: UtilityBillLines(bill: bill, tariffs: tr),
      ),
    );
  }
}

/// Строки расчёта: вода, свет, отопление, ЖКХ, итого.
class UtilityBillLines extends StatelessWidget {
  const UtilityBillLines({super.key, required this.bill, required this.tariffs});

  final UtilityBill bill;
  final UtilityTariffs tariffs;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cube = tariffs.cubeIn + tariffs.cubeOut;
    final subs = tariffs.waterSubIn + tariffs.waterSubOut;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _line(context, 'Вода',
            '${numStr(bill.waterUsed)} м³ × ${moneyCents(cube, currency: false)} + ${moneyCents(subs, currency: false)}',
            bill.water),
        _line(context, 'Електроенергія', '${numStr(bill.elUsed)} кВт·год × ${moneyCents(tariffs.kwh, currency: false)}',
            bill.electricity),
        _line(context, 'Опалення', bill.heating == 0 ? 'не нараховано' : null, bill.heating),
        _line(context, 'Абонплата ЖКГ', null, bill.housing),
        const Divider(indent: 16, endIndent: 16, height: 8),
        ListTile(
          dense: true,
          title: Text('Разом', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          trailing: Text(
            moneyCents(bill.total),
            style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontFeatures: tabular),
          ),
        ),
        if (bill.hasNegative)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Показники менші за минулі — перевірте цифри.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _line(BuildContext context, String title, String? sub, double amount) {
    final t = Theme.of(context);
    return ListTile(
      dense: true,
      title: Text(title),
      subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontFeatures: tabular)),
      trailing: Text(moneyCents(amount), style: t.textTheme.bodyLarge?.copyWith(fontFeatures: tabular)),
    );
  }
}

const _months = [
  'січень', 'лютий', 'березень', 'квітень', 'травень', 'червень',
  'липень', 'серпень', 'вересень', 'жовтень', 'листопад', 'грудень',
];

String _monthName(DateTime d) => '${_months[d.month - 1]} ${d.year}';

/// «Сентябрь 2026»
String monthTitle(DateTime d) {
  final s = _monthName(d);
  return s[0].toUpperCase() + s.substring(1);
}
