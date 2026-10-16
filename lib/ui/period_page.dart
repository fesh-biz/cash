import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../logic/budget.dart';
import '../logic/utilities.dart';
import '../util/format.dart';
import 'app_scope.dart';
import 'common.dart';
import 'reading_editor.dart';
import 'utilities_page.dart';

/// Вкладка «Период»: даты, доход и курс, обязательные расходы, история периодов.
class PeriodPage extends StatelessWidget {
  const PeriodPage({super.key, required this.period, required this.onSelectPeriod, this.onOpenUtilities});

  final Period? period;
  final ValueChanged<String?> onSelectPeriod;

  /// Открыть вкладку «Коммуналка».
  final VoidCallback? onOpenUtilities;

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).store;
    final p = period;
    if (p == null) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Створити період'),
          onPressed: () => onSelectPeriod(store.createFirstPeriod(DateTime.now()).id),
        ),
      );
    }

    final fixed = store.fixedOf(p.id);
    final fixedTotal = fixed.fold<double>(0, (s, f) => s + f.amount);
    final available = p.incomeUah - fixedTotal - p.creditPlan;
    final perDay = p.days > 0 ? available / p.days : 0.0;
    final hasNext = store.periods.any((x) => x.start.isAfter(p.end));
    final t = Theme.of(context);

    final datesCard = SectionCard(
      title: 'Дати',
      children: [
        ListTile(
          leading: const Icon(Icons.date_range_outlined),
          title: Text('${fmtDate(p.start)} – ${fmtDate(p.end)}'),
          subtitle: Text(daysStr(p.days)),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => _editDates(context, store, p),
        ),
      ],
    );

    final incomeCard = SectionCard(
      title: 'Дохід',
      children: [
        AmountTile(
          title: 'На місяць, €',
          amount: p.incomeEur,
          amountText: '${numStr(p.incomeEur)} €',
          onTap: () async {
            final v = await showNumberDialog(context, title: 'Дохід у євро', initial: p.incomeEur, suffix: '€');
            if (v != null) store.savePeriod(p.copyWith(incomeEur: v));
          },
        ),
        AmountTile(
          title: 'Курс, ₴ за €',
          amount: p.rate,
          amountText: numStr(p.rate),
          onTap: () async {
            final v = await showNumberDialog(context, title: 'Курс євро', initial: p.rate, suffix: '₴');
            if (v != null) store.savePeriod(p.copyWith(rate: v));
          },
        ),
        const Divider(indent: 16, endIndent: 16),
        AmountTile(title: 'У гривнях', amount: p.incomeUah, bold: true),
      ],
    );

    final fixedCard = SectionCard(
      title: 'Обов’язкові витрати',
      trailing: IconButton(
        tooltip: 'Додати',
        icon: const Icon(Icons.add),
        onPressed: () => _editFixed(context, store, p, null, fixed.length),
      ),
      children: [
        if (fixed.isEmpty) const ListTile(title: Text('Немає обов’язкових витрат')),
        for (final f in fixed)
          if (f.isUtilities)
            AmountTile(
              title: f.name.isEmpty ? 'Комуналка' : f.name,
              amount: f.amount,
              subtitle: f.isActual && f.readingDate != null
                  ? 'за показниками ${fmtDate(f.readingDate!)}'
                  : 'план · уточниться за показниками${_dueSuffix(p)}',
              leading: Icon(f.isActual ? Icons.check_circle_outline : Icons.schedule,
                  color: f.isActual ? positiveColor(context) : t.colorScheme.onSurfaceVariant),
              onTap: () => _utilitiesActions(context, store, p, f),
            )
          else
            AmountTile(
              title: f.name.isEmpty ? 'Без назви' : f.name,
              amount: f.amount,
              onTap: () => _editFixed(context, store, p, f, f.order),
            ),
        AmountTile(
          title: 'Кредити (плачу)',
          amount: p.creditPlan,
          subtitle: 'детальніше — на вкладці «Кредити»',
          onTap: () async {
            final v = await showNumberDialog(context, title: 'Плачу на кредити', initial: p.creditPlan);
            if (v != null) store.savePeriod(p.copyWith(creditPlan: v));
          },
        ),
        const Divider(indent: 16, endIndent: 16),
        AmountTile(title: 'Усього', amount: fixedTotal + p.creditPlan, bold: true),
      ],
    );

    final resultCard = SectionCard(
      title: 'Підсумок',
      children: [
        AmountTile(
          title: 'Залишок на період',
          amount: available,
          bold: true,
          color: balanceColor(context, available),
        ),
        AmountTile(title: 'На день', amount: perDay, bold: true, color: balanceColor(context, perDay)),
      ],
    );

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (!hasNext)
          FilledButton.tonalIcon(
            icon: const Icon(Icons.skip_next),
            label: const Text('Створити наступний період'),
            onPressed: () {
              final next = store.createNextPeriod(p);
              onSelectPeriod(next.id);
              showSnack(context, 'Створено період ${fmtRange(next.start, next.end)}');
            },
          ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: t.colorScheme.error),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Видалити період'),
          onPressed: () async {
            final ok = await confirm(
              context,
              'Видалити період?',
              'Буде видалено налаштування періоду ${fmtRange(p.start, p.end)}, обов’язкові витрати '
                  'і кредити. Щоденні витрати залишаться.',
            );
            if (!ok) return;
            store.deletePeriod(p.id);
            onSelectPeriod(null);
          },
        ),
      ],
    );

    final history = _History(current: p, onSelect: onSelectPeriod);

    if (isWide(context)) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(children: [
                  datesCard,
                  const SizedBox(height: 12),
                  incomeCard,
                  const SizedBox(height: 12),
                  resultCard,
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(children: [
                  fixedCard,
                  const SizedBox(height: 12),
                  history,
                ]),
              ),
            ],
          ),
          const SizedBox(height: 16),
          actions,
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        datesCard,
        const SizedBox(height: 12),
        incomeCard,
        const SizedBox(height: 12),
        fixedCard,
        const SizedBox(height: 12),
        resultCard,
        const SizedBox(height: 16),
        actions,
        const SizedBox(height: 16),
        history,
      ],
    );
  }

  Future<void> _editDates(BuildContext context, Store store, Period p) async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: p.start, end: p.end),
      helpText: 'Дати періоду',
      saveText: 'Зберегти',
    );
    if (r == null) return;
    final start = dateOnly(r.start);
    final end = dateOnly(r.end);
    final overlap = store.periods.where((x) => x.id != p.id).where(
          (x) => !(end.isBefore(x.start) || start.isAfter(x.end)),
        );
    if (overlap.isNotEmpty) {
      final o = overlap.first;
      if (context.mounted) {
        showSnack(context, 'Перетинається з періодом ${fmtRange(o.start, o.end)}');
      }
      return;
    }
    store.savePeriod(p.copyWith(start: start, end: end));
  }

  Future<void> _editFixed(BuildContext context, Store store, Period p, FixedExpense? f, int order) async {
    final r = await showItemDialog(
      context,
      title: f == null ? 'Обов’язкова витрата' : f.name,
      name: f?.name ?? '',
      amount: f?.amount,
      nameLabel: 'Назва (наприклад, «Квартира»)',
      canDelete: f != null,
    );
    if (r == null) return;
    if (r.delete) {
      final id = f!.id;
      store.remove(id);
      if (context.mounted) showSnack(context, 'Видалено', undo: () => store.restore(id));
      return;
    }
    final kind = f != null
        ? (f.kind.isEmpty ? FixedKind.manual : f.kind)
        : (isUtilitiesName(r.name) ? FixedKind.utilities : FixedKind.manual);
    store.saveFixed(FixedExpense(
      id: f?.id ?? Store.newId(),
      periodId: p.id,
      name: r.name,
      amount: r.amount,
      order: order,
      kind: kind,
    ));
  }

  static String _dueSuffix(Period p) {
    final d = meterDateIn(p);
    return d == null ? '' : ' ${fmtDateShort(d)}';
  }

  /// Коммуналка считается сама — вместо ввода суммы предлагаем действия.
  Future<void> _utilitiesActions(BuildContext context, Store store, Period p, FixedExpense f) async {
    final s = store.utilityStatus(p);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(f.name.isEmpty ? 'Комуналка' : f.name),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(s.isActual
                ? 'Суму пораховано за показниками лічильників: ${moneyCents(s.amount)}.'
                : 'Поки показників за період немає, у бюджеті стоїть сума за замовчуванням: ${money(s.plan)}.'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'reading'),
            child: ListTile(
              leading: const Icon(Icons.speed),
              title: Text(s.reading == null ? 'Внести показники' : 'Змінити показники'),
            ),
          ),
          if (!s.isActual)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'plan'),
              child: const ListTile(leading: Icon(Icons.edit_outlined), title: Text('Змінити суму за замовчуванням')),
            ),
          if (onOpenUtilities != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'open'),
              child: const ListTile(leading: Icon(Icons.receipt_long_outlined), title: Text('Відкрити «Комуналка»')),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'manual'),
            child: const ListTile(
              leading: Icon(Icons.link_off),
              title: Text('Вводити вручну'),
              subtitle: Text('Відключити від показників у цьому періоді'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: const Text('Видалити рядок'),
            ),
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'reading':
        await showReadingEditor(context, existing: s.reading, date: meterDateIn(p) ?? today());
      case 'plan':
        await editUtilityPlan(context);
      case 'open':
        onOpenUtilities?.call();
      case 'manual':
        store.saveFixed(FixedExpense(
          id: f.id,
          periodId: f.periodId,
          name: f.name,
          amount: f.amount,
          order: f.order,
          kind: FixedKind.manual,
        ));
        showSnack(context, 'Комуналка в цьому періоді тепер вводиться вручну');
      case 'delete':
        store.remove(f.id);
        showSnack(context, 'Видалено', undo: () => store.restore(f.id));
    }
  }
}

class _History extends StatelessWidget {
  const _History({required this.current, required this.onSelect});

  final Period current;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).store;
    final t = Theme.of(context);
    final all = store.periods.reversed.toList();
    final now = DateTime.now();
    return SectionCard(
      title: 'Усі періоди',
      children: [
        for (final x in all)
          Builder(builder: (context) {
            final s = PeriodSummary.compute(x, store.fixedOf(x.id), store.expensesBetween(x.start, x.end), now);
            final status = switch (s.state) {
              PeriodState.active => 'триває зараз',
              PeriodState.notStarted => 'ще не почався',
              PeriodState.finished => s.left.round() >= 0 ? 'заощаджено' : 'перевитрата',
            };
            return ListTile(
              selected: x.id == current.id,
              selectedTileColor: t.colorScheme.secondaryContainer.withAlpha(110),
              leading: Icon(x.contains(now) ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(fmtRange(x.start, x.end)),
              subtitle: Text('Витрачено ${money(s.spent)} · $status'),
              trailing: Text(
                money(s.left),
                style: t.textTheme.titleSmall?.copyWith(
                  color: balanceColor(context, s.left),
                  fontFeatures: tabular,
                ),
              ),
              onTap: () => onSelect(x.contains(now) ? null : x.id),
            );
          }),
      ],
    );
  }
}
