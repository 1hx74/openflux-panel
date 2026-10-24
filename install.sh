#!/usr/bin/env bash
# OpenFlux panel installer / updater. Run from the cloned repo (/opt/openflux).
# Already installed (config.json exists) -> update mode: keeps login, path, port, connections.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Запустите от root (sudo)."; exit 1; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$D"
REPO=p1neappleXpress/OpenFlux
UPDATE=0; [ -f config.json ] && UPDATE=1; export UPD=$([ $UPDATE = 1 ] && echo 1 || true)

if ! command -v python3 >/dev/null || ! python3 -c 'import venv, ensurepip' 2>/dev/null || ! command -v curl >/dev/null; then
  echo ">> Ставлю зависимости (python3, venv, curl, openssl)"
  if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq python3 python3-venv curl openssl iproute2
  elif command -v dnf >/dev/null; then dnf install -y -q python3 curl openssl iproute
  else echo "Установите python3 (с venv), curl, openssl вручную."; exit 1; fi
fi

pick_binary() {
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
  echo ">> Бинарник обновлён. Запущенные подключения подхватят его после рестарта в панели."
}

if [ $UPDATE = 1 ]; then
  echo ">> Найдена установка в $D — режим обновления (логин, пароль, путь, порт и подключения сохраняются)"
  read -rp "Заново скачать бинарник OpenFlux? [y/N]: " R; [[ "${R,,}" == y* ]] && pick_binary
  [ -x venv/bin/python ] || python3 -m venv venv
  ./venv/bin/pip install -q --upgrade qrcode
  export D
  DOMAIN="$(python3 -c 'import json,os;print(json.load(open(os.environ["D"]+"/config.json")).get("domain",""))')"
  HASCERT="$(python3 -c 'import json,os;print(json.load(open(os.environ["D"]+"/config.json")).get("cert",""))')"
  if [ -n "$HASCERT" ] && [ -z "$DOMAIN" ]; then
    read -rp "Домен панели (для вывода адреса): " DOMAIN; export DOMAIN
    python3 -c 'import json,os;p=os.environ["D"]+"/config.json";c=json.load(open(p));c["domain"]=os.environ["DOMAIN"];json.dump(c,open(p,"w"),indent=1)'
  fi
else
  pick_binary
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
  export D USER_ PASS SPATH PORT CERT KEY DOMAIN
  python3 - <<'PY'
import json, os
e = os.environ
json.dump({"user": e["USER_"], "password": e["PASS"], "path": e["SPATH"], "port": int(e["PORT"]),
           "cert": e["CERT"], "key": e["KEY"], "domain": e["DOMAIN"]}, open(e["D"] + "/config.json", "w"), indent=1)
PY
  chmod 600 config.json; [ -f connections.json ] || echo '{}' > connections.json
fi

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
systemctl daemon-reload && systemctl enable openflux-panel.service && systemctl restart openflux-panel.service

IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')"
export D IP; export DOMAIN="${DOMAIN:-}"
python3 - <<'PY'
import json, os
e = os.environ; c = json.load(open(e["D"] + "/config.json"))
host = c.get("domain") or e["IP"]; scheme = "https" if c.get("cert") and c.get("domain") else "http"
print(f"""
══════════════════════════════════════════════
  OpenFlux панель {'обновлена' if os.environ.get('UPD') else 'установлена'} и в автозапуске
══════════════════════════════════════════════
  Адрес:   {scheme}://{host}:{c['port']}/{c['path']}/
  Логин:   {c['user']}
  Пароль:  {c['password']}
  Порт:    {c['port']}   (откройте его в firewall/security group)
══════════════════════════════════════════════
  Данные: {e['D']}/config.json
  Обновить:     cd {e['D']} && git pull && bash install.sh
  Удалить всё:  bash {e['D']}/uninstall.sh""")
if scheme == "http": print("  ВНИМАНИЕ: без сертификата (http) логин и пароль идут открытым текстом.")
PY
