import 'dart:math';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../util/format.dart';

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 840;

const tabular = [FontFeature.tabularFigures()];

/// Цвета для плюса/минуса.
Color positiveColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);

Color negativeColor(BuildContext context) => Theme.of(context).colorScheme.error;

Color balanceColor(BuildContext context, double v) =>
    v.round() < 0 ? negativeColor(context) : positiveColor(context);

/// Карточка-раздел с заголовком.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, this.trailing, required this.children, this.padding});

  final String? title;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: t.colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? const EdgeInsets.only(top: 4, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title!, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    ),
                    if (trailing != null) trailing!,
                  ],
                ),
              ),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Небольшая плитка «подпись — значение».
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.hint, this.color, this.onTap});

  final String label;
  final String value;
  final String? hint;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(
                value,
                style: t.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: color,
                  fontFeatures: tabular,
                ),
              ),
              if (hint != null)
                Text(hint!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Сетка плиток, подстраивается под ширину.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.children, this.minTileWidth = 150});

  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const gap = 8.0;
      final cols = max(1, ((c.maxWidth + gap) / (minTileWidth + gap)).floor());
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final ch in children) SizedBox(width: w, child: ch)],
      );
    });
  }
}

/// Строка «название ……… сумма» внутри карточки.
class AmountTile extends StatelessWidget {
  const AmountTile({
    super.key,
    required this.title,
    required this.amount,
    this.subtitle,
    this.onTap,
    this.bold = false,
    this.color,
    this.leading,
    this.amountText,
  });

  final String title;
  final double amount;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool bold;
  final Color? color;
  final Widget? leading;
  final String? amountText;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = (bold ? t.textTheme.titleMedium : t.textTheme.bodyLarge)?.copyWith(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
      color: color,
      fontFeatures: tabular,
    );
    return ListTile(
      dense: false,
      leading: leading,
      title: Text(title, style: bold ? t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700) : null),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Text(amountText ?? money(amount), style: style),
      onTap: onTap,
    );
  }
}

/// Поле ввода суммы. Понимает «500+250».
class AmountField extends StatefulWidget {
  const AmountField({
    super.key,
    required this.controller,
    this.label = 'Сумма',
    this.autofocus = false,
    this.onSubmitted,
    this.suffix = '₴',
  });

  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final VoidCallback? onSubmitted;
  final String suffix;

  @override
  State<AmountField> createState() => _AmountFieldState();
}

class _AmountFieldState extends State<AmountField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final v = parseAmount(text);
    String? helper;
    String? error;
    if (text.trim().isNotEmpty) {
      if (v == null) {
        error = 'Не похоже на число';
      } else if (RegExp(r'\d\s*[+\-−]').hasMatch(text)) {
        helper = '= ${numStr(v)} ${widget.suffix}';
      }
    }
    return TextField(
      controller: widget.controller,
      autofocus: widget.autofocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      textInputAction: TextInputAction.done,
      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontFeatures: tabular),
      decoration: InputDecoration(
        labelText: widget.label,
        suffixText: widget.suffix,
        helperText: helper,
        errorText: error,
        border: const OutlineInputBorder(),
      ),
      onSubmitted: (_) => widget.onSubmitted?.call(),
    );
  }
}

/// Открывает форму: на широком экране — диалог, на телефоне — нижняя шторка.
Future<T?> showAdaptiveSheet<T>(BuildContext context, WidgetBuilder builder) {
  if (isWide(context)) {
    return showDialog<T>(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
          child: builder(ctx),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: builder(ctx),
    ),
  );
}

Future<DateTime?> pickDate(BuildContext context, DateTime initial) {
  return showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
  );
}

Future<bool> confirm(BuildContext context, String title, String message, {String action = 'Удалить'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return r ?? false;
}

void showSnack(BuildContext context, String text, {VoidCallback? undo}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(text),
    behavior: SnackBarBehavior.floating,
    // С Flutter 3.38+ снекбар с action по умолчанию не исчезает сам.
    persist: false,
    duration: const Duration(seconds: 5),
    action: undo == null ? null : SnackBarAction(label: 'Отменить', onPressed: undo),
  ));
}

/// Диалог ввода числа (курс, доход, сумма…).
Future<double?> showNumberDialog(
  BuildContext context, {
  required String title,
  required double initial,
  String suffix = '₴',
  String? help,
}) {
  return showDialog<double>(
    context: context,
    builder: (ctx) => _NumberDialog(title: title, initial: initial, suffix: suffix, help: help),
  );
}

class _NumberDialog extends StatefulWidget {
  const _NumberDialog({required this.title, required this.initial, required this.suffix, this.help});

  final String title;
  final double initial;
  final String suffix;
  final String? help;

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  late final TextEditingController _c = TextEditingController(text: editStr(widget.initial))
    ..selection = TextSelection(baseOffset: 0, extentOffset: editStr(widget.initial).length);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    final v = parseAmount(_c.text);
    if (v == null) return;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.help != null) ...[
              Text(widget.help!, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
            ],
            AmountField(controller: _c, autofocus: true, suffix: widget.suffix, label: 'Значение', onSubmitted: _ok),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: _ok, child: const Text('Сохранить')),
      ],
    );
  }
}

/// Диалог ввода текста.
Future<String?> showTextDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String? label,
  String? help,
  bool obscure = false,
  String Function()? generate,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _TextDialog(
      title: title,
      initial: initial,
      label: label,
      help: help,
      obscure: obscure,
      generate: generate,
    ),
  );
}

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.initial,
    this.label,
    this.help,
    this.obscure = false,
    this.generate,
  });

  final String title;
  final String initial;
  final String? label;
  final String? help;
  final bool obscure;
  final String Function()? generate;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);
  late bool _hidden = widget.obscure;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.help != null) ...[
              Text(widget.help!, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _c,
              autofocus: true,
              obscureText: _hidden,
              decoration: InputDecoration(
                labelText: widget.label,
                border: const OutlineInputBorder(),
                suffixIcon: widget.obscure
                    ? IconButton(
                        tooltip: _hidden ? 'Показать' : 'Скрыть',
                        icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _hidden = !_hidden),
                      )
                    : null,
              ),
              onSubmitted: (_) => Navigator.pop(context, _c.text.trim()),
            ),
            if (widget.generate != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.casino_outlined),
                label: const Text('Сгенерировать'),
                onPressed: () => setState(() {
                  _c.text = widget.generate!();
                  _hidden = false;
                }),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, _c.text.trim()), child: const Text('Сохранить')),
      ],
    );
  }
}

/// Результат диалога «название + сумма (+ дата)».
class ItemEdit {
  ItemEdit({required this.name, required this.amount, required this.date, this.delete = false});

  final String name;
  final double amount;
  final DateTime date;
  final bool delete;
}

Future<ItemEdit?> showItemDialog(
  BuildContext context, {
  required String title,
  String name = '',
  double? amount,
  DateTime? date,
  bool withDate = false,
  String nameLabel = 'Название',
  bool canDelete = false,
}) {
  return showDialog<ItemEdit>(
    context: context,
    builder: (ctx) => _ItemDialog(
      title: title,
      name: name,
      amount: amount,
      date: date ?? today(),
      withDate: withDate,
      nameLabel: nameLabel,
      canDelete: canDelete,
    ),
  );
}

class _ItemDialog extends StatefulWidget {
  const _ItemDialog({
    required this.title,
    required this.name,
    required this.amount,
    required this.date,
    required this.withDate,
    required this.nameLabel,
    required this.canDelete,
  });

  final String title;
  final String name;
  final double? amount;
  final DateTime date;
  final bool withDate;
  final String nameLabel;
  final bool canDelete;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late final TextEditingController _amount =
      TextEditingController(text: widget.amount == null ? '' : editStr(widget.amount!));
  late DateTime _date = widget.date;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _ok() {
    final v = parseAmount(_amount.text);
    if (v == null) return;
    Navigator.pop(context, ItemEdit(name: _name.text.trim(), amount: v, date: _date));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.name.isEmpty,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: widget.nameLabel, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            AmountField(controller: _amount, autofocus: widget.name.isNotEmpty, onSubmitted: _ok),
            if (widget.withDate) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.event_outlined),
                  label: Text(fmtDate(_date)),
                  onPressed: () async {
                    final d = await pickDate(context, _date);
                    if (d != null) setState(() => _date = d);
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.canDelete)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, ItemEdit(name: '', amount: 0, date: _date, delete: true)),
            child: const Text('Удалить'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: _ok, child: const Text('Сохранить')),
      ],
    );
  }
}
