#!/bin/bash
# Установка и обновление сервера таск-трекера (todod) на Linux с systemd одной командой:
#     sudo bash install.sh
#
# Параметры (необязательно, через переменные окружения):
#   PORT=8443              порт HTTPS (по умолчанию первый свободный из 8443, 9443, 10443...)
#   PUBLIC_URL=https://…   адрес, по которому сервер видят пользователи (по умолчанию https://<IP>:<порт>)
#   PROXY=1                сервер стоит за обратным прокси (Caddy, nginx) с настоящим сертификатом:
#                          todod слушает HTTP на 127.0.0.1:8080, сертификат — забота прокси
#
# Повторный запуск обновляет программу; настройки, ключ доступа и база сохраняются.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Запустите от root: sudo bash install.sh"; exit 1; }

case "$(uname -m)" in
  x86_64) BIN=./todod-linux-amd64 ;;
  aarch64|arm64) BIN=./todod-linux-arm64 ;;
  *) echo "Неизвестная архитектура $(uname -m)"; exit 1 ;;
esac
[ -f "$BIN" ] || { echo "Нет файла $BIN рядом со скриптом (скачайте его из релиза или соберите: tools/build-server.ps1)"; exit 1; }

# ---- программа и пользователь ----
id todod >/dev/null 2>&1 || useradd --system --home /var/lib/todod --shell /usr/sbin/nologin todod
systemctl stop todod 2>/dev/null || true
install -d -m 755 /opt/todod
install -m 755 "$BIN" /opt/todod/todod
install -m 755 backup.sh restore.sh /opt/todod/
install -d -m 750 -o todod -g todod /var/lib/todod /var/lib/todod/backups

# ---- первая настройка: ключ доступа, сертификат, config.json ----
if [ ! -f /etc/todod/config.json ]; then
  busy() { ss -tulnH 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$1\$"; }
  ARGS=(-dir /etc/todod -data /var/lib/todod)
  if [ "${PROXY:-}" = 1 ]; then
    ARGS+=(-proxy)
  else
    if [ -z "${PORT:-}" ]; then
      for p in 8443 9443 10443 11443 12443; do busy "$p" || { PORT=$p; break; }; done
    fi
    [ -n "${PORT:-}" ] || { echo "Не нашёл свободный порт, задайте PORT=..."; exit 1; }
    busy "$PORT" && { echo "Порт $PORT занят"; exit 1; }
    ARGS+=(-port "$PORT")
    if [ -z "${PUBLIC_URL:-}" ]; then
      IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
      PUBLIC_URL="https://${IP:-<адрес сервера>}:$PORT"
    fi
  fi
  [ -n "${PUBLIC_URL:-}" ] && ARGS+=(-public-url "$PUBLIC_URL")
  /opt/todod/todod init "${ARGS[@]}" >/dev/null
  chown -R root:todod /etc/todod
  chmod 750 /etc/todod
  chmod 640 /etc/todod/*
  chown todod:todod /var/lib/todod
  if [ "${PROXY:-}" != 1 ] && command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "$PORT/tcp" >/dev/null
  fi
fi

# ---- служба и ежедневная копия базы ----
install -m 644 todod.service todod-backup.service todod-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now todod todod-backup.timer >/dev/null
sleep 1
systemctl is-active --quiet todod || { journalctl -u todod -n 20 --no-pager; echo "todod не запустился"; exit 1; }

/opt/todod/todod info -config /etc/todod/config.json