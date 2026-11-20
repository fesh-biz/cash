import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/format.dart';
import 'app_scope.dart';
import 'common.dart';

/// Форма добавления/правки расхода.
Future<void> showExpenseEditor(BuildContext context, {Expense? existing, DateTime? date}) async {
  await showAdaptiveSheet<void>(
    context,
    (ctx) => _ExpenseForm(existing: existing, date: existing?.date ?? date ?? today()),
  );
}

class _ExpenseForm extends StatefulWidget {
  const _ExpenseForm({this.existing, required this.date});

  final Expense? existing;
  final DateTime date;

  @override
  State<_ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<_ExpenseForm> {
  late final TextEditingController _amount =
      TextEditingController(text: widget.existing == null ? '' : editStr(widget.existing!.amount));
  late final TextEditingController _note = TextEditingController(text: widget.existing?.note ?? '');
  late DateTime _date = widget.date;
  bool _addAnother = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final v = parseAmount(_amount.text);
    if (v == null || v == 0) return;
    final store = AppScope.of(context).store;
    final ex = widget.existing;
    if (ex == null) {
      store.addExpense(_date, v, _note.text);
    } else {
      store.updateExpense(Expense(id: ex.id, date: _date, amount: v, note: _note.text.trim(), created: ex.created));
    }
    if (_addAnother && ex == null) {
      _amount.clear();
      _note.clear();
      showSnack(context, 'Добавлено: ${money(v)}');
      return;
    }
    Navigator.pop(context);
  }

  void _delete() {
    final ex = widget.existing;
    if (ex == null) return;
    final store = AppScope.of(context).store;
    final messengerContext = Navigator.of(context).context;
    store.remove(ex.id);
    Navigator.pop(context);
    showSnack(messengerContext, 'Расход ${money(ex.amount)} удалён', undo: () => store.restore(ex.id));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final store = AppScope.of(context).store;
    final notes = store.frequentNotes();
    final isNew = widget.existing == null;
    final isToday = sameDay(_date, today());

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(isNew ? 'Новый расход' : 'Расход', style: t.textTheme.titleLarge),
          const SizedBox(height: 16),
          AmountField(controller: _amount, autofocus: true, onSubmitted: _save),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Комментарий (необязательно)',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final n in notes)
                  ActionChip(
                    label: Text(n),
                    onPressed: () => setState(() => _note.text = n),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.event_outlined),
                label: Text(isToday ? 'Сегодня, ${fmtDay(_date)}' : '${fmtWeekday(_date)}, ${fmtDay(_date)}'),
                onPressed: () async {
                  final d = await pickDate(context, _date);
                  if (d != null && mounted) setState(() => _date = d);
                },
              ),
              if (!isToday)
                TextButton(
                  onPressed: () => setState(() => _date = today()),
                  child: const Text('Сегодня'),
                ),
            ],
          ),
          if (isNew)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _addAnother,
              onChanged: (v) => setState(() => _addAnother = v ?? false),
              title: const Text('Добавить ещё один после сохранения'),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!isNew)
                IconButton(
                  tooltip: 'Удалить',
                  color: t.colorScheme.error,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _delete,
                ),
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _save, child: const Text('Сохранить')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Шторка «расходы за день».
Future<void> showDaySheet(BuildContext context, DateTime day) {
  return showAdaptiveSheet<void>(context, (ctx) => _DaySheet(day: dateOnly(day)));
}

class _DaySheet extends StatelessWidget {
  const _DaySheet({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).store;
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final list = store.expensesOn(day);
        final total = list.fold<double>(0, (s, e) => s + e.amount);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${fmtWeekdayLong(day)}, ${fmtDayLong(day)}', style: t.textTheme.titleLarge),
                        Text(
                          list.isEmpty ? 'Расходов нет' : 'Потрачено ${money(total)}',
                          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить'),
                    onPressed: () => showExpenseEditor(context, date: day),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: list.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('Нажмите «Добавить», чтобы записать расход')),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final e in list)
                          ListTile(
                            title: Text(
                              money(e.amount),
                              style: t.textTheme.titleMedium?.copyWith(fontFeatures: tabular),
                            ),
                            subtitle: e.note.isEmpty ? null : Text(e.note),
                            trailing: IconButton(
                              tooltip: 'Удалить',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () {
                                store.remove(e.id);
                                showSnack(context, 'Расход ${money(e.amount)} удалён',
                                    undo: () => store.restore(e.id));
                              },
                            ),
                            onTap: () => showExpenseEditor(context, existing: e),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }
}
