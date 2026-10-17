# Cash — правила работы

- После каждой правки кода — коммит и push в ветку `main` репозитория
  `fesh-biz/cash`. Не копить изменения между правками.
- Рабочая копия пользователя — `F:\projects\Cash` на его ПК. Изменения должны
  попасть и туда, и в GitHub одним и тем же коммитом, чтобы локальная ветка
  не расходилась с `origin/main`. Как это делать из облачной сессии:
  1. В начале работы запросить доступ к папке (`device_request_folder_access`
     на `F:\projects\Cash`) и разрешение на удаление в ней
     (`device_request_delete_permission`) — без него git оставляет .lock-файлы
     и не может заменять файлы. Оба доступа действуют только в текущей сессии.
  2. Проверить, что рабочая копия чистая (`git -c safe.directory=* status`
     через `device_bash`, папка — `$HOME/mnt/Cash`).
  3. После push: в облаке `git bundle create <outputs>/cash-update.bundle
     <старый HEAD ПК>..origin/main`, `device_commit_files` → `dist\cash-update.bundle`,
     на ПК `git fetch <bundle> refs/remotes/origin/main:refs/remotes/origin/main`
     и `git merge --ff-only origin/main`, затем удалить bundle. Сеть и учётные
     данные GitHub на ПК для этого не нужны.
  Если ПК недоступен (выключен, не открыто приложение Claude) — только push,
  а пользователю напомнить сделать `git pull` в этой папке.
- Сборка и тесты — GitHub Actions (`.github/workflows/build.yml`): каждый push
  в `main` запускает `flutter analyze`, `flutter test`, сборку APK и Windows
  и публикует релиз `v1.0.<номер запуска>`. После push дождаться результата
  запуска для этого коммита (`gh api repos/fesh-biz/cash/actions/runs`) и
  сообщить его. Упало — разобраться, исправить и закоммитить снова.
- Сборка на ПК (`build.bat`, `watch-build.bat` → `dist\build-status.json`)
  осталась как запасной вариант.
- Устройство структуры и сборки описано в `README.md`.
