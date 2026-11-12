#!/bin/bash
# Копия базы todod. Сервер останавливать не нужно.
#     /opt/todod/backup.sh [файл]
# Без аргумента копия кладётся в /var/lib/todod/backups, хранится 7 последних.
set -euo pipefail
DIR=/var/lib/todod/backups
OUT=${1:-$DIR/todo-$(date +%Y%m%d-%H%M%S).sqlite}
/opt/todod/todod backup "$OUT" -config /etc/todod/config.json >/dev/null
echo "Копия: $OUT"
if [ -z "${1:-}" ]; then
  ls -1t "$DIR"/todo-*.sqlite 2>/dev/null | tail -n +8 | xargs -r rm -f
fi
