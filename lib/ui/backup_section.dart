import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../data/backup.dart';
import '../data/store.dart';
import '../util/file_dialogs.dart';
import '../util/format.dart';
import 'common.dart';

String _recordsStr(int n) => '$n ${plural(n, 'запис', 'записи', 'записів')}';

/// Раздел «Резервные копии» на вкладке синхронизации.
class BackupCard extends StatelessWidget {
  const BackupCard({super.key, required this.store});

  final Store store;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final info = store.epochInfo;
    return SectionCard(
      title: 'Резервні копії',
      children: [
        ListTile(
          leading: const Icon(Icons.save_alt),
          title: const Text('Створити резервну копію'),
          subtitle: const Text('Зберегти всі дані у файл'),
          onTap: () => _export(context),
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: const Text('Відновити з копії'),
          subtitle: const Text('Дані з файлу замінять дані на цьому й на інших пристроях'),
          onTap: () => _import(context),
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Автокопії'),
          subtitle: const Text('Попередні дані, збережені перед кожною заміною'),
          onTap: () => _showAutoBackups(context),
        ),
        if (info != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Поточні дані відновлено з копії на «${info.device}» ${fmtDateTime(info.at)}.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Future<void> _export(BuildContext context) async {
    final b = store.makeBackup(BackupReason.manual);
    final bytes = Uint8List.fromList(utf8.encode(b.encode()));
    final name = 'cash-backup-${fileStamp(b.createdAt)}.json';
    try {
      final saved = await saveFileDialog(name, bytes);
      if (saved == null) return; // пользователь закрыл окно
      if (context.mounted) {
        showSnack(context, 'Резервну копію збережено (${_recordsStr(b.records.length)})');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, 'Не вдалося зберегти копію: ${_errorText(e)}');
    }
  }

  Future<void> _import(BuildContext context) async {
    Backup b;
    try {
      final bytes = await openFileDialog();
      if (bytes == null) return; // пользователь закрыл окно
      b = Backup.parse(utf8.decode(bytes, allowMalformed: true));
    } on BackupFormatException catch (e) {
      if (context.mounted) showSnack(context, e.message);
      return;
    } catch (e) {
      if (context.mounted) showSnack(context, 'Не вдалося відкрити файл: ${_errorText(e)}');
      return;
    }
    if (context.mounted) await _restore(context, b);
  }

  static String _errorText(Object e) => e is PlatformException ? (e.message ?? e.code) : '$e';

  Future<void> _showAutoBackups(BuildContext context) async {
    List<StoredBackup> list;
    try {
      list = await store.listAutoBackups();
    } catch (e) {
      if (context.mounted) showSnack(context, 'Не вдалося прочитати автокопії: $e');
      return;
    }
    if (!context.mounted) return;
    if (list.isEmpty) {
      showSnack(context, 'Автокопій поки немає — вони з’являються перед заміною даних');
      return;
    }
    final picked = await showAdaptiveSheet<StoredBackup>(
      context,
      (ctx) => _AutoBackupList(list: list, folder: store.backupDir?.path),
    );
    if (picked == null || !context.mounted) return;
    await _restore(context, picked.backup);
  }

  Future<void> _restore(BuildContext context, Backup b) async {
    final ok = await confirm(
      context,
      'Відновити дані з копії?',
      'Копія від ${fmtDateTime(b.createdAt)}'
          '${b.device.isEmpty ? '' : ', пристрій «${b.device}»'}, ${_recordsStr(b.records.length)}.\n\n'
          'Усі поточні дані на цьому пристрої буде замінено даними з копії. Під час синхронізації '
          'копія матиме пріоритет і так само замінить дані на інших пристроях.\n\n'
          'Поточні дані спершу збережуться в автокопію.',
      action: 'Відновити',
    );
    if (!ok || !context.mounted) return;
    try {
      await store.importBackup(b);
      if (context.mounted) {
        showSnack(context, 'Дані відновлено з копії. Інші пристрої отримають їх під час синхронізації.');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, 'Не вдалося відновити дані: $e');
    }
  }
}

class _AutoBackupList extends StatelessWidget {
  const _AutoBackupList({required this.list, this.folder});

  final List<StoredBackup> list;
  final String? folder;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Автокопії', style: t.textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Зберігаються останні ${Store.maxAutoBackups}. Виберіть копію, щоб відновити її.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final s in list)
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(fmtDateTime(s.backup.createdAt)),
                  subtitle: Text(
                    '${s.backup.reason.label}\n'
                    '${s.backup.device.isEmpty ? '' : '«${s.backup.device}» · '}${_recordsStr(s.backup.records.length)}',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.settings_backup_restore),
                  onTap: () => Navigator.pop(context, s),
                ),
            ],
          ),
        ),
        if (folder != null && !Platform.isAndroid)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: SelectableText(
              'Папка: $folder',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          )
        else
          const SizedBox(height: 16),
      ],
    );
  }
}

/// Сообщение: данные этого устройства заменены копией с другого устройства.
Future<void> showReplaceNotice(BuildContext context, ReplaceNotice n) {
  final i = n.info;
  final text = StringBuffer('На пристрої «${i.device}» ${fmtDateTime(i.at)} відновили резервну копію');
  if (i.backupAt != null) text.write(' від ${fmtDateTime(i.backupAt!)}');
  text.write('. Відновлена копія має пріоритет, тому дані на цьому пристрої замінено нею.');
  if (n.autoBackup != null) {
    text.write('\n\nПопередні дані цього пристрою збережено в автокопію: «Синхронізація» → '
        '«Резервні копії» → «Автокопії». Якщо відновити її, вона так само замінить дані '
        'й на інших пристроях.');
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.settings_backup_restore),
      title: const Text('Дані замінено резервною копією'),
      content: Text(text.toString()),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Зрозуміло')),
      ],
    ),
  );
}
