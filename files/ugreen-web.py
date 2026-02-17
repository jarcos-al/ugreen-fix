#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess
import urllib.parse
import os
import time

HOST = os.environ.get("UGREEN_WEB_HOST", "0.0.0.0")
PORT = int(os.environ.get("UGREEN_WEB_PORT", "8088"))

CT_ID = os.environ.get("UGREEN_CT_ID", "402")
WEB_TOKEN = os.environ.get("UGREEN_WEB_TOKEN", "")  # si vacío, no exige token

FIX_SCRIPT = os.environ.get("UGREEN_FIX_SCRIPT", "/usr/local/sbin/ugreen-reset-and-restart.sh")
LOG_FILE = os.environ.get("UGREEN_FIX_LOG", "/var/log/ugreen-fix.log")

CT_RESTART_MODE = os.environ.get("UGREEN_CT_RESTART_MODE", "reboot")  # reboot | stop-start
CT_TIMEOUT_SEC = int(os.environ.get("UGREEN_CT_TIMEOUT_SEC", "30"))

HTML = r"""<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>UGREEN HDMI Capture</title>
  <style>
    body {
      font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif;
      background: #111;
      color: #eee;
      text-align: center;
      padding: 40px 16px;
    }
    .wrap { max-width: 720px; margin: 0 auto; }
    h1 { margin: 0 0 8px 0; font-size: 34px; letter-spacing: .5px; }
    p { margin: 0 0 24px 0; color: #bbb; }
    .btn {
      display: block;
      width: 100%;
      padding: 18px 16px;
      margin: 14px 0;
      border: none;
      border-radius: 12px;
      font-size: 18px;
      font-weight: 700;
      cursor: pointer;
    }
    .btn-red { background: #e53935; color: white; }
    .btn-blue { background: #1e88e5; color: white; }
    .small { color: #999; font-size: 13px; margin-top: 10px; }
    pre {
      text-align: left;
      background: #0b0b0b;
      border: 1px solid #222;
      padding: 14px;
      border-radius: 12px;
      overflow: auto;
      max-height: 320px;
      font-size: 12px;
      line-height: 1.35;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .tag {
      display: inline-block;
      margin-top: 12px;
      padding: 6px 10px;
      border-radius: 999px;
      background: #222;
      color: #bbb;
      font-size: 12px;
    }
    a { color: #8ab4f8; }
  </style>
</head>
<body>
  <div class="wrap">
    <h1>UGREEN HDMI Capture</h1>
    <p>Si el streaming se queda tonto, pulsa un botón.</p>

    <form method="POST" action="/fix__TOKENQS__">
      <button class="btn btn-red" type="submit">🔄 Reiniciar capturadora (USB)</button>
    </form>

    <form method="POST" action="/ct__TOKENQS__">
      <button class="btn btn-blue" type="submit">♻️ Reiniciar CT (LXC __CTID__)</button>
    </form>

    <div class="small">Token opcional: <code>?token=TU_TOKEN</code> o header <code>X-Token</code></div>
    <div class="tag">Último log</div>
    <pre>__LASTLOG__</pre>
  </div>
</body>
</html>
"""

def read_last(n=220):
    try:
        with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()[-n:]
        return "".join(lines).strip() or "(log vacío)"
    except FileNotFoundError:
        return "(aún no existe el log)"
    except Exception as e:
        return f"(error leyendo log: {e})"

def token_ok(handler):
    if not WEB_TOKEN:
        return True
    qs = urllib.parse.parse_qs(urllib.parse.urlparse(handler.path).query)
    t = ""
    if "token" in qs and qs["token"]:
        t = qs["token"][0]
    if not t:
        t = handler.headers.get("X-Token", "")
    return t == WEB_TOKEN

def run_cmd(cmd_list, timeout=60):
    # Devuelve (rc, output)
    try:
        p = subprocess.run(cmd_list, capture_output=True, text=True, timeout=timeout)
        out = (p.stdout or "") + (p.stderr or "")
        return p.returncode, out.strip()
    except subprocess.TimeoutExpired:
        return 124, f"Timeout ejecutando: {' '.join(cmd_list)}"
    except Exception as e:
        return 1, f"Error ejecutando: {' '.join(cmd_list)} -> {e}"

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body.encode("utf-8", errors="replace"))

    def do_GET(self):
        if not token_ok(self):
            self._send(403, "Forbidden")
            return

        token_qs = ""
        if WEB_TOKEN:
            # Si hay token configurado, mantenlo en enlaces/acciones para móvil (comodidad)
            token_qs = "?token=" + urllib.parse.quote(WEB_TOKEN)

        html = HTML.replace("__CTID__", str(CT_ID)) \
                   .replace("__LASTLOG__", read_last()) \
                   .replace("__TOKENQS__", token_qs)
        self._send(200, html)

    def do_POST(self):
        if not token_ok(self):
            self._send(403, "Forbidden")
            return

        path = urllib.parse.urlparse(self.path).path

        if path == "/fix":
            # Ejecuta el fix
            rc, out = run_cmd([FIX_SCRIPT], timeout=120)
            # No mostramos "out" enorme; el log ya se escribe en fichero
            self._send(200, "<meta http-equiv='refresh' content='0; url=/'/>OK")
            return

        if path == "/ct":
            # Reinicia CT
            if CT_RESTART_MODE == "stop-start":
                run_cmd(["pct", "stop", str(CT_ID)], timeout=CT_TIMEOUT_SEC)
                time.sleep(2)
                run_cmd(["pct", "start", str(CT_ID)], timeout=CT_TIMEOUT_SEC)
            else:
                # reboot (recomendado)
                run_cmd(["pct", "reboot", str(CT_ID)], timeout=CT_TIMEOUT_SEC)

            self._send(200, "<meta http-equiv='refresh' content='0; url=/'/>OK")
            return

        self._send(404, "Not Found")

    def log_message(self, fmt, *args):
        # Silencia el spam en journal
        return

def main():
    print(f"UGREEN web on http://{HOST}:{PORT} (CT={CT_ID})")
    httpd = HTTPServer((HOST, PORT), Handler)
    httpd.serve_forever()

if __name__ == "__main__":
    main()
