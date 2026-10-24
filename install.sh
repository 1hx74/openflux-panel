#!/usr/bin/env bash
# OpenFlux panel installer. Run from the cloned repo (/opt/openflux).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Запустите от root (sudo)."; exit 1; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$D"
REPO=p1neappleXpress/OpenFlux

if ! command -v python3 >/dev/null || ! python3 -c 'import venv, ensurepip' 2>/dev/null || ! command -v curl >/dev/null; then
  echo ">> Ставлю зависимости (python3, venv, curl, openssl)"
  if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq python3 python3-venv curl openssl iproute2
  elif command -v dnf >/dev/null; then dnf install -y -q python3 curl openssl iproute
  else echo "Установите python3 (с venv), curl, openssl вручную."; exit 1; fi
fi

echo; echo "=== Выбор сборки OpenFlux ==="
mapfile -t ASSETS < <(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 | grep -i linux | grep -viE '\.(txt|sha256|sig|md5)$' || true)
[ ${#ASSETS[@]} -gt 0 ] || ASSETS=("https://github.com/$REPO/releases/latest/download/openflux-linux-amd64" \
  "https://github.com/$REPO/releases/latest/download/openflux-linux-arm64")
case "$(uname -m)" in x86_64) HINT=amd64;; aarch64|arm64) HINT=arm64;; armv7*|armv6*) HINT=arm;; *) HINT=;; esac
for i in "${!ASSETS[@]}"; do m=""; [[ -n "$HINT" && "${ASSETS[$i]}" == *"$HINT"* ]] && m="  <- похоже на вашу систему ($(uname -m))"
  echo "  $((i+1))) $(basename "${ASSETS[$i]}")$m"; done
read -rp "Номер [1]: " N; N=${N:-1}
URL="${ASSETS[$((N-1))]}"; [ -n "$URL" ] || { echo "Неверный выбор"; exit 1; }
echo ">> Скачиваю $URL"
curl -fL "$URL" -o openflux-new && chmod +x openflux-new && mv -f openflux-new openflux

echo; read -rp "Есть SSL-сертификаты (для домена)? [y/N]: " HAVE
CERT=""; KEY=""; DOMAIN=""
if [[ "${HAVE,,}" == y* ]]; then
  read -rp "Путь к сертификату (fullchain.pem): " CERT
  read -rp "Путь к приватному ключу (privkey.pem): " KEY
  [ -r "$CERT" ] && [ -r "$KEY" ] || { echo "Файлы не найдены/нечитаемы."; exit 1; }
  read -rp "Домен: " DOMAIN; [ -n "$DOMAIN" ] || { echo "Нужен домен."; exit 1; }
fi

echo ">> Ставлю python-зависимости в $D/venv"
python3 -m venv venv && ./venv/bin/pip install -q qrcode

USER_="admin$(openssl rand -hex 2)"; PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
SPATH="$(openssl rand -hex 10)"
while :; do PORT=$(shuf -i 9001-65000 -n1); ss -ltn | grep -q ":$PORT " || break; done
IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')"
export D USER_ PASS SPATH PORT CERT KEY
python3 - <<'PY'
import json, os
e = os.environ
json.dump({"user": e["USER_"], "password": e["PASS"], "path": e["SPATH"], "port": int(e["PORT"]),
           "cert": e["CERT"], "key": e["KEY"]}, open(e["D"] + "/config.json", "w"), indent=1)
PY
chmod 600 config.json; [ -f connections.json ] || echo '{}' > connections.json

cat > /etc/systemd/system/openflux-panel.service <<UNIT
[Unit]
Description=OpenFlux panel
After=network-online.target
[Service]
WorkingDirectory=$D
ExecStart=$D/venv/bin/python $D/panel.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now openflux-panel.service

if [ -n "$DOMAIN" ]; then LINK="https://$DOMAIN:$PORT/$SPATH/"; else LINK="http://$IP:$PORT/$SPATH/"; fi
cat <<OUT

══════════════════════════════════════════════
  OpenFlux панель установлена и в автозапуске
══════════════════════════════════════════════
  Адрес:   $LINK
  Логин:   $USER_
  Пароль:  $PASS
  Порт:    $PORT   (откройте его в firewall/security group)
══════════════════════════════════════════════
  Данные сохранены в $D/config.json
  Удалить всё:  bash $D/uninstall.sh
OUT
[ -z "$DOMAIN" ] && echo "  ВНИМАНИЕ: без сертификата (http) логин и пароль идут открытым текстом."
exit 0
