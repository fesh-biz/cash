import 'dart:math';

import 'package:flutter/material.dart';

import '../sync/sync_service.dart';
import '../util/format.dart';
import 'app_scope.dart';
import 'common.dart';

/// Вкладка «Синхронизация» — обмен данными с другими устройствами в той же сети.
class SyncPage extends StatelessWidget {
  const SyncPage({super.key});

  static String _generateKey() {
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    final parts = List.generate(3, (_) => List.generate(4, (_) => alphabet[r.nextInt(alphabet.length)]).join());
    return parts.join('-');
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final store = scope.store;
    final sync = scope.sync;
    return ListenableBuilder(
      listenable: Listenable.merge([store, sync]),
      builder: (context, _) {
        final t = Theme.of(context);
        final s = store.settings;
        final peers = sync.peers.values.toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

        final thisDevice = SectionCard(
          title: 'Это устройство',
          children: [
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Название'),
              subtitle: Text(s.deviceName),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () async {
                final v = await showTextDialog(context, title: 'Название устройства', initial: s.deviceName);
                if (v != null && v.isNotEmpty) {
                  s.deviceName = v;
                  store.saveSettings();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.lan_outlined),
              title: const Text('Адрес в сети'),
              subtitle: Text(
                sync.serverError ??
                    (sync.addresses.isEmpty
                        ? 'Нет подключения к сети'
                        : sync.addresses.map((a) => '$a:${sync.port ?? kSyncPort}').join('\n')),
              ),
            ),
            if (sync.discoveryError != null)
              ListTile(
                leading: Icon(Icons.warning_amber_outlined, color: t.colorScheme.error),
                title: const Text('Автопоиск устройств'),
                subtitle: Text('${sync.discoveryError}\nДобавьте устройство по IP-адресу.'),
              ),
          ],
        );

        final keyCard = SectionCard(
          title: 'Код синхронизации',
          children: [
            ListTile(
              leading: Icon(
                s.syncKey.isEmpty ? Icons.key_off_outlined : Icons.key_outlined,
                color: s.syncKey.isEmpty ? t.colorScheme.error : t.colorScheme.primary,
              ),
              title: Text(s.syncKey.isEmpty ? 'Не задан' : '•' * min(12, s.syncKey.length)),
              subtitle: const Text(
                'Одинаковый на всех ваших устройствах. Без него другие устройства в сети '
                'не смогут прочитать или изменить данные.',
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () async {
                final v = await showTextDialog(
                  context,
                  title: 'Код синхронизации',
                  initial: s.syncKey,
                  label: 'Код',
                  obscure: true,
                  help: 'Придумайте код (не короче 6 символов) или сгенерируйте его здесь, '
                      'затем введите такой же на другом устройстве.',
                  generate: _generateKey,
                );
                if (v == null) return;
                if (v.isNotEmpty && v.length < 6) {
                  if (context.mounted) showSnack(context, 'Код слишком короткий — нужно от 6 символов');
                  return;
                }
                s.syncKey = v;
                store.saveSettings();
                if (v.isNotEmpty) sync.syncAll(force: true);
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.autorenew),
              title: const Text('Автоматическая синхронизация'),
              subtitle: const Text('После каждого изменения и раз в 20 секунд, пока приложение открыто'),
              value: s.autoSync,
              onChanged: (v) {
                s.autoSync = v;
                store.saveSettings();
              },
            ),
          ],
        );

        final peersCard = SectionCard(
          title: 'Устройства',
          trailing: TextButton.icon(
            icon: const Icon(Icons.add_link),
            label: const Text('По IP'),
            onPressed: () => _addManual(context, sync),
          ),
          children: [
            if (peers.isEmpty)
              const ListTile(
                leading: Icon(Icons.search),
                title: Text('Ищем устройства в сети…'),
                subtitle: Text(
                  'Откройте приложение на другом устройстве в той же Wi‑Fi сети. '
                  'Если оно не появляется — добавьте его по IP-адресу.',
                ),
              ),
            for (final p in peers) _PeerTile(peer: p, sync: sync),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: FilledButton.icon(
                icon: sync.anyBusy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
                label: const Text('Синхронизировать сейчас'),
                onPressed: (!sync.hasKey || sync.anyBusy || peers.isEmpty) ? null : () => sync.syncAll(force: true),
              ),
            ),
          ],
        );

        final help = SectionCard(
          title: 'Как это работает',
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            Text(
              '1. Оба устройства подключены к одной сети (один роутер / Wi‑Fi).\n'
              '2. На обоих задан одинаковый код синхронизации.\n'
              '3. Устройства находят друг друга сами и обмениваются изменениями напрямую — '
              'без интернета и без внешних серверов.\n'
              '4. Если одну и ту же запись изменили на двух устройствах, остаётся более поздняя правка.\n\n'
              'Windows: при первом запуске разрешите приложению доступ в «Частных сетях» '
              'в окне брандмауэра. Сеть Wi‑Fi в Windows должна быть «Частной».',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            if (store.dataPath != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                'Файл данных: ${store.dataPath}',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ],
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
                    child: Column(children: [thisDevice, const SizedBox(height: 12), keyCard]),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(children: [peersCard, const SizedBox(height: 12), help]),
                  ),
                ],
              ),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            keyCard,
            const SizedBox(height: 12),
            peersCard,
            const SizedBox(height: 12),
            thisDevice,
            const SizedBox(height: 12),
            help,
          ],
        );
      },
    );
  }

  Future<void> _addManual(BuildContext context, SyncService sync) async {
    final v = await showTextDialog(
      context,
      title: 'Добавить устройство по IP',
      label: 'IP-адрес',
      help: 'Адрес указан на другом устройстве: вкладка «Синхронизация» → «Адрес в сети». '
          'Например: 192.168.1.20',
    );
    if (v == null || v.isEmpty) return;
    final err = await sync.addManual(v);
    if (context.mounted) {
      showSnack(context, err ?? 'Устройство добавлено');
    }
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.sync});

  final Peer peer;
  final SyncService sync;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = peer;
    final lines = <String>['${p.host}:${p.port} · ${p.online ? 'в сети' : 'не в сети'}'];
    if (p.lastSync != null) lines.add('Синхронизировано: ${fmtTimeAgo(p.lastSync!)}');
    if (p.error != null && (p.hasProblem || !p.networkError)) lines.add(p.error!);
    return ListTile(
      leading: Icon(
        Icons.devices_other,
        color: p.hasProblem
            ? t.colorScheme.error
            : p.online
                ? t.colorScheme.primary
                : t.colorScheme.onSurfaceVariant,
      ),
      title: Text(p.name),
      subtitle: Text(lines.join('\n')),
      isThreeLine: lines.length > 2,
      trailing: p.busy
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'sync') {
                  await sync.syncWith(p, force: true);
                } else if (v == 'forget') {
                  final ok = await confirm(
                    context,
                    'Забыть устройство?',
                    '«${p.name}» будет удалено из списка. Если оно снова появится в сети, '
                        'синхронизация начнётся заново.',
                    action: 'Забыть',
                  );
                  if (ok) sync.forget(p.id);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'sync', child: Text('Синхронизировать')),
                PopupMenuItem(value: 'forget', child: Text('Забыть')),
              ],
            ),
    );
  }
}
