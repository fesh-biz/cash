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
                    title: 'Сегодня',
                    trailing: TextButton(
                      onPressed: () => showDaySheet(context, today()),
                      child: const Text('Подробнее'),
                    ),
                    children: [
                      if (todayList.isEmpty)
                        const ListTile(title: Text('Расходов пока нет')),
                      for (final e in todayList)
                        AmountTile(
                          title: e.note.isEmpty ? 'Расход' : e.note,
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
        label = 'Остаток на сегодня';
        value = s.todayBalance;
        if (value.round() >= 0) {
          sub = 'Столько ещё можно потратить сегодня, оставаясь в плане';
        } else {
          final back = s.backToPlusDate;
          sub = back != null
              ? 'Перерасход. Если не тратить, в плюс выйдете ${fmtDayLong(back)}'
              : 'Перерасход: до конца периода дневной лимит его не покроет';
        }
        chips.add('В день: ${money(s.perDay)}');
        chips.add('С учётом трат: ${money(s.perDayFromToday)}/день');
        chips.add('Осталось ${daysStr(s.daysLeft)}');
        if (s.spentToday != 0) chips.add('Сегодня: ${money(s.spentToday)}');
      case PeriodState.notStarted:
        label = 'Период ещё не начался';
        value = s.available;
        sub = 'Начнётся ${fmtDayLong(s.period.start)} · ${money(s.perDay)} в день';
      case PeriodState.finished:
        label = 'Период завершён';
        value = s.left;
        sub = value.round() >= 0 ? 'Сэкономлено за период' : 'Перерасход за период';
    }

    final negative = value.round() < 0;
    final bg = negative ? t.colorScheme.errorContainer : t.colorScheme.primaryContainer;
    final fg = negative ? t.colorScheme.onErrorContainer : t.colorScheme.onPrimaryContainer;

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
                label: const Text('Создать следующий период'),
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
          label: 'Доход',
          value: money(p.incomeUah),
          hint: '${numStr(p.incomeEur)} € × ${numStr(p.rate)}',
          onTap: () => onOpenTab(2),
        ),
        StatTile(
          label: 'Обязательные',
          value: money(s.fixedTotal),
          hint: fixedNames.isEmpty ? null : fixedNames,
          onTap: () => onOpenTab(2),
        ),
        StatTile(
          label: 'На кредиты',
          value: money(p.creditPlan),
          hint: creditLeft.round() > 0
              ? 'внесено ${money(deposited)} · ещё ${money(creditLeft)}'
              : 'внесено ${money(deposited)}',
          onTap: () => onOpenTab(1),
        ),
        StatTile(
          label: 'На период',
          value: money(s.available),
          hint: '${daysStr(p.days)} · ${money(s.perDay)}/день',
        ),
        StatTile(label: 'Потрачено', value: money(s.spent)),
        StatTile(
          label: 'Осталось',
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
                  child: Text('Пора снять показания счётчиков',
                      style: t.textTheme.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Сейчас коммуналка в бюджете — план ${money(plan)}. '
              'После ввода показаний подставится точная сумма.',
              style: t.textTheme.bodyMedium?.copyWith(color: fg),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () => showReadingEditor(context, date: today()),
                  child: const Text('Внести показания'),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: fg),
                  onPressed: onOpen,
                  child: const Text('Коммуналка'),
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
          Expanded(flex: 4, child: Text('Потрачено', style: style, textAlign: TextAlign.right)),
          Expanded(flex: 4, child: Text('Остаток', style: style, textAlign: TextAlign.right)),
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
                        message: 'С этого дня остаток в плюсе, если больше не тратить',
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
              Text('Учёт финансов', style: t.textTheme.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'Доход за период минус обязательные расходы и кредиты — '
                'это сумма на жизнь. Она делится на дни, а приложение показывает, '
                'сколько можно потратить сегодня.',
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('Перенести данные из таблицы'),
                onPressed: () {
                  final p = store.loadSample();
                  onSelectPeriod(p.id);
                },
              ),
              const SizedBox(height: 4),
              Text(
                'Период 10.10–09.11.2026: курс 51, 740 €, квартира, коммуналка, '
                'кредиты, расходы за 10–13 октября и показания счётчиков за 2026 год.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Создать новый период'),
                onPressed: () {
                  final p = store.createFirstPeriod(DateTime.now());
                  onSelectPeriod(p.id);
                  onOpenTab(2);
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.sync),
                label: const Text('Получить данные с другого устройства'),
                onPressed: () => onOpenTab(4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
