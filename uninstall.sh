#!/usr/bin/env bash
# Полное удаление: все сервисы, юниты и папка установки.
set -u
[ "$(id -u)" = 0 ] || { echo "Нужен root."; exit 1; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in /etc/systemd/system/openflux-c-*.service /etc/systemd/system/openflux-panel.service; do
  [ -e "$f" ] || continue; n=$(basename "$f"); systemctl disable --now "$n" 2>/dev/null; rm -f "$f"; done
systemctl daemon-reload
cd / && rm -rf "$D"
echo "OpenFlux панель и все подключения удалены."
