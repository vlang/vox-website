#!/usr/bin/env bash
set -euo pipefail

site_dir="$(cd "$(dirname "$0")" && pwd)"
deploy_host="${DEPLOY_HOST:-vpm}"
dry_run=no
enable_https=no
for option in "$@"; do
    case "$option" in
        --dry-run) dry_run=yes ;;
        --https) enable_https=yes ;;
        *) echo "Usage: $0 [--dry-run] [--https]" >&2; exit 1 ;;
    esac
done
[[ "$deploy_host" =~ ^[A-Za-z0-9_@.-]+$ && "$deploy_host" != -* ]] || {
    echo 'DEPLOY_HOST must be an SSH host or user@host.' >&2
    exit 1
}
ssh_options=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
ssh "${ssh_options[@]}" "$deploy_host" 'test "$(id -u)" = 0 && command -v systemctl >/dev/null && command -v rsync >/dev/null'
mkdir -p "$site_dir/build"
# Import only the public runtime library, never the server's credentials. Its
# SONAME makes the deployed binary use the server's managed libpq package.
ssh "${ssh_options[@]}" "$deploy_host" 'test -r /usr/lib/x86_64-linux-gnu/libpq.so.5' || {
    echo 'Install libpq5 on the target server before building this release.' >&2
    exit 1
}
scp -q "${ssh_options[@]}" "$deploy_host:/usr/lib/x86_64-linux-gnu/libpq.so.5" "$site_dir/build/libpq.so.5"
make -C "$site_dir" build-linux
release_hash="$(shasum -a 256 "$site_dir/bin/vox-website-linux-amd64" | cut -c1-12)"
release_id="$(date -u +%Y%m%dT%H%M%SZ)-$release_hash"
release_dir="/var/www/vox-browser.org/releases/$release_id"
if [[ "$dry_run" == yes ]]; then
    printf 'Would upload Linux release and assets to %s:%s\n' "$deploy_host" "$release_dir"
    printf 'Would provision dedicated vox user/database, service, and Nginx; HTTPS=%s\n' "$enable_https"
    exit 0
fi
ssh "${ssh_options[@]}" "$deploy_host" "install -d -m 0755 '$release_dir/assets' '$release_dir/deploy'"
transport='ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3'
rsync -az --timeout=60 -e "$transport" "$site_dir/bin/vox-website-linux-amd64" "$deploy_host:$release_dir/vox-website"
rsync -az --timeout=60 -e "$transport" "$site_dir/assets/" "$deploy_host:$release_dir/assets/"
rsync -az --timeout=60 -e "$transport" "$site_dir/deploy/" "$deploy_host:$release_dir/deploy/"
ssh "${ssh_options[@]}" "$deploy_host" "bash '$release_dir/deploy/provision.sh' '$release_dir' '$enable_https'"
