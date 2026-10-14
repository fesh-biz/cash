import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../logic/utilities.dart';
import '../util/format.dart';
import 'app_scope.dart';
import 'common.dart';
import 'reading_editor.dart';

/// Вкладка «Коммуналка»: сумма в периоде, показания счётчиков, тарифы.
class UtilitiesPage extends StatelessWidget {
  const UtilitiesPage({super.key, required this.period});

  final Period? period;

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).store;
    final config = store.utilityConfig;
    final readings = store.meterReadings;

    final periodCard = period == null ? null : _PeriodCard(period: period!);

    final planCard = SectionCard(
      title: 'Сумма по умолчанию',
      children: [
        AmountTile(
          title: 'План на месяц',
          subtitle: 'Идёт в бюджет, пока не внесены показания за период',
          amount: config.plan ?? 0,
          amountText: config.plan == null ? 'не задана' : money(config.plan!),
          onTap: () => editUtilityPlan(context),
        ),
      ],
    );

    final tariffsCard = _TariffsCard(config: config);

    final historyCard = SectionCard(
      title: 'Показания',
      trailing: IconButton(
        tooltip: 'Внести показания',
        icon: const Icon(Icons.add),
        onPressed: () => showReadingEditor(context),
      ),
      children: [
        if (readings.isEmpty) ...[
          const ListTile(title: Text('Показаний пока нет')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.table_chart_outlined),
              label: const Text('Перенести показания из таблицы'),
              onPressed: () {
                store.importMeterHistory();
                showSnack(context, 'Перенесены показания за январь–сентябрь 2026');
              },
            ),
          ),
        ],
        for (final m in readings.reversed) _ReadingTile(reading: m, bill: store.billFor(m)),
      ],
    );

    if (isWide(context)) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(children: [
                  if (periodCard != null) ...[periodCard, const SizedBox(height: 12)],
                  planCard,
                  const SizedBox(height: 12),
                  tariffsCard,
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(child: historyCard),
            ],
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        if (periodCard != null) ...[periodCard, const SizedBox(height: 12)],
        planCard,
        const SizedBox(height: 12),
        historyCard,
        const SizedBox(height: 12),
        tariffsCard,
      ],
    );
  }
}

/// Изменить сумму коммуналки по умолчанию.
Future<void> editUtilityPlan(BuildContext context) async {
  final store = AppScope.of(context).store;
  final config = store.utilityConfig;
  final p = store.defaultPeriod(DateTime.now());
  final current = config.plan ?? (p == null ? 0.0 : store.utilityStatus(p).plan);
  final v = await showNumberDialog(
    context,
    title: 'Коммуналка по умолчанию',
    initial: current,
    help: 'Эта сумма стоит в бюджете периода, пока не внесены показания счётчиков (28-го). '
        'Действует, пока вы её не поменяете. Летом обычно около 2 000 ₴, '
        'в отопительный сезон — 4–5 тыс.',
  );
  if (v != null) store.saveUtilityConfig(config.copyWith(plan: v));
}

/// Коммуналка в выбранном периоде: факт или план.
class _PeriodCard extends StatelessWidget {
  const _PeriodCard({required this.period});

  final Period period;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final store = AppScope.of(context).store;
    final item = store.utilitiesItemOf(period.id);
    final title = 'В периоде ${fmtRange(period.start, period.end)}';

    if (item == null) {
      return SectionCard(
        title: title,
        children: [
          const ListTile(
            title: Text('Коммуналка не подключена к этому периоду'),
            subtitle: Text('Сумма в бюджете периода не будет браться из показаний'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.link),
              label: const Text('Подключить'),
              onPressed: () => store.attachUtilities(period),
            ),
          ),
        ],
      );
    }

    final s = store.utilityStatus(period);
    final due = s.dueDate;
    final now = DateTime.now();
    final String status;
    if (s.isActual) {
      status = 'Факт по показаниям ${fmtDate(s.bill!.reading.date)}';
    } else if (s.reading != null) {
      status = 'План: показания ${fmtDate(s.reading!.date)} — первые, сравнивать не с чем';
    } else if (due != null && s.isDue(now)) {
      status = 'План. Пора снять показания (${fmtDayLong(due)})';
    } else if (due != null) {
      status = 'План, пока не внесены показания ${fmtDayLong(due)}';
    } else {
      status = 'План: в периоде нет 28-го числа';
    }

    final fg = s.isActual ? t.colorScheme.onPrimaryContainer : t.colorScheme.onSurface;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: s.isActual ? t.colorScheme.primaryContainer : t.colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.textTheme.titleSmall?.copyWith(color: fg)),
                  const SizedBox(height: 4),
                  Text(
                    s.isActual ? moneyCents(s.amount) : money(s.amount),
                    style: t.textTheme.displaySmall?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                      fontFeatures: tabular,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(status, style: t.textTheme.bodyMedium?.copyWith(color: fg)),
                ],
              ),
            ),
            if (s.bill != null) ...[
              const SizedBox(height: 4),
              UtilityBillLines(bill: s.bill!, tariffs: s.bill!.reading.tariffs),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (s.reading == null)
                    FilledButton.icon(
                      icon: const Icon(Icons.speed),
                      label: const Text('Внести показания'),
                      onPressed: () => showReadingEditor(context, date: _suggestDate(due, now)),
                    )
                  else
                    OutlinedButton.icon(
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Изменить показания'),
                      onPressed: () => showReadingEditor(context, existing: s.reading),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Дата по умолчанию: сегодня, если 28-е уже наступило или идёт другой
  /// период, иначе само 28-е число периода.
  static DateTime _suggestDate(DateTime? due, DateTime now) {
    final t = dateOnly(now);
    if (due == null) return t;
    return t.isBefore(due) ? due : t;
  }
}

class _ReadingTile extends StatelessWidget {
  const _ReadingTile({required this.reading, required this.bill});

  final MeterReading reading;
  final UtilityBill? bill;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = reading;
    final b = bill;
    final parts = <String>[
      if (b != null) ...[
        'вода ${numStr(b.waterUsed)} м³',
        'свет ${numStr(b.elUsed)} кВт·ч',
        if (b.heating > 0) 'отопл. ${money(b.heating)}',
      ] else
        'ванна ${numStr(m.bath)} · кухня ${numStr(m.kitchen)} · эл ${numStr(m.el)}',
    ];
    return ListTile(
      title: Text('${monthTitle(m.date)} · ${fmtDateShort(m.date)}'),
      subtitle: Text(parts.join(' · ')),
      trailing: Text(
        b == null ? 'база' : moneyCents(b.total),
        style: t.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
          fontFeatures: tabular,
          color: b == null ? t.colorScheme.onSurfaceVariant : (b.hasNegative ? t.colorScheme.error : null),
        ),
      ),
      onTap: () => showReadingEditor(context, existing: m),
    );
  }
}

class _TariffsCard extends StatelessWidget {
  const _TariffsCard({required this.config});

  final UtilityConfig config;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final store = AppScope.of(context).store;
    final tr = config.tariffs;

    Widget tile(String title, double value, String unit, UtilityTariffs Function(double v) apply) {
      return AmountTile(
        title: title,
        amount: value,
        amountText: '${moneyCents(value, currency: false)} $unit',
        onTap: () async {
          final v = await showNumberDialog(context, title: title, initial: value);
          if (v != null) _save(store, config.copyWith(tariffs: apply(v)));
        },
      );
    }

    return SectionCard(
      title: 'Тарифы',
      children: [
        tile('Абонплата: подача воды', tr.waterSubIn, '₴', (v) => tr.copyWith(waterSubIn: v)),
        tile('Абонплата: водоотведение', tr.waterSubOut, '₴', (v) => tr.copyWith(waterSubOut: v)),
        tile('Вода, за 1 м³', tr.cubeIn, '₴', (v) => tr.copyWith(cubeIn: v)),
        tile('Водоотведение, за 1 м³', tr.cubeOut, '₴', (v) => tr.copyWith(cubeOut: v)),
        tile('Электричество, за 1 кВт·ч', tr.kwh, '₴', (v) => tr.copyWith(kwh: v)),
        tile('Абонплата ЖКХ', tr.housing, '₴', (v) => tr.copyWith(housing: v)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'Новые тарифы применяются к новым показаниям. Суммы за прошлые месяцы не меняются.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  static void _save(Store store, UtilityConfig c) => store.saveUtilityConfig(c);
}
