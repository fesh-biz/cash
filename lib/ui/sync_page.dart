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
          title: 'Цей пристрій',
          children: [
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Назва'),
              subtitle: Text(s.deviceName),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () async {
                final v = await showTextDialog(context, title: 'Назва пристрою', initial: s.deviceName);
                if (v != null && v.isNotEmpty) {
                  s.deviceName = v;
                  store.saveSettings();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.lan_outlined),
              title: const Text('Адреса в мережі'),
              subtitle: Text(
                sync.serverError ??
                    (sync.addresses.isEmpty
                        ? 'Немає підключення до мережі'
                        : sync.addresses.map((a) => '$a:${sync.port ?? kSyncPort}').join('\n')),
              ),
            ),
            if (sync.discoveryError != null)
              ListTile(
                leading: Icon(Icons.warning_amber_outlined, color: t.colorScheme.error),
                title: const Text('Автопошук пристроїв'),
                subtitle: Text('${sync.discoveryError}\nДодайте пристрій за IP-адресою.'),
              ),
          ],
        );

        final keyCard = SectionCard(
          title: 'Код синхронізації',
          children: [
            ListTile(
              leading: Icon(
                s.syncKey.isEmpty ? Icons.key_off_outlined : Icons.key_outlined,
                color: s.syncKey.isEmpty ? t.colorScheme.error : t.colorScheme.primary,
              ),
              title: Text(s.syncKey.isEmpty ? 'Не задано' : '•' * min(12, s.syncKey.length)),
              subtitle: const Text(
                'Однаковий на всіх ваших пристроях. Без нього інші пристрої в мережі '
                'не зможуть прочитати чи змінити дані.',
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () async {
                final v = await showTextDialog(
                  context,
                  title: 'Код синхронізації',
                  initial: s.syncKey,
                  label: 'Код',
                  obscure: true,
                  help: 'Придумайте код (не коротший за 6 символів) або згенеруйте його тут, '
                      'потім введіть такий самий на іншому пристрої.',
                  generate: _generateKey,
                );
                if (v == null) return;
                if (v.isNotEmpty && v.length < 6) {
                  if (context.mounted) showSnack(context, 'Код закороткий — потрібно щонайменше 6 символів');
                  return;
                }
                s.syncKey = v;
                store.saveSettings();
                if (v.isNotEmpty) sync.syncAll(force: true);
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.autorenew),
              title: const Text('Автоматична синхронізація'),
              subtitle: const Text('Після кожної зміни та раз на 20 секунд, поки застосунок відкритий'),
              value: s.autoSync,
              onChanged: (v) {
                s.autoSync = v;
                store.saveSettings();
              },
            ),
          ],
        );

        final peersCard = SectionCard(
          title: 'Пристрої',
          trailing: TextButton.icon(
            icon: const Icon(Icons.add_link),
            label: const Text('За IP'),
            onPressed: () => _addManual(context, sync),
          ),
          children: [
            if (peers.isEmpty)
              const ListTile(
                leading: Icon(Icons.search),
                title: Text('Шукаємо пристрої в мережі…'),
                subtitle: Text(
                  'Відкрийте застосунок на іншому пристрої в тій самій мережі Wi‑Fi. '
                  'Якщо він не з’являється — додайте його за IP-адресою.',
                ),
              ),
            for (final p in peers) _PeerTile(peer: p, sync: sync),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: FilledButton.icon(
                icon: sync.anyBusy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
                label: const Text('Синхронізувати зараз'),
                onPressed: (!sync.hasKey || sync.anyBusy || peers.isEmpty) ? null : () => sync.syncAll(force: true),
              ),
            ),
          ],
        );

        final help = SectionCard(
          title: 'Як це працює',
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            Text(
              '1. Обидва пристрої підключено до однієї мережі (один роутер / Wi‑Fi).\n'
              '2. На обох задано однаковий код синхронізації.\n'
              '3. Пристрої самі знаходять один одного й обмінюються змінами напряму — '
              'без інтернету й без зовнішніх серверів.\n'
              '4. Якщо той самий запис змінили на двох пристроях, залишається пізніша зміна.\n\n'
              'Windows: під час першого запуску дозвольте застосунку доступ у «Приватних мережах» '
              'у вікні брандмауера. Мережа Wi‑Fi у Windows має бути «Приватною».',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            if (store.dataPath != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                'Файл даних: ${store.dataPath}',
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
      title: 'Додати пристрій за IP',
      label: 'IP-адреса',
      help: 'Адресу вказано на іншому пристрої: вкладка «Синхронізація» → «Адреса в мережі». '
          'Наприклад: 192.168.1.20',
    );
    if (v == null || v.isEmpty) return;
    final err = await sync.addManual(v);
    if (context.mounted) {
      showSnack(context, err ?? 'Пристрій додано');
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
    final lines = <String>['${p.host}:${p.port} · ${p.online ? 'в мережі' : 'не в мережі'}'];
    if (p.lastSync != null) lines.add('Синхронізовано: ${fmtTimeAgo(p.lastSync!)}');
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
                    'Забути пристрій?',
                    '«${p.name}» буде видалено зі списку. Якщо він знову з’явиться в мережі, '
                        'синхронізація почнеться заново.',
                    action: 'Забути',
                  );
                  if (ok) sync.forget(p.id);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'sync', child: Text('Синхронізувати')),
                PopupMenuItem(value: 'forget', child: Text('Забути')),
              ],
            ),
    );
  }
}
