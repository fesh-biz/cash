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
          label: const Text('Создать период'),
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
      title: 'Даты',
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
      title: 'Доход',
      children: [
        AmountTile(
          title: 'В месяц, €',
          amount: p.incomeEur,
          amountText: '${numStr(p.incomeEur)} €',
          onTap: () async {
            final v = await showNumberDialog(context, title: 'Доход в евро', initial: p.incomeEur, suffix: '€');
            if (v != null) store.savePeriod(p.copyWith(incomeEur: v));
          },
        ),
        AmountTile(
          title: 'Курс, ₴ за €',
          amount: p.rate,
          amountText: numStr(p.rate),
          onTap: () async {
            final v = await showNumberDialog(context, title: 'Курс евро', initial: p.rate, suffix: '₴');
            if (v != null) store.savePeriod(p.copyWith(rate: v));
          },
        ),
        const Divider(indent: 16, endIndent: 16),
        AmountTile(title: 'В гривнах', amount: p.incomeUah, bold: true),
      ],
    );

    final fixedCard = SectionCard(
      title: 'Обязательные расходы',
      trailing: IconButton(
        tooltip: 'Добавить',
        icon: const Icon(Icons.add),
        onPressed: () => _editFixed(context, store, p, null, fixed.length),
      ),
      children: [
        if (fixed.isEmpty) const ListTile(title: Text('Нет обязательных расходов')),
        for (final f in fixed)
          if (f.isUtilities)
            AmountTile(
              title: f.name.isEmpty ? 'Коммуналка' : f.name,
              amount: f.amount,
              subtitle: f.isActual && f.readingDate != null
                  ? 'по показаниям ${fmtDate(f.readingDate!)}'
                  : 'план · уточнится по показаниям${_dueSuffix(p)}',
              leading: Icon(f.isActual ? Icons.check_circle_outline : Icons.schedule,
                  color: f.isActual ? positiveColor(context) : t.colorScheme.onSurfaceVariant),
              onTap: () => _utilitiesActions(context, store, p, f),
            )
          else
            AmountTile(
              title: f.name.isEmpty ? 'Без названия' : f.name,
              amount: f.amount,
              onTap: () => _editFixed(context, store, p, f, f.order),
            ),
        AmountTile(
          title: 'Кредиты (плачу)',
          amount: p.creditPlan,
          subtitle: 'подробнее — на вкладке «Кредиты»',
          onTap: () async {
            final v = await showNumberDialog(context, title: 'Плачу на кредиты', initial: p.creditPlan);
            if (v != null) store.savePeriod(p.copyWith(creditPlan: v));
          },
        ),
        const Divider(indent: 16, endIndent: 16),
        AmountTile(title: 'Всего', amount: fixedTotal + p.creditPlan, bold: true),
      ],
    );

    final resultCard = SectionCard(
      title: 'Итог',
      children: [
        AmountTile(
          title: 'Остаток на период',
          amount: available,
          bold: true,
          color: balanceColor(context, available),
        ),
        AmountTile(title: 'В день', amount: perDay, bold: true, color: balanceColor(context, perDay)),
      ],
    );

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (!hasNext)
          FilledButton.tonalIcon(
            icon: const Icon(Icons.skip_next),
            label: const Text('Создать следующий период'),
            onPressed: () {
              final next = store.createNextPeriod(p);
              onSelectPeriod(next.id);
              showSnack(context, 'Создан период ${fmtRange(next.start, next.end)}');
            },
          ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: t.colorScheme.error),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Удалить период'),
          onPressed: () async {
            final ok = await confirm(
              context,
              'Удалить период?',
              'Будут удалены настройки периода ${fmtRange(p.start, p.end)}, обязательные расходы '
                  'и кредиты. Ежедневные расходы останутся.',
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
      helpText: 'Даты периода',
      saveText: 'Сохранить',
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
        showSnack(context, 'Пересекается с периодом ${fmtRange(o.start, o.end)}');
      }
      return;
    }
    store.savePeriod(p.copyWith(start: start, end: end));
  }

  Future<void> _editFixed(BuildContext context, Store store, Period p, FixedExpense? f, int order) async {
    final r = await showItemDialog(
      context,
      title: f == null ? 'Обязательный расход' : f.name,
      name: f?.name ?? '',
      amount: f?.amount,
      nameLabel: 'Название (например, «Квартира»)',
      canDelete: f != null,
    );
    if (r == null) return;
    if (r.delete) {
      final id = f!.id;
      store.remove(id);
      if (context.mounted) showSnack(context, 'Удалено', undo: () => store.restore(id));
      return;
    }
    final kind = f != null
        ? (f.kind.isEmpty ? FixedKind.manual : f.kind)
        : (r.name.toLowerCase().contains('коммунал') ? FixedKind.utilities : FixedKind.manual);
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
        title: Text(f.name.isEmpty ? 'Коммуналка' : f.name),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(s.isActual
                ? 'Сумма посчитана по показаниям счётчиков: ${moneyCents(s.amount)}.'
                : 'Пока показаний за период нет, в бюджете стоит сумма по умолчанию: ${money(s.plan)}.'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'reading'),
            child: ListTile(
              leading: const Icon(Icons.speed),
              title: Text(s.reading == null ? 'Внести показания' : 'Изменить показания'),
            ),
          ),
          if (!s.isActual)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'plan'),
              child: const ListTile(leading: Icon(Icons.edit_outlined), title: Text('Изменить сумму по умолчанию')),
            ),
          if (onOpenUtilities != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'open'),
              child: const ListTile(leading: Icon(Icons.water_drop_outlined), title: Text('Открыть «Коммуналка»')),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'manual'),
            child: const ListTile(
              leading: Icon(Icons.link_off),
              title: Text('Вводить вручную'),
              subtitle: Text('Отключить от показаний в этом периоде'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: const Text('Удалить строку'),
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
        showSnack(context, 'Коммуналка в этом периоде теперь вводится вручную');
      case 'delete':
        store.remove(f.id);
        showSnack(context, 'Удалено', undo: () => store.restore(f.id));
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
      title: 'Все периоды',
      children: [
        for (final x in all)
          Builder(builder: (context) {
            final s = PeriodSummary.compute(x, store.fixedOf(x.id), store.expensesBetween(x.start, x.end), now);
            final status = switch (s.state) {
              PeriodState.active => 'идёт сейчас',
              PeriodState.notStarted => 'ещё не начался',
              PeriodState.finished => s.left.round() >= 0 ? 'сэкономлено' : 'перерасход',
            };
            return ListTile(
              selected: x.id == current.id,
              selectedTileColor: t.colorScheme.secondaryContainer.withAlpha(110),
              leading: Icon(x.contains(now) ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(fmtRange(x.start, x.end)),
              subtitle: Text('Потрачено ${money(s.spent)} · $status'),
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
