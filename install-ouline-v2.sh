#!/usr/bin/env bash
# Ubuntu/Debian, systemd, fresh server. Run: sudo bash install-outline-wss.sh
set -Eeuo pipefail

OUTLINE_VERSION=1.9.2
BACKEND_PORT=18080
CONF_DIR=/etc/outline-wss
WEB_ROOT=/var/www/outline-wss
NGINX_CONF=/etc/nginx/sites-available/outline-wss

die() { printf '\nОшибка: %s\n' "$*" >&2; exit 1; }

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
      - type: websocket-packet
        web_server: web
        path: "${UDP_PATH}"
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
      \$type: websocket
      url: "wss://${DOMAIN}:443${TCP_PATH}"
    cipher: chacha20-ietf-poly1305
    secret: "${SS_SECRET}"
  udp:
    \$type: shadowsocks
    endpoint:
      \$type: websocket
      url: "wss://${DOMAIN}:443${UDP_PATH}"
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
    location = ${KEY_PATH} {
        alias ${CONF_DIR}/client.yaml;
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options nosniff always;
        access_log off;
    }
EOF
    local path
    for path in "$TCP_PATH" "$UDP_PATH"; do
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
    cat <<'EOF'
    location ~ /\. { return 404; }
    location / { try_files $uri $uri/ =404; }
}
EOF
}

render_site() {
    cat <<'EOF'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Field Notes — Places, ideas, everyday details</title>
<style>
:root{color-scheme:light;--ink:#26362e;--paper:#f6f3eb;--line:#dcded2}*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:17px/1.7 system-ui,sans-serif}main{max-width:1050px;margin:auto;padding:30px 24px 60px}nav{display:flex;justify-content:space-between;border-bottom:1px solid var(--line);padding:12px 0 22px}nav a{color:inherit;text-decoration:none}small,.label{font-size:12px;letter-spacing:.15em;text-transform:uppercase}header{padding:75px 0 55px;max-width:780px}h1{font:clamp(42px,7vw,76px)/1.08 Georgia,serif;letter-spacing:-.035em;margin:18px 0 25px}header p{max-width:560px;color:#627166}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:24px}article{border-top:1px solid var(--line);padding-top:22px}h2{font:28px/1.25 Georgia,serif}article p{color:#627166}.art{height:150px;border-radius:3px;background:linear-gradient(145deg,#b5c0aa,#dde0c8)}article:nth-child(2) .art{background:linear-gradient(140deg,#dbb897,#eee0c7)}article:nth-child(3) .art{background:linear-gradient(140deg,#91aaa9,#cdd9d1)}section.about{border-top:1px solid var(--line);margin-top:65px;padding-top:28px;max-width:650px}footer{margin-top:55px;font-size:13px;color:#627166}@media(max-width:650px){.grid{grid-template-columns:1fr}header{padding-top:45px}.art{height:180px}}
</style></head><body><main>
<nav><strong>FIELD NOTES</strong><a href="#about">About this journal ↗</a></nav>
<header><span class="label">An independent journal</span><h1>A little room<br>for curiosity.</h1><p>Observations on places, thoughtful design, and the details that make everyday life feel a little richer.</p></header>
<div class="grid"><article><div class="art"></div><h2>Taking the slower route</h2><p>A walk without a destination leaves space to notice familiar streets in a different light.</p></article><article><div class="art"></div><h2>Things made to last</h2><p>Simple materials, careful decisions, and objects that become more interesting with time.</p></article><article><div class="art"></div><h2>A quiet beginning</h2><p>A notebook, an open window, and a few minutes before the day gets busy.</p></article></div>
<section class="about" id="about"><small>About</small><h2>Small observations. Open possibilities.</h2><p>Field Notes is a small personal corner of the web for collecting ideas and noticing what is close at hand. Thanks for stopping by.</p></section><footer>Field Notes · A personal journal</footer>
</main></body></html>
EOF
}

show_result() {
    printf '\nГотово. Ключ для Outline Client:\n'
    cat "${CONF_DIR}/access-key.txt"
    printf '\nКонфигурация: %s/config.yaml\n' "$CONF_DIR"
    printf 'Сайт: %s/index.html\n' "$WEB_ROOT"
    printf 'Журнал: journalctl -u outline-wss -n 100 --no-pager\n'
    printf 'Продление сертификата: certbot renew --dry-run\n'
}

main() {
    [[ $EUID -eq 0 ]] || die 'Запустите скрипт через sudo bash.'
    [[ -r /etc/os-release ]] || die 'Не найден /etc/os-release.'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ $ID == ubuntu || $ID == debian ]] || die 'Поддерживаются Ubuntu и Debian.'
    [[ -d /run/systemd/system ]] || die 'Нужен сервер с systemd.'
    if [[ -s ${CONF_DIR}/access-key.txt ]]; then
        printf 'Установка уже выполнялась; существующие ключи не изменены.\n'
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
    apt-get install -y nginx certbot ca-certificates curl openssl python3 ufw iproute2
    [[ -z $(ss -H -ltn 'sport = :18080') ]] || die 'Локальный порт 18080 занят.'

    # Preserve existing UFW rules. Permit SSH before enabling the firewall.
    ufw allow "${SSH_PORT}/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    if ! ufw status | LC_ALL=C grep -q '^Status: active'; then
        ufw default deny incoming
        ufw default allow outgoing
        ufw --force enable
    fi

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf -- "${TMP_DIR}"' EXIT
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
    render_site > "$WEB_ROOT/index.html"
    chmod 0644 "$WEB_ROOT/index.html"
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
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/outline-wss.service
    render_nginx > "$NGINX_CONF"
    chmod 0644 "$NGINX_CONF"
    nginx -t
    systemctl daemon-reload
    systemctl enable --now outline-wss
    systemctl reload nginx
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

    # Verify certificate, YAML download and both real WebSocket handshakes locally.
    curl --fail --silent --show-error --noproxy '*' --max-time 15 \
        --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" >/dev/null
    curl --fail --silent --show-error --noproxy '*' --max-time 15 \
        --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}${KEY_PATH}" -o "$TMP_DIR/client.yaml"
    cmp "$CONF_DIR/client.yaml" "$TMP_DIR/client.yaml" || die 'Загруженный ключ не совпадает с конфигурацией.'
    python3 - "$DOMAIN" "$TCP_PATH" "$UDP_PATH" <<'PY'
import base64, hashlib, os, socket, ssl, sys
domain = sys.argv[1]
for path in sys.argv[2:]:
    key = base64.b64encode(os.urandom(16)).decode()
    request = (f'GET {path} HTTP/1.1\r\nHost: {domain}\r\n'
               'Upgrade: websocket\r\nConnection: Upgrade\r\n'
               f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n')
    with socket.create_connection(('127.0.0.1', 443), timeout=10) as tcp:
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
print('HTTPS, загрузка ключа и оба WebSocket-входа проверены.')
PY
    printf 'ssconf://%s%s\n' "$DOMAIN" "$KEY_PATH" > "$CONF_DIR/access-key.txt"
    chmod 0600 "$CONF_DIR/access-key.txt"
    show_result
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    trap 'printf "\nУстановка остановлена на строке %s. Смотрите ошибку выше.\n" "$LINENO" >&2' ERR
    main "$@"
fi
