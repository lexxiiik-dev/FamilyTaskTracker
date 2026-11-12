#!/bin/bash
# Восстановление базы todod из копии:
#     sudo /opt/todod/restore.sh /var/lib/todod/backups/todo-XXXXXXXX-XXXXXX.sqlite
# После восстановления у базы меняется «эпоха»: клиенты заново забирают все данные
# и повторно присылают свои открытые задачи, так что правки после копии не теряются.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Запустите от root"; exit 1; }
SRC=${1:?Укажите файл копии}
[ -f "$SRC" ] || { echo "Нет файла $SRC"; exit 1; }
DB=/var/lib/todod/todo.sqlite
systemctl stop todod
[ -f "$DB" ] && mv "$DB" "$DB.before-restore-$(date +%Y%m%d-%H%M%S)"
rm -f "$DB-wal" "$DB-shm"
install -m 640 -o todod -g todod "$SRC" "$DB"
sudo -u todod /opt/todod/todod new-epoch -config /etc/todod/config.json >/dev/null
systemctl start todod
echo "Восстановлено из $SRC"
