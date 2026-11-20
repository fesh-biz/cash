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

String _recordsStr(int n) => '$n ${plural(n, 'запись', 'записи', 'записей')}';

/// Раздел «Резервные копии» на вкладке синхронизации.
class BackupCard extends StatelessWidget {
  const BackupCard({super.key, required this.store});

  final Store store;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final info = store.epochInfo;
    return SectionCard(
      title: 'Резервные копии',
      children: [
        ListTile(
          leading: const Icon(Icons.save_alt),
          title: const Text('Создать резервную копию'),
          subtitle: const Text('Сохранить все данные в файл'),
          onTap: () => _export(context),
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: const Text('Восстановить из копии'),
          subtitle: const Text('Данные из файла заменят данные на этом и на других устройствах'),
          onTap: () => _import(context),
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Автокопии'),
          subtitle: const Text('Предыдущие данные, сохранённые перед каждой заменой'),
          onTap: () => _showAutoBackups(context),
        ),
        if (info != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Текущие данные восстановлены из копии на «${info.device}» ${fmtDateTime(info.at)}.',
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
        showSnack(context, 'Резервная копия сохранена (${_recordsStr(b.records.length)})');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, 'Не удалось сохранить копию: ${_errorText(e)}');
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
      if (context.mounted) showSnack(context, 'Не удалось открыть файл: ${_errorText(e)}');
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
      if (context.mounted) showSnack(context, 'Не удалось прочитать автокопии: $e');
      return;
    }
    if (!context.mounted) return;
    if (list.isEmpty) {
      showSnack(context, 'Автокопий пока нет — они появляются перед заменой данных');
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
      'Восстановить данные из копии?',
      'Копия от ${fmtDateTime(b.createdAt)}'
          '${b.device.isEmpty ? '' : ', устройство «${b.device}»'}, ${_recordsStr(b.records.length)}.\n\n'
          'Все текущие данные на этом устройстве будут заменены данными из копии. При синхронизации '
          'копия будет иметь приоритет и так же заменит данные на других устройствах.\n\n'
          'Текущие данные сначала сохранятся в автокопию.',
      action: 'Восстановить',
    );
    if (!ok || !context.mounted) return;
    try {
      await store.importBackup(b);
      if (context.mounted) {
        showSnack(context, 'Данные восстановлены из копии. Другие устройства получат их при синхронизации.');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, 'Не удалось восстановить данные: $e');
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
          child: Text('Автокопии', style: t.textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Хранятся последние ${Store.maxAutoBackups}. Выберите копию, чтобы восстановить её.',
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
  final text = StringBuffer('На устройстве «${i.device}» ${fmtDateTime(i.at)} восстановили резервную копию');
  if (i.backupAt != null) text.write(' от ${fmtDateTime(i.backupAt!)}');
  text.write('. Восстановленная копия имеет приоритет, поэтому данные на этом устройстве заменены ею.');
  if (n.autoBackup != null) {
    text.write('\n\nПредыдущие данные этого устройства сохранены в автокопию: «Синхронизация» → '
        '«Резервные копии» → «Автокопии». Если восстановить её, она так же заменит данные '
        'и на других устройствах.');
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.settings_backup_restore),
      title: const Text('Данные заменены резервной копией'),
      content: Text(text.toString()),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Понятно')),
      ],
    ),
  );
}
