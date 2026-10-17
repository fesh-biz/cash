#!/usr/bin/env bash
# Запуск шага сборки в GitHub Actions: вывод идёт в лог как обычно, а если
# команда упала — последние строки вывода показываются ещё и как ошибка
# (annotation) на странице запуска, чтобы причину было видно без скачивания лога.
#
#   scripts/ci-run.sh "Збірка APK" flutter build apk --release

title="$1"
shift
log="$(mktemp)"
set -o pipefail
"$@" 2>&1 | tee "$log"
code=$?
[ "$code" -eq 0 ] && exit 0
# Строки — через %0A (перевод строки в annotation), % и \r экранируются.
msg="$(grep -v '^\s*$' "$log" | tail -n 80 | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN{ORS="%0A"} {print}')"
echo "::error title=${title}::${msg}"
exit "$code"
