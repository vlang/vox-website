#!/usr/bin/env bash
# Runs as root on the Debian server after an isolated release is uploaded.
set -euo pipefail

release_dir="${1:?release directory required}"
enable_https="${2:-no}"
site_root=/var/www/vox-browser.org
service=vox-website

[[ "$release_dir" == "$site_root/releases/"* && -x "$release_dir/vox-website" ]] || {
    echo 'Invalid release directory or missing executable.' >&2
    exit 1
}
[[ "$enable_https" == yes || "$enable_https" == no ]] || exit 1
[[ "$(id -u)" == 0 ]] || { echo 'Run provisioning as root.' >&2; exit 1; }

missing_packages=()
command -v nginx >/dev/null || missing_packages+=(nginx)
command -v psql >/dev/null || missing_packages+=(postgresql libpq5)
command -v certbot >/dev/null || missing_packages+=(certbot python3-certbot-nginx)
if ((${#missing_packages[@]})); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
fi
ldd "$release_dir/vox-website"
if ldd "$release_dir/vox-website" | grep -q 'not found'; then
    echo 'The release has missing shared libraries.' >&2
    exit 1
fi

systemctl enable --now postgresql
getent passwd vox >/dev/null || useradd --system --user-group --home-dir "$site_root" --shell /usr/sbin/nologin vox
if ! runuser -u postgres -- psql -XAtqc "SELECT 1 FROM pg_roles WHERE rolname='vox'" | grep -qx 1; then
    runuser -u postgres -- createuser --login --no-superuser --no-createdb --no-createrole vox
fi
if ! runuser -u postgres -- psql -XAtqc "SELECT 1 FROM pg_database WHERE datname='vox'" | grep -qx 1; then
    runuser -u postgres -- createdb --owner=vox vox
fi
runuser -u vox -- psql 'host=/var/run/postgresql dbname=vox user=vox' -XAtqc 'SELECT current_user'

# Generate credentials only on the server. Use loopback TCP to match the
# database/role-specific password authentication rules below.
if [[ ! -e /etc/vox-website.env ]] || grep -q '^VOX_DB_CONNINFO="host=/var/run/postgresql' /etc/vox-website.env; then
    python3 - <<'PY'
import os
from pathlib import Path
import secrets
import subprocess

path = Path('/etc/vox-website.env')
existing = path.read_text().splitlines() if path.exists() else []
notes = next((line for line in existing if line.startswith('VOX_STATS_NOTES_KEY=')),
             'VOX_STATS_NOTES_KEY=' + secrets.token_hex(24))
password = secrets.token_hex(32)
subprocess.run(['runuser', '-u', 'postgres', '--', 'psql', '-X', '-v', 'ON_ERROR_STOP=1'],
               input="SET password_encryption = 'scram-sha-256'; ALTER ROLE vox PASSWORD '" + password + "';\n",
               text=True, stdout=subprocess.DEVNULL, check=True)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as output:
    output.write('VOX_DB_CONNINFO="host=127.0.0.1 port=5432 dbname=vox user=vox password=' +
                 password + ' connect_timeout=5"\n' + notes + '\n')
PY
    chown root:vox /etc/vox-website.env
    chmod 0640 /etc/vox-website.env
fi

# Require the generated password for this role/database, even if this shared
# server has permissive loopback rules for older applications. Leave those
# other applications' authentication rules unchanged.
hba_file="$(runuser -u postgres -- psql -XAtqc 'SHOW hba_file')"
python3 - "$hba_file" <<'PY'
import os
from pathlib import Path
import shutil
import sys
import tempfile

path = Path(sys.argv[1])
marker = '# Vox website authentication\n'
content = path.read_text()
if marker not in content:
    backup = path.with_name(path.name + '.before-vox')
    if not backup.exists():
        shutil.copy2(path, backup)
    rules = (marker +
             'host vox vox 127.0.0.1/32 scram-sha-256\n' +
             'host vox vox ::1/128 scram-sha-256\n' +
             '# End Vox website authentication\n\n')
    stat = path.stat()
    fd, temporary = tempfile.mkstemp(prefix='.vox-hba-', dir=path.parent)
    try:
        os.fchown(fd, stat.st_uid, stat.st_gid)
        os.fchmod(fd, stat.st_mode & 0o777)
        with os.fdopen(fd, 'w') as output:
            output.write(rules + content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
PY
runuser -u postgres -- psql -XAtqc 'SELECT COUNT(*) FROM pg_hba_file_rules WHERE error IS NOT NULL' | grep -qx 0
runuser -u postgres -- psql -XAtqc 'SELECT pg_reload_conf()' | grep -qx t

install -d -m 0755 "$site_root/acme/.well-known/acme-challenge"
previous_release=''
if [[ -L "$site_root/current" && -d "$site_root/current" ]]; then
    previous_release="$(readlink -f "$site_root/current")"
fi
if [[ -z "$previous_release" ]] && ss -ltnH '( sport = :8098 )' | grep -q .; then
    echo 'Port 8098 is already in use by another service.' >&2
    exit 1
fi
ln -sfn "$release_dir" "$site_root/current.next"
mv -Tf "$site_root/current.next" "$site_root/current"
install -m 0644 "$release_dir/deploy/vox-website.service" /etc/systemd/system/vox-website.service
systemctl daemon-reload
systemctl enable "$service"
systemctl restart "$service"
if ! timeout 25 bash -c 'until curl --fail --silent --head --max-time 2 http://127.0.0.1:8098/ >/dev/null && curl --fail --silent --max-time 2 http://127.0.0.1:8098/stats228 >/dev/null; do sleep 1; done'; then
    if [[ -n "$previous_release" ]]; then
        ln -sfn "$previous_release" "$site_root/current.next"
        mv -Tf "$site_root/current.next" "$site_root/current"
        systemctl restart "$service"
    else
        systemctl stop "$service"
    fi
    journalctl -u "$service" -n 25 --no-pager >&2
    exit 1
fi

nginx_config=/etc/nginx/sites-available/vox-browser.org
nginx_backup="$(mktemp)"
had_nginx_config=no
if [[ -f "$nginx_config" ]]; then
    cp "$nginx_config" "$nginx_backup"
    had_nginx_config=yes
else
    install -m 0644 "$release_dir/deploy/nginx-http.conf" "$nginx_config"
fi
ln -sfn "$nginx_config" /etc/nginx/sites-enabled/vox-browser.org

if [[ "$enable_https" == yes ]]; then
    # Bootstrap HTTP for ACME without changing any existing HTTPS configuration.
    nginx -t
    systemctl reload nginx
    certbot certonly --webroot -w "$site_root/acme" --cert-name vox-browser.org \
        -d vox-browser.org -d www.vox-browser.org --non-interactive --agree-tos
    install -m 0644 "$release_dir/deploy/nginx-https.conf" "$nginx_config"
elif [[ ! -f /etc/letsencrypt/live/vox-browser.org/fullchain.pem ]]; then
    install -m 0644 "$release_dir/deploy/nginx-http.conf" "$nginx_config"
else
    install -m 0644 "$release_dir/deploy/nginx-https.conf" "$nginx_config"
fi

if ! nginx -t; then
    if [[ "$had_nginx_config" == yes ]]; then
        cp "$nginx_backup" "$nginx_config"
    else
        rm -f /etc/nginx/sites-enabled/vox-browser.org "$nginx_config"
    fi
    rm -f "$nginx_backup"
    exit 1
fi
rm -f "$nginx_backup"
systemctl enable --now nginx
systemctl reload nginx
if [[ -f /etc/letsencrypt/live/vox-browser.org/fullchain.pem ]]; then
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    install -m 0755 "$release_dir/deploy/certbot-reload-nginx.sh" \
        /etc/letsencrypt/renewal-hooks/deploy/vox-website
    systemctl enable --now certbot.timer
fi
systemctl is-active --quiet "$service"
printf 'Deployed %s to %s\n' "$service" "$release_dir"
