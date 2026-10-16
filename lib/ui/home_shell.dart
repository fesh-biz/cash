import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../util/format.dart';
import 'app_scope.dart';
import 'credits_page.dart';
import 'expense_editor.dart';
import 'overview_page.dart';
import 'period_page.dart';
import 'sync_page.dart';
import 'utilities_page.dart';

/// Главный экран: навигация снизу (телефон) или сбоку (Windows/планшет).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  /// Выбранный период; null — текущий по дате.
  String? _periodId;

  static const _destinations = [
    (Icons.today_outlined, Icons.today, 'Бюджет'),
    (Icons.credit_card_outlined, Icons.credit_card, 'Кредити'),
    (Icons.tune_outlined, Icons.tune, 'Період'),
    (Icons.receipt_long_outlined, Icons.receipt_long, 'Комуналка'),
    (Icons.sync_outlined, Icons.sync, 'Синхронізація'),
  ];

  void _goTab(int i) => setState(() => _tab = i);

  void _selectPeriod(String? id) => setState(() => _periodId = id);

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final store = scope.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final now = DateTime.now();
        final period = store.periodById(_periodId) ?? store.defaultPeriod(now);
        final isCurrent = period != null && period.contains(now);
        final utilitiesDue = _utilitiesDue(now);

        // Значок вкладки; на «Коммуналке» — точка, когда пора снять показания.
        Widget navIcon(int i, {required bool selected}) {
          final d = _destinations[i];
          final icon = Icon(selected ? d.$2 : d.$1);
          if (i != _utilitiesTab) return icon;
          return Badge(isLabelVisible: utilitiesDue, child: icon);
        }

        final pages = <Widget>[
          OverviewPage(
            period: period,
            onOpenTab: _goTab,
            onSelectPeriod: _selectPeriod,
          ),
          CreditsPage(period: period),
          PeriodPage(period: period, onSelectPeriod: _selectPeriod, onOpenUtilities: () => _goTab(_utilitiesTab)),
          UtilitiesPage(period: period),
          const SyncPage(),
        ];

        final wide = MediaQuery.sizeOf(context).width >= 840;
        final body = IndexedStack(index: _tab, children: pages);

        final fab = (_tab == 0 && period != null)
            ? FloatingActionButton.extended(
                onPressed: () => showExpenseEditor(context, date: _defaultExpenseDate(period)),
                icon: const Icon(Icons.add),
                label: const Text('Витрата'),
                tooltip: 'Додати витрату (Ctrl+N)',
              )
            : null;

        final appBar = AppBar(
          title: _PeriodTitle(
            period: period,
            isCurrent: isCurrent,
            title: _destinations[_tab].$3,
            onSelect: _selectPeriod,
          ),
          actions: const [_SyncButton(), SizedBox(width: 8)],
        );

        Widget scaffold;
        if (wide) {
          scaffold = Scaffold(
            appBar: appBar,
            floatingActionButton: fab,
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: _tab,
                  onDestinationSelected: _goTab,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (var i = 0; i < _destinations.length; i++)
                      NavigationRailDestination(
                        icon: navIcon(i, selected: false),
                        selectedIcon: navIcon(i, selected: true),
                        label: Text(_destinations[i].$3),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          );
        } else {
          scaffold = Scaffold(
            appBar: appBar,
            floatingActionButton: fab,
            body: body,
            // На телефоне внизу только иконки: подписи не помещаются,
            // а название вкладки и так написано в заголовке страницы.
            bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: _goTab,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
              height: 64,
              destinations: [
                for (var i = 0; i < _destinations.length; i++)
                  NavigationDestination(
                    icon: navIcon(i, selected: false),
                    selectedIcon: navIcon(i, selected: true),
                    label: _destinations[i].$3,
                  ),
              ],
            ),
          );
        }

        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
              if (period != null) showExpenseEditor(context, date: _defaultExpenseDate(period));
            },
            const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => _goTab(0),
            const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => _goTab(1),
            const SingleActivator(LogicalKeyboardKey.digit3, control: true): () => _goTab(2),
            const SingleActivator(LogicalKeyboardKey.digit4, control: true): () => _goTab(3),
            const SingleActivator(LogicalKeyboardKey.digit5, control: true): () => _goTab(4),
          },
          child: Focus(autofocus: true, child: scaffold),
        );
      },
    );
  }

  static const _utilitiesTab = 3;

  /// В текущем периоде наступило 28-е, а показаний ещё нет.
  bool _utilitiesDue(DateTime now) {
    final store = AppScope.of(context).store;
    final p = store.periodFor(now);
    if (p == null || store.utilitiesItemOf(p.id) == null) return false;
    return store.utilityStatus(p).isDue(now);
  }

  DateTime _defaultExpenseDate(Period p) {
    final t = today();
    if (p.contains(t)) return t;
    return t.isBefore(p.start) ? p.start : p.end;
  }
}

class _PeriodTitle extends StatelessWidget {
  const _PeriodTitle({required this.period, required this.isCurrent, required this.title, required this.onSelect});

  final Period? period;
  final bool isCurrent;
  final String title;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).store;
    final p = period;
    if (p == null) return Text(title);
    final t = Theme.of(context);
    final all = store.periods.reversed.toList();
    return PopupMenuButton<String>(
      tooltip: 'Вибрати період',
      onSelected: (id) => onSelect(id == '__current' ? null : id),
      itemBuilder: (ctx) => [
        const PopupMenuItem(value: '__current', child: Text('Поточний період')),
        const PopupMenuDivider(),
        for (final x in all)
          CheckedPopupMenuItem(
            value: x.id,
            checked: x.id == p.id,
            child: Text(fmtRange(x.start, x.end)),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, overflow: TextOverflow.ellipsis),
                Text(
                  '${fmtRange(p.start, p.end)}${isCurrent ? '' : ' · не поточний'}',
                  style: t.textTheme.bodySmall?.copyWith(
                    color: isCurrent ? t.colorScheme.onSurfaceVariant : t.colorScheme.tertiary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }
}

/// Кнопка синхронизации в шапке: показывает состояние.
class _SyncButton extends StatelessWidget {
  const _SyncButton();

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final t = Theme.of(context);
        Widget icon;
        String tip;
        if (sync.anyBusy) {
          icon = const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
          tip = 'Синхронізація…';
        } else if (!sync.hasKey) {
          icon = Icon(Icons.sync_disabled, color: t.colorScheme.onSurfaceVariant);
          tip = 'Синхронізацію не налаштовано';
        } else if (sync.hasErrors) {
          icon = Icon(Icons.sync_problem, color: t.colorScheme.error);
          tip = 'Є помилки синхронізації';
        } else if (sync.peers.values.any((p) => p.lastSync != null)) {
          final last = sync.peers.values
              .map((p) => p.lastSync)
              .whereType<DateTime>()
              .reduce((a, b) => a.isAfter(b) ? a : b);
          icon = Icon(Icons.cloud_done_outlined, color: t.colorScheme.primary);
          tip = 'Синхронізовано: ${fmtTimeAgo(last)}';
        } else {
          icon = const Icon(Icons.sync);
          tip = 'Синхронізувати';
        }
        return IconButton(
          tooltip: tip,
          icon: icon,
          onPressed: sync.hasKey ? () => sync.syncAll(force: true) : null,
        );
      },
    );
  }
}
