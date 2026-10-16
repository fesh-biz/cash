import 'package:flutter/material.dart';

import '../data/models.dart';
import '../logic/budget.dart';
import '../util/format.dart';
import 'app_scope.dart';
import 'common.dart';
import 'expense_editor.dart';
import 'reading_editor.dart';

/// Вкладка «Бюджет»: главное число дня, сводка и таблица по дням.
class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.period,
    required this.onOpenTab,
    required this.onSelectPeriod,
  });

  final Period? period;
  final ValueChanged<int> onOpenTab;
  final ValueChanged<String?> onSelectPeriod;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  static const double _rowHeight = 48;
  final ScrollController _tableScroll = ScrollController();
  String? _scrolledFor;

  @override
  void dispose() {
    _tableScroll.dispose();
    super.dispose();
  }

  void _scrollToToday(PeriodSummary s) {
    final key = '${s.period.id}:${s.todayIndex}';
    if (_scrolledFor == key || s.todayIndex == null) return;
    _scrolledFor = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_tableScroll.hasClients) return;
      final target = (s.todayIndex! - 3) * _rowHeight;
      final maxExtent = _tableScroll.position.maxScrollExtent;
      _tableScroll.jumpTo(target.clamp(0.0, maxExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).store;
    final period = widget.period;
    if (period == null) {
      return _Welcome(onOpenTab: widget.onOpenTab, onSelectPeriod: widget.onSelectPeriod);
    }
    final summary = PeriodSummary.compute(
      period,
      store.fixedOf(period.id),
      store.expensesBetween(period.start, period.end),
      DateTime.now(),
    );
    final hasNext = store.periods.any((p) => p.start.isAfter(period.end));

    final hero = _Hero(
      summary: summary,
      onCreateNext: hasNext
          ? null
          : () {
              final next = store.createNextPeriod(period);
              widget.onSelectPeriod(next.id);
            },
    );
    final stats = _Stats(summary: summary, onOpenTab: widget.onOpenTab);
    final util = store.utilitiesItemOf(period.id) == null ? null : store.utilityStatus(period);
    final reminder = (util != null && summary.state == PeriodState.active && util.isDue(DateTime.now()))
        ? _UtilityReminder(plan: util.plan, onOpen: () => widget.onOpenTab(3))
        : null;

    if (isWide(context)) {
      _scrollToToday(summary);
      final todayList = summary.state == PeriodState.active ? store.expensesOn(today()) : const <Expense>[];
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 420,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 96),
              children: [
                hero,
                if (reminder != null) ...[const SizedBox(height: 12), reminder],
                const SizedBox(height: 12),
                stats,
                if (summary.state == PeriodState.active) ...[
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'Сьогодні',
                    trailing: TextButton(
                      onPressed: () => showDaySheet(context, today()),
                      child: const Text('Детальніше'),
                    ),
                    children: [
                      if (todayList.isEmpty)
                        const ListTile(title: Text('Витрат поки немає')),
                      for (final e in todayList)
                        AmountTile(
                          title: e.note.isEmpty ? 'Витрата' : e.note,
                          amount: e.amount,
                          onTap: () => showExpenseEditor(context, existing: e),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 16, 16),
              child: SectionCard(
                padding: EdgeInsets.zero,
                children: [
                  const _DaysHeader(),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      controller: _tableScroll,
                      padding: const EdgeInsets.only(bottom: 80),
                      itemExtent: _rowHeight,
                      itemCount: summary.rows.length,
                      itemBuilder: (context, i) => _DayRowTile(row: summary.rows[i], summary: summary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: [
        hero,
        if (reminder != null) ...[const SizedBox(height: 12), reminder],
        const SizedBox(height: 12),
        stats,
        const SizedBox(height: 12),
        SectionCard(
          padding: EdgeInsets.zero,
          children: [
            const _DaysHeader(),
            const Divider(height: 1),
            for (final r in summary.rows)
              SizedBox(height: _rowHeight, child: _DayRowTile(row: r, summary: summary)),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- главное число

class _Hero extends StatelessWidget {
  const _Hero({required this.summary, this.onCreateNext});

  final PeriodSummary summary;
  final VoidCallback? onCreateNext;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = summary;
    var label = '';
    var value = 0.0;
    var sub = '';
    final chips = <String>[];

    switch (s.state) {
      case PeriodState.active:
        label = 'Залишок на сьогодні';
        value = s.todayBalance;
        if (value.round() >= 0) {
          sub = 'Стільки ще можна витратити сьогодні, не виходячи за план';
        } else {
          final back = s.backToPlusDate;
          sub = back != null
              ? 'Перевитрата. Якщо не витрачати, вийдете в плюс ${fmtDayLong(back)}'
              : 'Перевитрата: до кінця періоду денний ліміт її не покриє';
        }
        chips.add('На день: ${money(s.perDay)}');
        chips.add('З урахуванням витрат: ${money(s.perDayFromToday)}/день');
        final toPlus = s.daysToPlus;
        chips.add(toPlus != null ? 'У плюс через ${daysStr(toPlus)}' : 'Залишилось ${daysStr(s.daysLeft)}');
        if (s.spentToday != 0) chips.add('Сьогодні: ${money(s.spentToday)}');
      case PeriodState.notStarted:
        label = 'Період ще не почався';
        value = s.available;
        sub = 'Почнеться ${fmtDayLong(s.period.start)} · ${money(s.perDay)} на день';
      case PeriodState.finished:
        label = 'Період завершено';
        value = s.left;
        sub = value.round() >= 0 ? 'Заощаджено за період' : 'Перевитрата за період';
    }

    // Карточка всегда в основных (голубых) тонах приложения, и при перерасходе тоже.
    final bg = t.colorScheme.primaryContainer;
    final fg = t.colorScheme.onPrimaryContainer;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: t.textTheme.titleSmall?.copyWith(color: fg)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                money(value),
                style: t.textTheme.displayMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontFeatures: tabular,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(sub, style: t.textTheme.bodyMedium?.copyWith(color: fg)),
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in chips)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: fg.withAlpha(24),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(c, style: t.textTheme.labelLarge?.copyWith(color: fg, fontFeatures: tabular)),
                    ),
                ],
              ),
            ],
            if (s.state == PeriodState.finished && onCreateNext != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onCreateNext,
                icon: const Icon(Icons.skip_next),
                label: const Text('Створити наступний період'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- сводка

class _Stats extends StatelessWidget {
  const _Stats({required this.summary, required this.onOpenTab});

  final PeriodSummary summary;
  final ValueChanged<int> onOpenTab;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final p = s.period;
    final store = AppScope.of(context).store;
    final fixedNames = store
        .fixedOf(p.id)
        .where((f) => f.name.isNotEmpty)
        .map((f) => f.isUtilities && !f.isActual ? '${f.name} (план)' : f.name)
        .join(', ');
    final deposited = store.depositsOf(p.id).fold<double>(0, (sum, d) => sum + d.amount);
    final creditLeft = p.creditPlan - deposited;
    return StatGrid(
      minTileWidth: 150,
      children: [
        StatTile(
          label: 'Дохід',
          value: money(p.incomeUah),
          hint: '${numStr(p.incomeEur)} € × ${numStr(p.rate)}',
          onTap: () => onOpenTab(2),
        ),
        StatTile(
          label: 'Обов’язкові',
          value: money(s.fixedTotal),
          hint: fixedNames.isEmpty ? null : fixedNames,
          onTap: () => onOpenTab(2),
        ),
        StatTile(
          label: 'На кредити',
          value: money(p.creditPlan),
          hint: creditLeft.round() > 0
              ? 'внесено ${money(deposited)} · ще ${money(creditLeft)}'
              : 'внесено ${money(deposited)}',
          onTap: () => onOpenTab(1),
        ),
        StatTile(
          label: 'На період',
          value: money(s.available),
          hint: '${daysStr(p.days)} · ${money(s.perDay)}/день',
        ),
        StatTile(label: 'Витрачено', value: money(s.spent)),
        StatTile(
          label: 'Залишилось',
          value: money(s.left),
          color: balanceColor(context, s.left),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- напоминание

/// 28-е наступило, а показаний за период ещё нет.
class _UtilityReminder extends StatelessWidget {
  const _UtilityReminder({required this.plan, required this.onOpen});

  final double plan;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fg = t.colorScheme.onTertiaryContainer;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: t.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.speed, color: fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Час зняти показники лічильників',
                      style: t.textTheme.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Зараз комуналка в бюджеті — план ${money(plan)}. '
              'Після введення показників підставиться точна сума.',
              style: t.textTheme.bodyMedium?.copyWith(color: fg),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () => showReadingEditor(context, date: today()),
                  child: const Text('Внести показники'),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: fg),
                  onPressed: onOpen,
                  child: const Text('Комуналка'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- таблица дней

class _DaysHeader extends StatelessWidget {
  const _DaysHeader();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text('День', style: style)),
          Expanded(flex: 4, child: Text('Витрачено', style: style, textAlign: TextAlign.right)),
          Expanded(flex: 4, child: Text('Залишок', style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class _DayRowTile extends StatelessWidget {
  const _DayRowTile({required this.row, required this.summary});

  final DayRow row;
  final PeriodSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ti = summary.todayIndex;
    final isToday = ti == row.index;
    final plusDate = summary.backToPlusDate;
    final isPlusDay = plusDate != null && sameDay(plusDate, row.date);
    final isFuture = summary.state == PeriodState.notStarted || (ti != null && row.index > ti);
    final weekend = row.date.weekday >= 6;

    final baseStyle = t.textTheme.bodyLarge?.copyWith(
      fontFeatures: tabular,
      fontWeight: isToday || isPlusDay ? FontWeight.w700 : FontWeight.w400,
    );
    final muted = t.colorScheme.onSurfaceVariant;

    final plusColor = positiveColor(context);

    return Material(
      color: isToday
          ? t.colorScheme.secondaryContainer
          : isPlusDay
              ? plusColor.withAlpha(28)
              : Colors.transparent,
      shape: isPlusDay
          ? Border.symmetric(horizontal: BorderSide(color: plusColor.withAlpha(140)))
          : null,
      child: InkWell(
        onTap: () => showDaySheet(context, row.date),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text(
                        fmtWeekday(row.date),
                        style: t.textTheme.labelMedium?.copyWith(
                          color: weekend ? t.colorScheme.tertiary : muted,
                        ),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        fmtDay(row.date),
                        style: baseStyle,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isPlusDay) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: 'З цього дня залишок у плюсі, якщо більше не витрачати',
                        child: Icon(Icons.flag, size: 16, color: plusColor),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  row.count == 0 ? '—' : money(row.spent, currency: false),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: baseStyle?.copyWith(color: row.count == 0 ? muted.withAlpha(120) : null),
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  money(row.balance, currency: false),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: baseStyle?.copyWith(
                    color: isPlusDay
                        ? plusColor
                        : isFuture
                            ? muted
                            : balanceColor(context, row.balance),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- первый запуск

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onOpenTab, required this.onSelectPeriod});

  final ValueChanged<int> onOpenTab;
  final ValueChanged<String?> onSelectPeriod;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final store = AppScope.of(context).store;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.account_balance_wallet_outlined, size: 56, color: t.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Облік фінансів', style: t.textTheme.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'Дохід за період мінус обов’язкові витрати й кредити — '
                'це сума на життя. Вона ділиться на дні, а застосунок показує, '
                'скільки можна витратити сьогодні.',
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('Перенести дані з таблиці'),
                onPressed: () {
                  final p = store.loadSample();
                  onSelectPeriod(p.id);
                },
              ),
              const SizedBox(height: 4),
              Text(
                'Період 10.10–09.11.2026: курс 51, 740 €, квартира, комуналка, '
                'кредити, витрати за 10–13 жовтня і показники лічильників за 2026 рік.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Створити новий період'),
                onPressed: () {
                  final p = store.createFirstPeriod(DateTime.now());
                  onSelectPeriod(p.id);
                  onOpenTab(2);
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.sync),
                label: const Text('Отримати дані з іншого пристрою'),
                onPressed: () => onOpenTab(4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
