#!/usr/bin/env python3
"""OpenFlux panel: stdlib http server + systemd units per connection."""
import hmac, base64, io, json, os, re, secrets, shlex, ssl, subprocess, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import qrcode, qrcode.image.svg

D = os.path.dirname(os.path.abspath(__file__))
CFG = json.load(open(os.path.join(D, "config.json")))
DB = os.path.join(D, "connections.json")
LOCK = threading.Lock()
LINK_RE = re.compile(r"openflux://\S+")
B64_RE = re.compile(r"^[A-Za-z0-9+/]{40,}={0,2}$")

def load():
    try: return json.load(open(DB))
    except Exception: return {}
def save(db): json.dump(db, open(DB, "w"), indent=1)
def unit(i): return f"openflux-c-{i}.service"
def sh(*a): return subprocess.run(a, capture_output=True, text=True).stdout
def esc(s): return shlex.quote(s).replace("%", "%%").replace("$", "$$")

def full_args(c):
    a = list(c["args"])
    if c.get("code") and not any(x.startswith("--url") for x in a): a.append(f"--url={c['code']}")
    return a

def write_unit(i, c):
    exe = " ".join(esc(x) for x in [os.path.join(D, "openflux")] + full_args(c))
    open(f"/etc/systemd/system/{unit(i)}", "w").write(
f"""[Unit]
Description=OpenFlux connection {i}
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory={D}
ExecStart={exe}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
""")
    sh("systemctl", "daemon-reload")

def logs(i, n=200): return sh("journalctl", "-u", unit(i), "-n", str(n), "--no-pager", "-o", "cat")

def capture(i):
    """Wait for the node to print openflux:// link / base64 code; save them."""
    for _ in range(60):
        time.sleep(2)
        out = logs(i)
        link = (LINK_RE.findall(out) or [None])[-1]
        b64 = ([l.strip() for l in out.splitlines() if B64_RE.match(l.strip())] or [None])[-1]
        with LOCK:
            db = load(); c = db.get(i)
            if not c: return
            if link: c["link"] = link
            if b64 and not link: c["code_seen"] = b64
            cups_new = "cupsonline" in " ".join(c["args"]) and not any(x.startswith("--url") for x in c["args"])
            if cups_new and b64:
                c["code"] = b64; write_unit(i, c)   # next start uses --url=<code>
            save(db)
            if link or (cups_new and b64): return

def view(i, c):
    return {"id": i, "name": c["name"], "args": c["args"], "status": sh("systemctl", "is-active", unit(i)).strip(),
            "link": c.get("link"), "code": c.get("code") or c.get("code_seen")}

def share_data(c): return c.get("link") or c.get("code") or c.get("code_seen")

PAGE = r"""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>OpenFlux</title>
<style>:root{color-scheme:dark}body{font:15px system-ui;background:#111;color:#eee;max-width:860px;margin:0 auto;padding:16px}
.c{background:#1c1c1c;border:1px solid #333;border-radius:8px;padding:12px;margin:10px 0}button{background:#2d6cdf;color:#fff;border:0;border-radius:6px;padding:6px 11px;margin:2px;cursor:pointer}
button.g{background:#444}button.r{background:#b33}input,textarea{width:100%;box-sizing:border-box;background:#111;color:#eee;border:1px solid #444;border-radius:6px;padding:8px;margin:4px 0}
code,pre{background:#000;padding:2px 5px;border-radius:4px;word-break:break-all;white-space:pre-wrap}.ok{color:#5c5}.bad{color:#e66}</style>
<h2>OpenFlux · панель</h2>
<div class=c><b>Новое подключение</b><input id=n placeholder="Название">
<div><button class=g onclick=pre('t')>Телемост пример</button><button class=g onclick=pre('c')>CUPS пример</button></div>
<input id=u placeholder="Ссылка Телемоста https://telemost.yandex.ru/j/... (для примера Телемост)">
<textarea id=a rows=2 placeholder='Аргументы запуска, например: --role=exit --mode=l4 --transport=cupsonline'></textarea>
<button onclick=add()>Создать и запустить</button> <small>Запускается как ./openflux &lt;аргументы&gt;, с автозапуском</small></div>
<div id=l></div>
<script>
const B=location.pathname.replace(/\/?$/,'/');const q=s=>document.getElementById(s);
const E=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function api(p,m='GET',b){const r=await fetch(B+'api/'+p,{method:m,body:b?JSON.stringify(b):undefined});return r.headers.get('content-type').includes('json')?r.json():r.text()}
function pre(k){if(k=='c'){q('a').value='--role=exit --mode=l4 --transport=cupsonline';q('u').value=''}
else{const u=q('u').value.trim();if(!u){alert('Вставьте ссылку Телемоста в поле выше');return}
q('a').value='--role=exit --mode=l4 --transport=telemost --url="'+u+'" --debug'}}
async function add(){const r=await api('add','POST',{name:q('n').value,args:q('a').value});if(r.error)alert(r.error);else{q('n').value=q('a').value='';load()}}
async function act(i,a){if(a=='delete'&&!confirm('Удалить подключение?'))return;await api(i+'/'+a,'POST');load()}
async function lg(i){const t=await api(i+'/logs');q('lg'+i).textContent=t;q('lg'+i).style.display='block'}
function sh(i){const e=q('sh'+i);e.style.display=e.style.display=='block'?'none':'block'}
async function load(){const d=await api('list');q('l').innerHTML=d.map(c=>`<div class=c><b>${E(c.name)}</b> <small>#${c.id}</small>
<span class="${c.status=='active'?'ok':'bad'}">● ${E(c.status)}</span><br><code>./openflux ${E(c.args.join(' '))}</code><br>
<button onclick="act('${c.id}','start')">Старт</button><button onclick="act('${c.id}','stop')" class=g>Стоп</button>
<button onclick="act('${c.id}','restart')" class=g>Рестарт</button><button onclick="lg('${c.id}')" class=g>Логи</button>
<button onclick="sh('${c.id}')">Ссылка / QR</button><button onclick="act('${c.id}','delete')" class=r>Удалить</button>
<pre id=lg${c.id} style="display:none;max-height:260px;overflow:auto"></pre>
<div id=sh${c.id} style="display:none">${c.link?'<p><b>Ссылка:</b><br><code>'+E(c.link)+'</code></p>':'<p>openflux:// ссылка ещё не получена от узла.</p>'}
${c.code?'<p><b>Код (base64):</b><br><code>'+E(c.code)+'</code></p>':''}
${(c.link||c.code)?'<img src="'+B+'api/'+c.id+'/qr.svg?'+Date.now()+'" style="background:#fff;padding:8px;border-radius:8px;width:240px">':''}</div></div>`).join('')||'<p>Подключений пока нет.</p>'}
load();setInterval(()=>{if(!document.activeElement||document.activeElement.tagName!='TEXTAREA')load()},8000);
</script>"""

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def out(self, code, body, ct="application/json"):
        b = body if isinstance(body, bytes) else (json.dumps(body) if ct == "application/json" else body).encode()
        self.send_response(code); self.send_header("Content-Type", ct + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def authed(self):
        h = self.headers.get("Authorization", "")
        try: u, p = base64.b64decode(h.split()[1]).decode().split(":", 1)
        except Exception: u = p = ""
        ok = hmac.compare_digest(u, CFG["user"]) & hmac.compare_digest(p, CFG["password"])
        if not ok:
            time.sleep(1)
            self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="OpenFlux"')
            self.send_header("Content-Length", "0"); self.end_headers()
        return ok
    def route(self, method):
        base = "/" + CFG["path"]
        path = self.path.split("?")[0]
        if path != base and not path.startswith(base + "/"): return self.out(404, "not found", "text/plain")
        if not self.authed(): return
        sub = path[len(base):].strip("/")
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        if sub == "" and method == "GET": return self.out(200, PAGE, "text/html")
        p = sub.split("/")
        if p[0] != "api": return self.out(404, "not found", "text/plain")
        with LOCK: db = load()
        if p[1:] == ["list"]: return self.out(200, [view(i, c) for i, c in db.items()])
        if p[1:] == ["add"] and method == "POST":
            try: args = shlex.split(body.get("args", ""))
            except ValueError as e: return self.out(200, {"error": f"Ошибка разбора аргументов: {e}"})
            if not args: return self.out(200, {"error": "Пустые аргументы"})
            i = secrets.token_hex(3); c = {"name": body.get("name") or f"conn-{i}", "args": args}
            with LOCK: db = load(); db[i] = c; save(db)
            write_unit(i, c); sh("systemctl", "enable", "--now", unit(i))
            threading.Thread(target=capture, args=(i,), daemon=True).start()
            return self.out(200, {"id": i})
        i = p[1] if len(p) > 1 else ""
        if i not in db: return self.out(404, {"error": "no such connection"})
        a = p[2] if len(p) > 2 else ""
        if a == "logs": return self.out(200, logs(i) or "(пусто)", "text/plain")
        if a == "qr.svg":
            d = share_data(db[i])
            if not d: return self.out(404, "no data", "text/plain")
            buf = io.BytesIO(); qrcode.make(d, image_factory=qrcode.image.svg.SvgPathImage).save(buf)
            return self.out(200, buf.getvalue(), "image/svg+xml")
        if method == "POST" and a in ("start", "stop", "restart"):
            sh("systemctl", a, unit(i))
            if a != "stop": threading.Thread(target=capture, args=(i,), daemon=True).start()
            return self.out(200, {"ok": 1})
        if method == "POST" and a == "delete":
            sh("systemctl", "disable", "--now", unit(i)); 
            try: os.remove(f"/etc/systemd/system/{unit(i)}")
            except OSError: pass
            sh("systemctl", "daemon-reload")
            with LOCK: db = load(); db.pop(i, None); save(db)
            return self.out(200, {"ok": 1})
        self.out(404, {"error": "bad request"})
    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")

if __name__ == "__main__":
    s = ThreadingHTTPServer(("0.0.0.0", CFG["port"]), H)
    if CFG.get("cert"):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(CFG["cert"], CFG["key"])
        s.socket = ctx.wrap_socket(s.socket, server_side=True)
    s.serve_forever()
