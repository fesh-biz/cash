import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../logic/credits.dart';
import '../util/format.dart';
import 'app_scope.dart';
import 'common.dart';

/// Вкладка «Кредиты»: платежи и рассрочки, внесённые суммы, сколько отдаю из бюджета.
class CreditsPage extends StatelessWidget {
  const CreditsPage({super.key, required this.period});

  final Period? period;

  @override
  Widget build(BuildContext context) {
    final p = period;
    if (p == null) {
      return const Center(child: Text('Спочатку створіть період на вкладці «Бюджет»'));
    }
    final store = AppScope.of(context).store;
    final now = DateTime.now();
    final items = store.creditsOf(p.id);
    final deposits = store.depositsOf(p.id);
    final dueItems = items.where((c) => hasPaymentIn(c, p.start, p.end)).toList();
    final due = dueItems.fold<double>(0, (s, c) => s + c.amount);
    final paid = deposits.fold<double>(0, (s, d) => s + d.amount);
    final diff = paid - due;
    final planLeft = p.creditPlan - paid;

    final installments = items.where((c) => c.isInstallment).map((c) => InstallmentInfo.of(c, now)).toList();
    final active = installments.where((i) => !i.finished).toList();
    final leftSum = active.fold<double>(0, (s, i) => s + i.leftSum);
    final leftCount = active.fold<int>(0, (s, i) => s + i.left);

    final summary = StatGrid(
      minTileWidth: 150,
      children: [
        StatTile(label: 'До сплати в періоді', value: money(due), hint: 'сума платежів'),
        StatTile(label: 'Внесено', value: money(paid)),
        StatTile(
          label: diff.round() >= 0 ? 'Внесено понад платежі' : 'Бракує до платежів',
          value: money(diff.abs()),
          color: balanceColor(context, diff),
        ),
        StatTile(
          label: 'Плачу (з бюджету)',
          value: money(p.creditPlan),
          hint: planLeft.round() > 0
              ? 'ще внести ${money(planLeft)}'
              : planLeft.round() < 0
                  ? 'внесено більше за план на ${money(-planLeft)}'
                  : 'внесено за планом',
          onTap: () => _editPlan(context, store, p),
        ),
        if (installments.isNotEmpty)
          StatTile(
            label: 'Залишилось виплатити',
            value: money(leftSum),
            hint: active.isEmpty
                ? 'усі розстрочки виплачено'
                : '$leftCount ${plural(leftCount, 'платіж', 'платежі', 'платежів')} '
                    'за ${active.length} ${plural(active.length, 'розстрочкою', 'розстрочками', 'розстрочками')}',
          ),
      ],
    );

    final itemsCard = SectionCard(
      title: 'Кредити й розстрочки',
      trailing: IconButton(
        tooltip: 'Додати',
        icon: const Icon(Icons.add),
        onPressed: () => _editItem(context, store, p, null, items.length),
      ),
      children: [
        if (items.isEmpty)
          const ListTile(
            title: Text('Платежів немає'),
            subtitle: Text('Додайте кредити, розстрочки й відсотки'),
          ),
        for (final c in items)
          _CreditTile(
            item: c,
            now: now,
            inPeriod: hasPaymentIn(c, p.start, p.end),
            onTap: () => _editItem(context, store, p, c, c.order),
          ),
        if (items.isNotEmpty) ...[
          const Divider(indent: 16, endIndent: 16),
          AmountTile(title: 'Усього в цьому періоді', amount: due, bold: true),
        ],
      ],
    );

    final depositsCard = SectionCard(
      title: 'Внесено',
      trailing: IconButton(
        tooltip: 'Внести',
        icon: const Icon(Icons.add),
        onPressed: () => _editDeposit(context, store, p, null),
      ),
      children: [
        if (deposits.isEmpty) const ListTile(title: Text('Поки нічого не внесено')),
        for (final d in deposits)
          AmountTile(
            title: fmtDate(d.date),
            subtitle: d.note.isEmpty ? null : d.note,
            amount: d.amount,
            onTap: () => _editDeposit(context, store, p, d),
          ),
        if (deposits.isNotEmpty) ...[
          const Divider(indent: 16, endIndent: 16),
          AmountTile(title: 'Усього', amount: paid, bold: true),
        ],
      ],
    );

    final wide = isWide(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        summary,
        const SizedBox(height: 12),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: itemsCard),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: depositsCard),
            ],
          )
        else ...[
          itemsCard,
          const SizedBox(height: 12),
          depositsCard,
        ],
        const SizedBox(height: 12),
        Text(
          '«Плачу» — сума, яку ви відкладаєте на кредити з доходу періоду; '
          'вона віднімається з бюджету на життя. Для розстрочки вкажіть кількість '
          'платежів і дату першого — застосунок сам порахує, скільки залишилось. '
          'Зміни кредиту переносяться й у наступні періоди.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  Future<void> _editPlan(BuildContext context, Store store, Period p) async {
    final v = await showNumberDialog(
      context,
      title: 'Плачу на кредити',
      initial: p.creditPlan,
      help: 'Скільки з доходу періоду йде на кредити. Віднімається з бюджету.',
    );
    if (v != null) store.savePeriod(p.copyWith(creditPlan: v));
  }

  Future<void> _editItem(BuildContext context, Store store, Period p, CreditItem? c, int order) async {
    final r = await showDialog<_CreditEdit>(
      context: context,
      builder: (_) => _CreditDialog(item: c),
    );
    if (r == null) return;
    if (r.delete) {
      final ids = store.removeCredit(c!);
      if (context.mounted) {
        showSnack(
          context,
          ids.length > 1 ? 'Видалено з цього й наступних періодів' : 'Платіж видалено',
          undo: () {
            for (final id in ids) {
              store.restore(id);
            }
          },
        );
      }
      return;
    }
    store.saveCredit(CreditItem(
      id: c?.id ?? Store.newId(),
      periodId: p.id,
      name: r.name,
      amount: r.amount,
      order: order,
      payments: r.payments,
      firstDate: r.firstDate,
      firstPaid: r.firstPaid,
      key: c?.key,
    ));
  }

  Future<void> _editDeposit(BuildContext context, Store store, Period p, CreditDeposit? d) async {
    final r = await showItemDialog(
      context,
      title: d == null ? 'Внести на кредит' : 'Внесено',
      name: d?.note ?? '',
      amount: d?.amount,
      date: d?.date ?? (p.contains(today()) ? today() : p.start),
      withDate: true,
      nameLabel: 'Коментар (необов’язково)',
      canDelete: d != null,
    );
    if (r == null) return;
    if (r.delete) {
      final id = d!.id;
      store.remove(id);
      if (context.mounted) showSnack(context, 'Запис видалено', undo: () => store.restore(id));
      return;
    }
    store.saveDeposit(CreditDeposit(
      id: d?.id ?? Store.newId(),
      periodId: p.id,
      date: r.date,
      amount: r.amount,
      note: r.name,
    ));
  }
}

// ---------------------------------------------------------------- строка кредита

class _CreditTile extends StatelessWidget {
  const _CreditTile({required this.item, required this.now, required this.inPeriod, required this.onTap});

  final CreditItem item;
  final DateTime now;
  final bool inPeriod;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = item;
    final name = c.name.isEmpty ? 'Без назви' : c.name;
    if (!c.isInstallment) {
      return AmountTile(title: name, amount: c.amount, subtitle: 'щомісяця', onTap: onTap);
    }

    final t = Theme.of(context);
    final info = InstallmentInfo.of(c, now);
    final muted = t.colorScheme.onSurfaceVariant;
    final String status;
    final String details;
    if (info.finished) {
      status = 'Виплачено повністю';
      details = 'Останній платіж ${fmtDate(info.last)} · усього ${money(info.totalSum)}';
    } else {
      status = 'Залишилось ${info.left} ${plural(info.left, 'платіж', 'платежі', 'платежів')} '
          'з ${info.total} · ${money(info.leftSum)}';
      details = 'Наступний ${fmtDayLong(info.next!)}'
          '${info.next!.year != now.year ? ' ${info.next!.year}' : ''}'
          ' · останній ${fmtDate(info.last)} · усього ${money(info.totalSum)}';
    }

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(name, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                Text(
                  '${money(c.amount)}/міс',
                  style: t.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontFeatures: tabular,
                    color: inPeriod ? null : muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              status,
              style: t.textTheme.bodyMedium?.copyWith(
                fontFeatures: tabular,
                color: info.finished ? positiveColor(context) : null,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: info.progress,
                minHeight: 6,
                backgroundColor: t.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 6),
            Text(details, style: t.textTheme.bodySmall?.copyWith(color: muted, fontFeatures: tabular)),
            if (!inPeriod)
              Text(
                'У цьому періоді платежу немає',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.tertiary),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- диалог кредита

class _CreditEdit {
  _CreditEdit({
    required this.name,
    required this.amount,
    this.payments,
    this.firstDate,
    this.firstPaid = false,
    this.delete = false,
  });

  final String name;
  final double amount;
  final int? payments;
  final DateTime? firstDate;
  final bool firstPaid;
  final bool delete;
}

class _CreditDialog extends StatefulWidget {
  const _CreditDialog({this.item});

  final CreditItem? item;

  @override
  State<_CreditDialog> createState() => _CreditDialogState();
}

class _CreditDialogState extends State<_CreditDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.item?.name ?? '');
  late final TextEditingController _amount =
      TextEditingController(text: widget.item == null ? '' : editStr(widget.item!.amount));
  late final TextEditingController _count =
      TextEditingController(text: widget.item?.payments?.toString() ?? '');
  late bool _installment = widget.item?.isInstallment ?? false;
  late DateTime _first = widget.item?.firstDate ?? today();

  /// Новый кредит обычно заводят в день оформления, когда первый платёж уже внесён.
  late bool _firstPaid = widget.item?.firstPaid ?? true;

  /// Галочка «сплачено при оформленні» имеет смысл, только если первый платёж
  /// сегодня: прошедшие и так выплачены, будущие ещё нет.
  bool get _firstIsToday => _first == today();

  bool get _firstPaidEffective => _firstPaid && _firstIsToday;

  @override
  void initState() {
    super.initState();
    _amount.addListener(_rebuild);
    _count.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _count.dispose();
    super.dispose();
  }

  int? get _payments {
    final v = int.tryParse(_count.text.trim());
    return (v != null && v > 0 && v <= 600) ? v : null;
  }

  void _ok() {
    final a = parseAmount(_amount.text);
    if (a == null) return;
    if (_installment && _payments == null) return;
    Navigator.pop(
      context,
      _CreditEdit(
        name: _name.text.trim(),
        amount: a,
        payments: _installment ? _payments : null,
        firstDate: _installment ? _first : null,
        firstPaid: _installment && _firstPaidEffective,
      ),
    );
  }

  Future<void> _fromRemaining() async {
    final r = await showDialog<(int, DateTime)>(context: context, builder: (_) => const _RemainingDialog());
    if (r == null || !mounted) return;
    final (left, next) = r;
    var total = _payments ?? left;
    if (total < left) total = left;
    setState(() {
      _count.text = '$total';
      _first = installmentDate(next, -(total - left));
      _firstPaid = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final a = parseAmount(_amount.text);
    final n = _payments;
    InstallmentInfo? info;
    if (_installment && a != null && n != null) {
      info = InstallmentInfo.of(
        CreditItem(
          id: '',
          periodId: '',
          name: '',
          amount: a,
          payments: n,
          firstDate: _first,
          firstPaid: _firstPaidEffective,
        ),
        DateTime.now(),
      );
    }

    return AlertDialog(
      title: Text(widget.item == null ? 'Новий кредит / платіж' : 'Кредит'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: widget.item == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Назва (наприклад, «Розстрочка Rozetka» або «Відсотки»)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              AmountField(controller: _amount, label: 'Платіж на місяць', onSubmitted: _ok),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Розстрочка або кредит на строк'),
                subtitle: const Text('Вказати кількість платежів і дату'),
                value: _installment,
                onChanged: (v) => setState(() => _installment = v),
              ),
              if (_installment) ...[
                const SizedBox(height: 4),
                TextField(
                  controller: _count,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Усього платежів',
                    border: const OutlineInputBorder(),
                    errorText: _count.text.trim().isNotEmpty && n == null ? 'Ціле число від 1 до 600' : null,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.event_outlined),
                  label: Text('Перший платіж: ${fmtDate(_first)}'),
                  onPressed: () async {
                    final d = await pickDate(context, _first);
                    if (d != null && mounted) setState(() => _first = d);
                  },
                ),
                if (_firstIsToday)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Перший платіж сплачено при оформленні'),
                    value: _firstPaid,
                    onChanged: (v) => setState(() => _firstPaid = v ?? false),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _fromRemaining,
                    child: const Text('Не пам’ятаю першого — знаю, скільки залишилось'),
                  ),
                ),
                if (info != null)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(color: t.colorScheme.onSecondaryContainer, fontFeatures: tabular),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Усього за розстрочкою: ${money(info.totalSum)}',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(info.finished
                              ? 'Виплачено повністю'
                              : 'Минуло ${info.paid} з ${info.total}, залишилось ${info.left} · ${money(info.leftSum)}'),
                          Text('Платіж ${info.dayOfMonth}-го числа, останній — ${fmtDate(info.last)}'),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (widget.item != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
            onPressed: () => Navigator.pop(context, _CreditEdit(name: '', amount: 0, delete: true)),
            child: const Text('Видалити'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
        FilledButton(onPressed: _ok, child: const Text('Зберегти')),
      ],
    );
  }
}

/// «Сколько осталось платежей и когда ближайший» → дата первого платежа.
class _RemainingDialog extends StatefulWidget {
  const _RemainingDialog();

  @override
  State<_RemainingDialog> createState() => _RemainingDialogState();
}

class _RemainingDialogState extends State<_RemainingDialog> {
  final TextEditingController _left = TextEditingController();
  DateTime _next = today();

  @override
  void dispose() {
    _left.dispose();
    super.dispose();
  }

  void _ok() {
    final v = int.tryParse(_left.text.trim());
    if (v == null || v <= 0 || v > 600) return;
    Navigator.pop(context, (v, _next));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Скільки залишилось'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _left,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Залишилось платежів (включно з найближчим)',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _ok(),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_outlined),
              label: Text('Найближчий платіж: ${fmtDate(_next)}'),
              onPressed: () async {
                final d = await pickDate(context, _next);
                if (d != null && mounted) setState(() => _next = d);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
        FilledButton(onPressed: _ok, child: const Text('Готово')),
      ],
    );
  }
}
