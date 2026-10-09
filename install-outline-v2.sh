#!/usr/bin/env bash
# Ubuntu/Debian, systemd, fresh server. Run: sudo bash install-outline-wss.sh
set -Eeuo pipefail

OUTLINE_VERSION=1.9.2
BACKEND_PORT=18080
CONF_DIR=/etc/outline-wss
WEB_ROOT=/var/www/outline-wss
NGINX_CONF=/etc/nginx/sites-available/outline-wss

die() { printf '\nОшибка: %s\n' "$*" >&2; exit 1; }

enable_bbr() {
    # Optional root prefix is used by isolated tests; production uses /etc.
    local root=${1:-} available old_qdisc old_cc module_loaded=false
    if command -v modprobe >/dev/null && modprobe tcp_bbr 2>/dev/null; then
        module_loaded=true
    fi
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) || available=''
    if [[ " $available " != *' bbr '* ]]; then
        printf '\nBBR не включён: ядро/VPS не предоставляет tcp_bbr.\n' >&2
        return 0
    fi
    old_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null) || old_qdisc=''
    old_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || old_cc=''
    if [[ -z $old_qdisc || -z $old_cc ]]; then
        printf '\nBBR не включён: недоступны параметры ядра для проверки.\n' >&2
        return 0
    fi
    if ! sysctl -q -w net.core.default_qdisc=fq ||
        ! sysctl -q -w net.ipv4.tcp_congestion_control=bbr; then
        sysctl -q -w "net.core.default_qdisc=$old_qdisc" || true
        sysctl -q -w "net.ipv4.tcp_congestion_control=$old_cc" || true
        printf '\nBBR не включён: VPS не разрешает изменение параметров ядра.\n' >&2
        return 0
    fi
    install -d -m 0755 "${root}/etc/sysctl.d" "${root}/etc/modules-load.d"
    # One dedicated file, overwritten on reruns instead of appending duplicates.
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' \
        > "${root}/etc/sysctl.d/99-outline-wss-bbr.conf"
    chmod 0644 "${root}/etc/sysctl.d/99-outline-wss-bbr.conf"
    if [[ $module_loaded == true ]]; then
        printf 'tcp_bbr\n' > "${root}/etc/modules-load.d/outline-wss-bbr.conf"
        chmod 0644 "${root}/etc/modules-load.d/outline-wss-bbr.conf"
    fi
    printf '\nBBR включён: tcp_congestion_control=bbr, default_qdisc=fq.\n'
}

valid_domain() {
    local label
    local -a labels
    [[ ${#1} -le 253 && $1 == *.* && $1 != *..* ]] || return 1
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
    [[ $1 != *. ]]
}

render_backend() {
    cat <<EOF
web:
  servers:
    - id: web
      listen:
        - "127.0.0.1:${BACKEND_PORT}"
services:
  - listeners:
      - type: websocket-stream
        web_server: web
        path: "${TCP_PATH}"
    keys:
      - id: user-1
        cipher: chacha20-ietf-poly1305
        secret: "${SS_SECRET}"
EOF
}

render_client() {
    cat <<EOF
transport:
  \$type: tcpudp
  tcp:
    \$type: shadowsocks
    endpoint:
      \$type: first-supported
      options:
        - \$type: websocket
          url: "wss://${DOMAIN}:8443${TCP_PATH}"
        - \$type: websocket
          url: "wss://${DOMAIN}:443${TCP_PATH}"
    cipher: chacha20-ietf-poly1305
    secret: "${SS_SECRET}"
  udp:
    \$type: shadowsocks
    endpoint: "127.0.0.1:9"
    cipher: chacha20-ietf-poly1305
    secret: "${SS_SECRET}"
EOF
}

render_http() {
    cat <<EOF
# Managed by install-outline-wss.sh
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEB_ROOT};
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
}

render_nginx() {
    cat <<EOF
# Managed by install-outline-wss.sh
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEB_ROOT};
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://${DOMAIN}\$request_uri; }
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:OutlineTLS:10m;
    ssl_session_timeout 1d;
    server_tokens off;
    root ${WEB_ROOT};
    index index.html;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;

    # Bearer URL: anyone who knows this path can download the access key.
    location ~ "^/config/([a-f0-9]{64})\\.yaml\$" {
        alias ${CONF_DIR}/clients/\$1.yaml;
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options nosniff always;
        access_log off;
    }
EOF
    local path
    for path in "$TCP_PATH"; do
        cat <<EOF
    location = ${path} {
        # Ordinary visits to this path get a 404; only WebSocket upgrades pass.
        if (\$http_upgrade !~* "^websocket\$") { return 404; }
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        client_max_body_size 0;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        access_log off;
    }
EOF
    done
    cat <<EOF
    location = ${UDP_PATH} { return 403; }
EOF
    cat <<'EOF'
    location ~ /\. { return 404; }
    location / { try_files $uri $uri/ =404; }
}
EOF
    cat <<EOF
server {
    listen ${API_PORT} ssl;
    listen [::]:${API_PORT} ssl;
    server_name ${DOMAIN};
    ssl_certificate ${CONF_DIR}/api-cert.pem;
    ssl_certificate_key ${CONF_DIR}/api-key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    access_log off;
    client_max_body_size 64k;
    location ^~ /${API_TOKEN}/ {
        proxy_pass http://127.0.0.1:18100/;
        proxy_http_version 1.1;
        proxy_set_header X-Outline-Api-Token "${API_TOKEN}";
        proxy_set_header Host \$host;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }
    location / { return 404; }
}
EOF
}

install_random_site() {
    local choice archive stage
    choice=$(python3 -c 'import secrets; print(secrets.randbelow(3))')
    case "$choice" in
        0)
            SITE_TEMPLATE=clean-blog
            SITE_COMMIT=1ebc4f8f3b6194335df237a2a7837955a5a4a9aa
            SITE_SHA256=ee5b86b01a5eb5d7704d4da621aaae6c657b74821c11fc275e405058ba0fb67d
            ;;
        1)
            SITE_TEMPLATE=business-casual
            SITE_COMMIT=b6f928934386a54e08c2e7f40ebd9e4d7510bba4
            SITE_SHA256=aa5345459728854c05fe42a6b1bee3d4b8e2fb482707b8145d2529798f1d1db1
            ;;
        2)
            SITE_TEMPLATE=modern-business
            SITE_COMMIT=7d297106cbda2f04db4696752fcdb5b4dc9cd936
            SITE_SHA256=d708c0376a3c101aa8980c2caa0966dd8919878de59214d15e42c8a9be8a9257
            ;;
        *) die 'Не удалось выбрать шаблон сайта.' ;;
    esac
    printf '\nШаблон сайта: Start Bootstrap %s\n' "$SITE_TEMPLATE"
    archive="$TMP_DIR/startbootstrap.tar.gz"
    stage="$TMP_DIR/startbootstrap-site"
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 180 \
        "https://codeload.github.com/StartBootstrap/startbootstrap-${SITE_TEMPLATE}/tar.gz/${SITE_COMMIT}" \
        -o "$archive"
    python3 - "$archive" "$stage" "$SITE_SHA256" "$DOMAIN" <<'STARTBOOTSTRAP_PY'
import hashlib
import pathlib
import re
import sys
import tarfile

archive, destination, expected, domain = sys.argv[1:]
archive = pathlib.Path(archive)
destination = pathlib.Path(destination)
if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise SystemExit('Start Bootstrap: SHA256 архива не совпадает')
if not re.fullmatch(r'[a-z0-9.-]+', domain):
    raise SystemExit('Некорректный домен')
destination.mkdir(mode=0o755, parents=True, exist_ok=True)
with tarfile.open(archive, 'r:gz') as source:
    members = source.getmembers()
    roots = {pathlib.PurePosixPath(m.name).parts[0] for m in members if m.name}
    if len(roots) != 1:
        raise SystemExit('Некорректная структура архива шаблона')
    root = next(iter(roots))
    total = 0
    for member in members:
        parts = pathlib.PurePosixPath(member.name).parts
        if len(parts) < 3 or parts[:2] != (root, 'dist'):
            continue
        relative = pathlib.PurePosixPath(*parts[2:])
        if '..' in relative.parts or relative.is_absolute() or member.issym() or member.islnk():
            raise SystemExit('Небезопасный путь в архиве шаблона')
        target = destination.joinpath(*relative.parts)
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True, mode=0o755)
            continue
        if not member.isfile():
            raise SystemExit('Неподдерживаемый тип файла в шаблоне')
        total += member.size
        if total > 100_000_000:
            raise SystemExit('Шаблон слишком большой')
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        with source.extractfile(member) as inp, target.open('wb') as out:
            out.write(inp.read())
        target.chmod(0o644)
    licenses = [m for m in members if m.name == root + '/LICENSE' and m.isfile()]
    if len(licenses) != 1:
        raise SystemExit('Не найдена лицензия шаблона')
    (destination/'LICENSE.txt').write_bytes(source.extractfile(licenses[0]).read())
pages = list(destination.glob('*.html'))
if len(pages) < 3 or not (destination/'index.html').is_file() or not (destination/'css/styles.css').is_file():
    raise SystemExit('В шаблоне нет готового многостраничного сайта')
for page in pages:
    text = page.read_text()
    # These are static cover pages, not a configured third-party form service.
    text = re.sub(r'<script\b[^>]*\bsrc=["\']https://cdn\.startbootstrap\.com/sb-forms-latest\.js["\'][^>]*>\s*</script>', '', text, flags=re.I)
    text = re.sub(r'<form\b[^>]*>[\s\S]*?</form>',
        f'<div class="py-4"><p>Contact us by email:</p><a href="mailto:webmaster@{domain}">webmaster@{domain}</a></div>',
        text, flags=re.I)
    page.write_text(text)
print('Start Bootstrap: SHA256, лицензия и готовые страницы проверены; страниц:', len(pages))
STARTBOOTSTRAP_PY
    cp -a "$stage/." "$WEB_ROOT/"
    find "$WEB_ROOT" -type d -exec chmod 0755 {} +
    find "$WEB_ROOT" -type f -exec chmod 0644 {} +
}

render_api() {
    cat <<'OUTLINE_WSS_API_PY'
#!/usr/bin/env python3
"""Outline Manager adapter for an official Outline WSS backend.
Key CRUD and live usage counters; quotas and telemetry are unsupported.
"""
import copy
import grp
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from urllib.request import build_opener, ProxyHandler

CIPHER = 'chacha20-ietf-poly1305'
WSS_PORT = 8443
WSS_FALLBACK_PORT = 443
MAX_KEYS = 10000

class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message

def atomic_write(path, text, mode=0o600, group=None):
    path = Path(path)
    tmp = path.with_name(path.name + '.' + secrets.token_hex(8) + '.tmp')
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, 'w') as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        if group:
            os.chown(tmp, 0, grp.getgrnam(group).gr_gid)
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)

def backend_config(s):
    return json.dumps({'web': {'servers': [{'id': 'web', 'listen': ['127.0.0.1:18080']}]},
        'services': [{'listeners': [
            {'type': 'websocket-stream', 'web_server': 'web', 'path': s['tcpPath']}],
            'keys': [{'id': k['id'], 'cipher': CIPHER, 'secret': k['password']} for k in s['keys']]}]}, indent=2) + '\n'

def client_config(s, k):
    # JSON is valid YAML, so existing .yaml bearer links keep working.
    return json.dumps(client_config_json(s, k), indent=2) + '\n'

def client_config_json(s, k):
    return {'transport': {'$type': 'tcpudp',
        'tcp': {'$type': 'shadowsocks',
            'endpoint': {'$type': 'first-supported', 'options': [
                {'$type': 'websocket', 'url': f"wss://{s['domain']}:{port}{s['tcpPath']}"}
                for port in (WSS_PORT, WSS_FALLBACK_PORT)]},
            'cipher': CIPHER, 'secret': k['password']},
        # Do not omit UDP: null would send UDP directly. No remote UDP endpoint.
        'udp': {'$type': 'shadowsocks', 'endpoint': '127.0.0.1:9',
                'cipher': CIPHER, 'secret': k['password']}}}

def key_model(s, k):
    return {'id': k['id'], 'name': k['name'], 'password': k['password'], 'method': CIPHER,
        'port': WSS_PORT, 'accessUrl': f"ssconf://{s['domain']}/config/{k['token']}.yaml"}

class Store:
    def __init__(self, root, runner=None, groups=True):
        self.root = Path(root)
        self.lock = threading.RLock()
        self.runner = runner or self.reload
        self.groups = groups
        self.state = json.loads((self.root / 'state.json').read_text())
    @staticmethod
    def reload():
        def command(args):
            return subprocess.run(args, check=True, timeout=5, capture_output=True, text=True).stdout
        def main_pid():
            value = command(['systemctl', 'show', 'outline-wss', '--property=MainPID', '--value']).strip()
            if not value.isdigit() or int(value) <= 0:
                raise RuntimeError('Outline backend is not running')
            return value
        pid = main_pid()
        recent = command(['journalctl', '-u', 'outline-wss', '-n', '1', '-o', 'json', '--no-pager'])
        entries = [json.loads(line) for line in recent.splitlines() if line.startswith('{')]
        if not entries or not entries[-1].get('__CURSOR'):
            raise RuntimeError('Cannot verify config reload: Outline journal cursor unavailable')
        cursor = entries[-1]['__CURSOR']
        # Send only to the main process; never stop or restart the service.
        command(['systemctl', 'kill', '--kill-whom=main', '--signal=HUP', 'outline-wss'])
        # ExecReload sends HUP to the main process without restarting the service.
        command(['systemctl', 'reload', 'outline-wss'])
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if main_pid() != pid:
                raise RuntimeError('Outline process changed during config reload')
            log = command(['journalctl', '-u', 'outline-wss', '--after-cursor=' + cursor,
                           '-o', 'json', '--no-pager'])
            for line in log.splitlines():
                if not line.startswith('{'):
                    continue
                message = json.loads(line).get('MESSAGE', '')
                if 'Failed to update server.' in message:
                    raise RuntimeError('Outline rejected updated configuration')
                if 'Loaded config.' in message:
                    return
            time.sleep(0.1)
        raise RuntimeError('Outline did not confirm config reload')
    def publish(self, s):
        clients = self.root / 'clients'
        clients.mkdir(mode=0o751, exist_ok=True)
        # systemd UMask=0077 overrides mkdir's mode on first creation.
        # nginx needs traversal to known bearer filenames, not directory listing.
        clients.chmod(0o751)
        for k in s['keys']:
            target = clients / (k['token'] + '.yaml')
            text = client_config(s, k)
            if not target.exists() or target.read_text() != text:
                atomic_write(target, text, 0o640, 'www-data' if self.groups else None)
        atomic_write(self.root / 'config.yaml', backend_config(s),
                     0o640, 'outline-wss' if self.groups else None)
    def prune(self):
        keep = {k['token'] + '.yaml' for k in self.state['keys']}
        for file in (self.root / 'clients').glob('*.yaml'):
            if file.name not in keep:
                file.unlink()
        if self.state['keys']:
            k = self.state['keys'][0]
            atomic_write(self.root / 'access-key.txt', key_model(self.state, k)['accessUrl'] + '\n')
            atomic_write(self.root / 'client.yaml', client_config(self.state, k),
                         0o640, 'www-data' if self.groups else None)
        else:
            (self.root / 'access-key.txt').unlink(missing_ok=True)
            (self.root / 'client.yaml').unlink(missing_ok=True)
    def reconcile(self):
        changed = (self.root / 'config.yaml').read_text() != backend_config(self.state)
        self.publish(self.state)
        if changed:
            self.runner()
        self.prune()
    def commit(self, new, changed=False):
        old = copy.deepcopy(self.state)
        try:
            if changed:
                self.publish(new)
                self.runner()
            atomic_write(self.root / 'state.json', json.dumps(new, indent=2) + '\n')
        except Exception:
            self.publish(old)
            if changed:
                self.runner()
            self.prune()
            raise
        self.state = new
        self.prune()
    def usage(self):
        try:
            with build_opener(ProxyHandler({})).open('http://127.0.0.1:18090/metrics', timeout=5) as r:
                text = r.read(4000001)
            if len(text) > 4000000:
                raise ValueError('metrics too large')
        except Exception as e:
            raise APIError(503, 'Outline metrics unavailable') from e
        totals = {k['id']: 0 for k in self.state['keys']}
        for line in text.decode().splitlines():
            m = re.fullmatch(r'shadowsocks_data_bytes\{(.*?)\}\s+([0-9.eE+\-]+)(?:\s+\d+)?', line)
            if m:
                labels = dict(re.findall(r'(\w+)="([^"\\]*)"', m[1]))
                if labels.get('dir') in ('c>p', 'p<c') and labels.get('access_key') in totals:
                    totals[labels['access_key']] += int(float(m[2]))
        return {'bytesTransferredByUserId': totals}
    def dispatch(self, method, path, body):
        with self.lock:
            s = self.state
            if method == 'GET' and path == '/server':
                return 200, {'name': s['name'], 'serverId': s['serverId'], 'version': '1.9.2',
                    'createdTimestampMs': s['createdTimestampMs'], 'metricsEnabled': False,
                    'portForNewAccessKeys': WSS_PORT, 'hostnameForAccessKeys': s['domain'],
                    'transport': 'wss',
                    'wssTcpUrl': f"wss://{s['domain']}:{WSS_PORT}{s['tcpPath']}",
                    'wssTcpFallbackUrl': f"wss://{s['domain']}:{WSS_FALLBACK_PORT}{s['tcpPath']}",
                    'wssUdpUrl': None, 'udpEnabled': False}
            if method == 'GET' and path == '/metrics/transfer':
                return 200, self.usage()
            if method == 'GET' and path == '/access-keys':
                return 200, {'accessKeys': [key_model(s, k) for k in s['keys']]}
            if 'data-limit' in path:
                if method == 'DELETE':
                    return 204, None
                raise APIError(501, 'Data limits are not supported by this WSS adapter')
            if method == 'PUT' and path == '/metrics/enabled':
                if body.get('metricsEnabled') is not False:
                    raise APIError(501, 'Telemetry submission is not supported')
                return 204, None
            if method == 'PUT' and path == '/server/port-for-new-access-keys':
                if body.get('port') != WSS_PORT:
                    raise APIError(400, 'WSS primary port is fixed to 8443')
                return 204, None
            if method == 'PUT' and path == '/server/hostname-for-access-keys':
                if body.get('hostname') != s['domain']:
                    raise APIError(400, 'Changing hostname requires nginx and certificate changes')
                return 204, None
            if method == 'PUT' and path == '/name':
                name = body.get('name')
                if not isinstance(name, str) or len(name) > 200:
                    raise APIError(400, 'Invalid server name')
                new = copy.deepcopy(s)
                new['name'] = name
                self.commit(new)
                return 204, None
            m = re.fullmatch(r'/access-keys/([A-Za-z0-9_-]{1,64})(/name|/config)?', path)
            kid = m[1] if m else None
            key = next((k for k in s['keys'] if k['id'] == kid), None)
            if (method == 'POST' and path == '/access-keys') or (method == 'PUT' and m and not m[2]):
                if len(s['keys']) >= MAX_KEYS or key:
                    raise APIError(409, 'Key already exists or maximum number of keys reached')
                if body.get('port', WSS_PORT) != WSS_PORT or body.get('method', CIPHER) != CIPHER:
                    raise APIError(400, 'Only port 8443 and chacha20-ietf-poly1305 are supported')
                if 'limit' in body:
                    raise APIError(501, 'Data limits are not supported')
                name, password = body.get('name', ''), body.get('password', secrets.token_urlsafe(32))
                if not isinstance(name, str) or len(name) > 200:
                    raise APIError(400, 'Invalid key name')
                if not isinstance(password, str) or not 16 <= len(password) <= 256:
                    raise APIError(400, 'Password must contain 16 to 256 characters')
                new = copy.deepcopy(s)
                if kid is None:
                    kid = str(new['nextId'])
                    new['nextId'] += 1
                    while any(k['id'] == kid for k in new['keys']):
                        kid = str(new['nextId'])
                        new['nextId'] += 1
                created = {'id': kid, 'name': name, 'password': password, 'token': secrets.token_hex(32)}
                new['keys'].append(created)
                self.commit(new, changed=True)
                return 201, key_model(new, created)
            if m:
                if key is None:
                    raise APIError(404, 'Key not found')
                if method == 'GET' and m[2] == '/config':
                    return 200, client_config_json(s, key)
                if method == 'GET' and not m[2]:
                    return 200, key_model(s, key)
                if method == 'PUT' and m[2]:
                    name = body.get('name')
                    if not isinstance(name, str) or len(name) > 200:
                        raise APIError(400, 'Invalid key name')
                    new = copy.deepcopy(s)
                    next(k for k in new['keys'] if k['id'] == kid)['name'] = name
                    self.commit(new)
                    return 204, None
                if method == 'DELETE' and not m[2]:
                    new = copy.deepcopy(s)
                    new['keys'] = [k for k in new['keys'] if k['id'] != kid]
                    self.commit(new, changed=True)
                    return 204, None
            raise APIError(404, 'Endpoint not found')

class Handler(BaseHTTPRequestHandler):
    store = None
    server_version, sys_version = 'OutlineWSSAPI', ''
    def setup(self):
        super().setup()
        self.connection.settimeout(10)
    def log_message(self, *_args):
        pass
    def reply(self, status, payload=None):
        data = json.dumps(payload).encode() if payload is not None else b''
        self.send_response(status)
        for k, v in [('Content-Type','application/json'), ('Cache-Control','no-store'),
                     ('Access-Control-Allow-Origin','*'),
                     ('Access-Control-Allow-Methods','GET, POST, PUT, DELETE, OPTIONS'),
                     ('Access-Control-Allow-Headers','Content-Type'), ('Content-Length',str(len(data)))]:
            self.send_header(k, v)
        self.end_headers()
        if data:
            self.wfile.write(data)
    def handle_request(self):
        try:
            if not hmac.compare_digest(self.headers.get('X-Outline-Api-Token', ''), self.store.state['apiToken']):
                raise APIError(404, 'Not found')
            if self.command == 'OPTIONS':
                self.reply(204)
                return
            if self.headers.get('Transfer-Encoding'):
                raise APIError(400, 'Transfer-Encoding is not supported')
            try:
                length = int(self.headers.get('Content-Length', '0'))
            except ValueError:
                raise APIError(400, 'Invalid Content-Length')
            if not 0 <= length <= 65536:
                raise APIError(413, 'Request body too large')
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise APIError(400, 'Incomplete request body')
            body = {}
            if raw:
                try:
                    if self.headers.get('Content-Type', '').split(';', 1)[0] == 'application/x-www-form-urlencoded':
                        body = {k: v[-1] for k, v in parse_qs(raw.decode(), keep_blank_values=True).items()}
                    else:
                        body = json.loads(raw)
                    if not isinstance(body, dict):
                        raise ValueError('Expected object')
                except (ValueError, UnicodeError):
                    raise APIError(400, 'Invalid body')
            status, data = self.store.dispatch(self.command, urlsplit(self.path).path, body)
            self.reply(status, data)
        except APIError as e:
            self.reply(e.status, {'code':'Error', 'message':e.message})
        except Exception as e:
            print('API operation failed:', type(e).__name__, file=sys.stderr, flush=True)
            self.reply(500, {'code':'InternalError', 'message':'Operation failed; inspect API service log'})
    do_GET = do_POST = do_PUT = do_DELETE = do_OPTIONS = handle_request

def main():
    Handler.store = Store(sys.argv[1] if len(sys.argv) > 1 else '/etc/outline-wss')
    Handler.store.reconcile()
    server = ThreadingHTTPServer(('127.0.0.1', 18100), Handler)
    server.daemon_threads = True
    server.serve_forever()

if __name__ == '__main__':
    main()
OUTLINE_WSS_API_PY
}

select_api_port() {
    API_PORT=$(python3 - "$CONF_DIR" <<'API_PORT_PY'
import errno, pathlib, secrets, socket, sys
root = pathlib.Path(sys.argv[1])
file = root / 'api-port'
excluded = {6044, 8443, 18080, 18090, 18100}
if file.exists():
    value = file.read_text().strip()
    if not value.isdigit() or not 1024 <= int(value) <= 65535:
        raise SystemExit('Invalid saved API port')
    if int(value) not in excluded:
        print(value)
        raise SystemExit(0)
ports = list(range(1024, 65536))
secrets.SystemRandom().shuffle(ports)
for port in ports:
    if port in excluded:
        continue
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(('0.0.0.0', port))
            if socket.has_ipv6:
                try:
                    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock6:
                        sock6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                        sock6.bind(('::', port))
                except OSError as error:
                    if error.errno not in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL):
                        raise
    except OSError:
        continue
    file.write_text(str(port) + '\n')
    file.chmod(0o600)
    print(port)
    break
else:
    raise SystemExit('No free TCP port for Outline API')
API_PORT_PY
    ) || die 'Не удалось выбрать порт API.'
    [[ $API_PORT =~ ^[0-9]+$ ]] || die 'Некорректный порт API.'
    export API_PORT
}

configure_nginx_capacity() {
    bash <<'OUTLINE_CAPACITY_SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }
backup=$(mktemp /etc/nginx/nginx.conf.outline-backup.XXXXXX)
cp -p /etc/nginx/nginx.conf "$backup"
python3 - /etc/nginx/nginx.conf <<'NGINX_TUNE_PY'
import pathlib, re, sys
path=pathlib.Path(sys.argv[1]); text=path.read_text()
def main_directive(name,value):
    global text
    pattern=rf'(?m)^[ \t]*{name}\s+[^;]+;'
    matches=list(re.finditer(pattern,text))
    if len(matches)>1: raise SystemExit('Ambiguous nginx '+name)
    text=re.sub(pattern,name+' '+value+';',text) if matches else name+' '+value+';\n'+text
main_directive('worker_processes','auto')
main_directive('worker_rlimit_nofile','131072')
main_directive('worker_rlimit_nofile','65535')
events=list(re.finditer(r'(?m)^[ \t]*events\s*\{([^{}]*)\}',text))
if len(events)!=1: raise SystemExit('Expected one plain nginx events block')
event=events[0]; body=event.group(1)
pattern=r'(?m)^[ \t]*worker_connections\s+[^;]+;'
if len(re.findall(pattern,body))>1: raise SystemExit('Ambiguous worker_connections')
body=re.sub(pattern,'    worker_connections 16384;',body) if re.search(pattern,body) else '\n    worker_connections 16384;\n'+body
pattern=r'(?m)^[ \t]*multi_accept\s+[^;]+;'
if len(re.findall(pattern,body))>1: raise SystemExit('Ambiguous multi_accept')
body=re.sub(pattern,'    multi_accept on;',body) if re.search(pattern,body) else '\n    multi_accept on;\n'+body
text=text[:event.start(1)]+body+text[event.end(1):]
path.write_text(text)
NGINX_TUNE_PY
if ! nginx -t; then
    cp -p "$backup" /etc/nginx/nginx.conf
    echo "nginx config rejected; restored backup: $backup" >&2
    exit 1
fi
for unit in nginx outline-wss; do
    install -d -m 0755 "/etc/systemd/system/${unit}.service.d"
    printf '[Service]\nLimitNOFILE=131072\n' > "/etc/systemd/system/${unit}.service.d/outline-capacity.conf"
    printf '[Service]\nLimitNOFILE=65535\n' > "/etc/systemd/system/${unit}.service.d/outline-capacity.conf"
done
printf '[Service]\nExecReload=\nExecReload=/bin/kill -HUP $MAINPID\n' > /etc/systemd/system/outline-wss.service.d/reload.conf
systemctl daemon-reload
# Apply limits to running masters without restarting either service.
for unit in nginx outline-wss; do
    pid=$(systemctl show "$unit" --property=MainPID --value)
    if [[ $pid =~ ^[1-9][0-9]*$ ]]; then
        prlimit --pid "$pid" --nofile=131072:131072
        prlimit --pid "$pid" --nofile=65535:65535
    fi
done
if systemctl is-active --quiet nginx; then systemctl reload nginx; fi
echo 'nginx: auto workers, 16384 connections/worker; nginx/Outline NOFILE=131072.'
echo 'nginx: auto workers, 16384 connections/worker; nginx/Outline NOFILE=65535.'
echo "Backup: $backup"
OUTLINE_CAPACITY_SH
}

install_api() {
    configure_nginx_capacity
    select_api_port
    install -d -m 0755 /usr/local/lib/outline-wss
    render_api > /usr/local/lib/outline-wss/api.py
    chmod 0644 /usr/local/lib/outline-wss/api.py
    INITIAL_KEY_PATH="${KEY_PATH:-}" python3 - "$CONF_DIR" <<'PY'
import json, os, pathlib, re, secrets, time, uuid
from urllib.parse import urlsplit
import yaml
root = pathlib.Path(__import__('sys').argv[1])
if not (root / 'state.json').exists():
    backend = yaml.safe_load((root / 'config.yaml').read_text())
    client = yaml.safe_load((root / 'client.yaml').read_text())
    endpoint = client['transport']['tcp']['endpoint']
domain = urlsplit(endpoint.get('url') or endpoint['options'][0]['url']).hostname
    if not domain or not re.fullmatch(r'[a-z0-9.-]+', domain):
        raise SystemExit('Invalid domain in existing client configuration')
    listeners = backend['services'][0]['listeners']
    key_path = os.environ.get('INITIAL_KEY_PATH', '')
    if not key_path and (root / 'access-key.txt').exists():
        key_path = urlsplit((root / 'access-key.txt').read_text().strip()).path
    token = pathlib.PurePosixPath(key_path).stem
    if not re.fullmatch(r'[a-f0-9]{64}', token):
        token = secrets.token_hex(32)
    old_keys = backend['services'][0]['keys']
    if len(old_keys) != 1:
        raise SystemExit('Migration expects the original single-key WSS installation')
    state = {'domain': domain, 'name': 'Outline WSS', 'serverId': str(uuid.uuid4()),
        'createdTimestampMs': int(time.time()*1000), 'apiToken': secrets.token_hex(32),
        'tcpPath': next(x['path'] for x in listeners if x['type']=='websocket-stream'),
        'udpPath': next((x['path'] for x in listeners if x['type']=='websocket-packet'),
                        '/v2/api/'+secrets.token_hex(24)+'/packet'),
        'nextId': 1, 'keys': [{'id': str(old_keys[0]['id']), 'name': 'First key',
                              'password': old_keys[0]['secret'], 'token': token}]}
    (root / 'state.json').write_text(json.dumps(state, indent=2)+'\n')
    (root / 'state.json').chmod(0o600)
PY
    local -a values
    mapfile -t values < <(python3 - "$CONF_DIR/state.json" <<'PY'
import json, sys
s=json.load(open(sys.argv[1]))
for k in ('domain','tcpPath','udpPath','apiToken'): print(s[k])
PY
    )
    [[ ${#values[@]} -eq 4 ]] || die 'Не удалось прочитать параметры API.'
    DOMAIN=${values[0]}
    TCP_PATH=${values[1]}
    UDP_PATH=${values[2]}
    API_TOKEN=${values[3]}
    valid_domain "$DOMAIN" || die 'Некорректный домен в state.json.'
    [[ $TCP_PATH =~ ^/v2/api/[a-f0-9]+/stream$ && $UDP_PATH =~ ^/v2/api/[a-f0-9]+/packet$ &&
       $API_TOKEN =~ ^[a-f0-9]{64}$ ]] || die 'Некорректные пути в state.json.'
    if [[ ! -s ${CONF_DIR}/api-cert.pem ]]; then
        openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
            -subj "/CN=Outline WSS Management" \
            -keyout "$CONF_DIR/api-key.pem" -out "$CONF_DIR/api-cert.pem"
        chmod 0600 "$CONF_DIR/api-key.pem"
        chmod 0644 "$CONF_DIR/api-cert.pem"
    fi
    # Outline Manager pins this separate certificate; website renewals do not change it.
    local api_host
    api_host=$(curl -4 --fail --silent --show-error --connect-timeout 10 --max-time 20 https://api.ipify.org || true)
    if ! python3 - "$api_host" <<'PY'
import ipaddress, sys
try:
    a=ipaddress.ip_address(sys.argv[1])
    assert a.version == 4 and a.is_global
except Exception:
    raise SystemExit(1)
PY
    then
        api_host=$DOMAIN
        printf 'Не удалось определить публичный IPv4: API использует домен. Cloudflare Proxy для API должен быть выключен.\n'
    fi
    API_HOST="$api_host" python3 - "$CONF_DIR" <<'PY'
import json, os, pathlib, ssl, hashlib, sys
root=pathlib.Path(sys.argv[1]); s=json.loads((root/'state.json').read_text())
der=ssl.PEM_cert_to_DER_cert((root/'api-cert.pem').read_text())
m={'apiUrl':f"https://{os.environ['API_HOST']}:{os.environ['API_PORT']}/{s['apiToken']}",
   'certSha256':hashlib.sha256(der).hexdigest().upper()}
(root/'manager.json').write_text(json.dumps(m,indent=2)+'\n')
(root/'manager.json').chmod(0o600)
PY
    # Expose metrics only on loopback for the management adapter.
    sed -i 's|^ExecStart=.*|ExecStart=/usr/local/bin/outline-ss-server -config=/etc/outline-wss/config.yaml -metrics=127.0.0.1:18090|' \
        /etc/systemd/system/outline-wss.service
    cat > /etc/systemd/system/outline-wss-api.service <<'EOF'
[Unit]
Description=Outline WSS management API adapter
After=outline-wss.service
Wants=outline-wss.service
[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/outline-wss/api.py /etc/outline-wss
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/etc/outline-wss
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/outline-wss-api.service
    systemctl daemon-reload
    systemctl restart outline-wss
    systemctl enable --now outline-wss-api
    # Ensure a re-run loads the newly embedded API too.
    systemctl restart outline-wss-api
    cp -a "$NGINX_CONF" "$CONF_DIR/nginx-before-api.conf"
    render_nginx > "$NGINX_CONF"
    chmod 0600 "$NGINX_CONF"
    nginx -t
    systemctl reload nginx
    ufw allow "${API_PORT}/tcp"
    ufw --force delete allow 6044/tcp
    local attempt api_ready=0
    for attempt in {1..20}; do
        # The API certificate is pinned rather than hostname-validated by Manager.
        if API_TEST_TOKEN="$API_TOKEN" python3 - "$CONF_DIR" 2>/dev/null <<'PY'
import os, ssl, sys, urllib.request
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname=False
ctx.load_verify_locations(sys.argv[1]+'/api-cert.pem')
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx))
with opener.open('https://127.0.0.1:'+os.environ['API_PORT']+'/'+os.environ['API_TEST_TOKEN']+'/server',timeout=3) as r:
    assert r.status == 200
PY
        then api_ready=1; break; fi
        sleep 1
    done
    ((api_ready == 1)) || die 'API не ответил: journalctl -u outline-wss-api -n 100.'
    API_TEST_TOKEN="$API_TOKEN" python3 - "$CONF_DIR" <<'PY'
import json, os, pathlib, ssl, sys, urllib.error, urllib.request
root=pathlib.Path(sys.argv[1])
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname=False
ctx.load_verify_locations(str(root/'api-cert.pem'))
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx))
base='https://127.0.0.1:'+os.environ['API_PORT']+'/'+os.environ['API_TEST_TOKEN']
def request(method,path,body=None):
    req=urllib.request.Request(base+path,method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Content-Type':'application/json'})
    with opener.open(req,timeout=45) as r:
        raw=r.read()
        return json.loads(raw) if raw else None
key=request('POST','/access-keys',{'name':'Installation check'})
try:
    assert key['port']==8443 and key['accessUrl'].startswith('ssconf://')
    token=key['accessUrl'].rsplit('/',1)[-1]
    assert (root/'clients'/token).is_file()
    assert key['password'] in (root/'config.yaml').read_text()
    request('PUT','/access-keys/'+key['id']+'/name',{'name':'Installation check renamed'})
    assert request('GET','/access-keys/'+key['id'])['name']=='Installation check renamed'
finally:
    request('DELETE','/access-keys/'+key['id'])
assert not (root/'clients'/token).exists()
assert key['password'] not in (root/'config.yaml').read_text()
request('GET','/metrics/transfer')
print('API: создание, переименование, удаление WSS-ключа и метрики проверены.')
PY
}

export_app_config() {
    python3 - "$CONF_DIR" <<'APP_CONFIG_PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manager = json.loads((root / 'manager.json').read_text())
state = json.loads((root / 'state.json').read_text())
bot_config = dict(manager, transport='wss',
    wss_tcp_url=f"wss://{state['domain']}:8443{state['tcpPath']}",
    wss_tcp_fallback_url=f"wss://{state['domain']}:443{state['tcpPath']}",
    wss_udp_url=None, udp_enabled=False)
import os
fd = os.open(root / 'bot-server.json', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as out:
    json.dump(bot_config, out, ensure_ascii=False, indent=2)
    out.write('\n')
(root / 'bot-server.json').chmod(0o600)
config = {
    'schemaVersion': 1,
    'provider': 'outline-wss-adapter',
    'apiUrl': manager['apiUrl'],
    'tls': {'mode': 'certificate-sha256', 'certSha256': manager['certSha256']},
    'transports': ['wss'],
    'capabilities': {'createKeys': True, 'deleteKeys': True, 'renameKeys': True,
                     'clientConfigJson': True, 'legacyShadowsocks': False,
                     'trafficLimits': False},
    'operations': {
        'createKey': {'method': 'POST', 'path': '/access-keys',
                      'bodyExample': {'name': 'user-123'}},
        'listKeys': {'method': 'GET', 'path': '/access-keys'},
        'getKey': {'method': 'GET', 'path': '/access-keys/{id}'},
        'getClientConfig': {'method': 'GET', 'path': '/access-keys/{id}/config'},
        'renameKey': {'method': 'PUT', 'path': '/access-keys/{id}/name',
                      'bodyExample': {'name': 'user-123'}},
        'deleteKey': {'method': 'DELETE', 'path': '/access-keys/{id}'},
    },
    'keyResponseFields': ['id', 'name', 'password', 'method', 'port', 'accessUrl'],
    'minimumOutlineClientVersion': '1.15.0',
}
target = root / 'app-api.json'
# This file contains the management secret, so never expose it through nginx.
import os
fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as out:
    json.dump(config, out, ensure_ascii=False, indent=2)
    out.write('\n')
target.chmod(0o600)
APP_CONFIG_PY
}

show_result() {
    export_app_config
    printf '\nКонфигурация API для backend вашего приложения (%s/app-api.json):\n' "$CONF_DIR"
    cat "${CONF_DIR}/app-api.json"
    printf '\nДанные для добавления сервера в Outline Manager:\n'
    cat "${CONF_DIR}/manager.json"
    printf '\nJSON для добавления сервера в админке VPN_Bot (%s/bot-server.json):\n' "$CONF_DIR"
    cat "${CONF_DIR}/bot-server.json"
    if [[ -s ${CONF_DIR}/access-key.txt ]]; then
        printf '\nПервый ключ для Outline Client:\n'
        cat "${CONF_DIR}/access-key.txt"
    fi
    printf '\nКонфигурация: %s/config.yaml\n' "$CONF_DIR"
    if [[ -s ${CONF_DIR}/api-port ]]; then
        printf 'Порт API (откройте TCP также в firewall хостинга): %s\n' "$(cat "$CONF_DIR/api-port")"
    fi
    printf 'Сайт: %s/index.html\n' "$WEB_ROOT"
    printf 'Журнал: journalctl -u outline-wss -n 100 --no-pager\n'
    printf 'Журнал API: journalctl -u outline-wss-api -n 100 --no-pager\n'
    printf 'Продление сертификата: certbot renew --dry-run\n'
}

main() {
    [[ $EUID -eq 0 ]] || die 'Запустите скрипт через sudo bash.'
    [[ -r /etc/os-release ]] || die 'Не найден /etc/os-release.'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ $ID == ubuntu || $ID == debian ]] || die 'Поддерживаются Ubuntu и Debian.'
    [[ -d /run/systemd/system ]] || die 'Нужен сервер с systemd.'
    if [[ ${1:-} == --add-api ]]; then
        [[ -s ${CONF_DIR}/config.yaml ]] &&
            [[ -s ${CONF_DIR}/client.yaml || -s ${CONF_DIR}/state.json ]] || die 'Не найдена предыдущая WSS-установка.'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-yaml kmod procps
        enable_bbr
        install_api
        show_result
        return
    fi
    [[ $# -eq 0 ]] || die 'Поддерживается только необязательный параметр --add-api.'
    if [[ -s ${CONF_DIR}/manager.json ]]; then
        printf 'Установка уже выполнялась; существующие ключи не изменены.\n'
        enable_bbr
        show_result
        return
    fi
    [[ ! -e ${CONF_DIR} && ! -e /etc/systemd/system/outline-wss.service ]] ||
        die 'Найдена незавершённая/существующая установка /etc/outline-wss. Не перезаписываю её.'
    case "$(uname -m)" in
        x86_64) ARCH=x86_64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) die 'Поддерживаются amd64 и arm64.' ;;
    esac
    printf 'Установка Outline WSS + nginx для чистого сервера Ubuntu/Debian.\n'
    printf 'Заранее направьте A-запись домена на VPS. AAAA должна быть корректной или отсутствовать.\n'
    printf 'На время установки отключите Cloudflare Proxy. Порты 80/443 должны быть доступны извне.\n'
    read -r -p 'Домен (например, vpn.example.com): ' DOMAIN </dev/tty
    DOMAIN=${DOMAIN,,}
    valid_domain "$DOMAIN" || die 'Введите домен без схемы, порта, пути и wildcard; IDN — в punycode.'
    ACME_EMAIL="webmaster@${DOMAIN}"
    SSH_PORT=22

    # Do not disturb existing applications or custom nginx virtual hosts.
    if command -v ss >/dev/null; then
        [[ -z $(ss -H -ltn '( sport = :80 or sport = :443 or sport = :18080 )') ]] ||
            die 'Порт 80, 443 или 18080 занят. Скрипт рассчитан на чистый сервер.'
    fi
    if [[ -d /etc/nginx/sites-enabled ]]; then
        local entry
        for entry in /etc/nginx/sites-enabled/*; do
            [[ ! -e $entry && ! -L $entry ]] && continue
            [[ $entry == /etc/nginx/sites-enabled/default && -L $entry ]] ||
                die 'Уже настроены сайты nginx; не перезаписываю их.'
        done
    fi
    local conf
    for conf in /etc/nginx/conf.d/*.conf; do
        [[ ! -e $conf ]] || die 'Найдена пользовательская конфигурация nginx в conf.d.'
    done
    [[ ! -e $WEB_ROOT && ! -e $NGINX_CONF ]] || die 'Каталог сайта или конфиг nginx уже существует.'

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y nginx certbot ca-certificates curl openssl python3 python3-yaml ufw iproute2 kmod procps
    enable_bbr
    [[ -z $(ss -H -ltn 'sport = :18080') ]] || die 'Локальный порт 18080 занят.'

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf -- "${TMP_DIR}"' EXIT
    # Download completely before executing; stop on download or syntax errors.
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 120 \
        'https://raw.githubusercontent.com/DaDe287/Traffic-Guard/refs/heads/main/install.sh' \
        -o "$TMP_DIR/traffic-guard-install.sh"
    bash -n "$TMP_DIR/traffic-guard-install.sh"

    # User-requested clean firewall policy. This deliberately removes old UFW rules.
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    local port
    for port in "$SSH_PORT" 80 443 8443; do
        ufw allow "${port}/tcp"
    done
    ufw --force enable

    local asset="outline-ss-server_${OUTLINE_VERSION}_linux_${ARCH}.tar.gz"
    local base="https://github.com/OutlineFoundation/tunnel-server/releases/download/v${OUTLINE_VERSION}"
    printf '\nЗагрузка официального outline-ss-server %s…\n' "$OUTLINE_VERSION"
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 180 \
        "$base/$asset" -o "$TMP_DIR/$asset"
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 60 \
        "$base/checksums.txt" -o "$TMP_DIR/checksums.txt"
    python3 - "$TMP_DIR" "$asset" <<'PY'
import hashlib, pathlib, sys, tarfile
root, name = pathlib.Path(sys.argv[1]), sys.argv[2]
expected = None
for line in (root / 'checksums.txt').read_text().splitlines():
    fields = line.split()
    if len(fields) == 2 and fields[1].lstrip('*') == name:
        expected = fields[0].lower()
if expected is None or hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
    raise SystemExit('Ошибка проверки SHA256 архива Outline')
with tarfile.open(root / name, 'r:gz') as archive:
    members = [m for m in archive.getmembers()
               if m.isfile() and pathlib.PurePosixPath(m.name).name == 'outline-ss-server']
    if len(members) != 1:
        raise SystemExit('Не найден единственный бинарный файл outline-ss-server')
    with archive.extractfile(members[0]) as src:
        (root / 'outline-ss-server').write_bytes(src.read())
PY
    install -m 0755 "$TMP_DIR/outline-ss-server" /usr/local/bin/outline-ss-server

    install -d -m 0755 "$WEB_ROOT/.well-known/acme-challenge"
    install_random_site
    render_http > "$NGINX_CONF"
    # Only the package's default enabled symlink is removed; its source is preserved.
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        unlink /etc/nginx/sites-enabled/default
    fi
    ln -s "$NGINX_CONF" /etc/nginx/sites-enabled/outline-wss
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx

    printf '\nВыпуск сертификата. Использование скрипта означает согласие с условиями Let’s Encrypt.\n'
    certbot certonly --webroot -w "$WEB_ROOT" --non-interactive --agree-tos \
        --email "$ACME_EMAIL" --cert-name "$DOMAIN" -d "$DOMAIN" ||
        die 'Сертификат не выпущен. Проверьте DNS, AAAA и внешний доступ к порту 80. HTTP-сайт оставлен для диагностики.'

    id outline-wss >/dev/null 2>&1 || useradd --system --user-group \
        --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin outline-wss
    install -d -m 0750 -o root -g outline-wss "$CONF_DIR"
    printf '{"template":"%s","commit":"%s","sha256":"%s"}\n' \
        "$SITE_TEMPLATE" "$SITE_COMMIT" "$SITE_SHA256" > "$CONF_DIR/site-template.json"
    TCP_PATH="/v2/api/$(openssl rand -hex 24)/stream"
    UDP_PATH="/v2/api/$(openssl rand -hex 24)/packet"
    KEY_PATH="/config/$(openssl rand -hex 32).yaml"
    SS_SECRET=$(openssl rand -base64 32)
    umask 077
    render_backend > "$CONF_DIR/config.yaml"
    chown root:outline-wss "$CONF_DIR/config.yaml"
    chmod 0640 "$CONF_DIR/config.yaml"
    render_client > "$CONF_DIR/client.yaml"
    chown root:www-data "$CONF_DIR/client.yaml"
    chmod 0640 "$CONF_DIR/client.yaml"
    # nginx needs directory traversal only; it cannot list server config or read it.
    chmod 0751 "$CONF_DIR"
    cat > /etc/systemd/system/outline-wss.service <<'EOF'
[Unit]
Description=Outline Shadowsocks over WebSocket
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=outline-wss
Group=outline-wss
ExecStart=/usr/local/bin/outline-ss-server -config=/etc/outline-wss/config.yaml
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
UMask=0077
LimitNOFILE=131072
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/outline-wss.service
    systemctl daemon-reload
    systemctl enable --now outline-wss
    sleep 2
    systemctl is-active --quiet outline-wss || die 'Outline не запустился: journalctl -u outline-wss -n 100.'

    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/outline-wss-nginx.sh <<'EOF'
#!/bin/sh
set -eu
nginx -t
systemctl reload nginx
EOF
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/outline-wss-nginx.sh
    systemctl enable --now certbot.timer

    install_api

    printf '\nУстановка и активация Traffic Guard…\n'
    bash "$TMP_DIR/traffic-guard-install.sh"
    /usr/local/bin/traffic-guard --version

    # Verify certificate, YAML download and both real WebSocket handshakes locally.
    curl --fail --silent --show-error --noproxy '*' --max-time 15 \
        --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" >/dev/null
    curl --fail --silent --show-error --noproxy '*' --max-time 15 \
        --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}${KEY_PATH}" -o "$TMP_DIR/client.yaml"
    cmp "$CONF_DIR/client.yaml" "$TMP_DIR/client.yaml" || die 'Загруженный ключ не совпадает с конфигурацией.'
    python3 - "$DOMAIN" "$TCP_PATH" "$UDP_PATH" <<'PY'
import base64, hashlib, os, socket, ssl, sys
domain = sys.argv[1]
for port in (8443, 443):
    path = sys.argv[2]
    key = base64.b64encode(os.urandom(16)).decode()
    request = (f'GET {path} HTTP/1.1\r\nHost: {domain}\r\n'
               'Upgrade: websocket\r\nConnection: Upgrade\r\n'
               f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n')
    with socket.create_connection(('127.0.0.1', port), timeout=10) as tcp:
        with ssl.create_default_context().wrap_socket(tcp, server_hostname=domain) as tls:
            tls.sendall(request.encode())
            data = b''
            while b'\r\n\r\n' not in data:
                part = tls.recv(4096)
                if not part:
                    raise SystemExit('WebSocket: соединение закрыто до ответа')
                data += part
                if len(data) > 65536:
                    raise SystemExit('WebSocket: слишком большой заголовок ответа')
            headers = data.split(b'\r\n\r\n', 1)[0].decode()
            if headers.split('\r\n')[0].split()[1] != '101':
                raise SystemExit('WebSocket не вернул 101: ' + headers.split('\r\n')[0])
            expected = base64.b64encode(hashlib.sha1(
                (key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            values = dict(line.split(':', 1) for line in headers.split('\r\n')[1:] if ':' in line)
            accept = next((v.strip() for k, v in values.items()
                           if k.lower() == 'sec-websocket-accept'), None)
            if accept != expected:
                raise SystemExit('WebSocket: неверный Sec-WebSocket-Accept')
print('HTTPS, загрузка ключа и TCP WebSocket на 8443/443 проверены.')
PY
    show_result
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    trap 'printf "\nУстановка остановлена на строке %s. Смотрите ошибку выше.\n" "$LINENO" >&2' ERR
    main "$@"
fi
