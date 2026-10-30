#!/bin/sh
set -eu

# Certbot runs directory hooks for every renewed certificate on this server.
# Reload Nginx only when the Vox certificate has been renewed successfully.
if [ "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/vox-browser.org ]; then
    /usr/sbin/nginx -t
    /bin/systemctl reload nginx
fi
