# Vox browser website

The Vox browser website restored from the [January 4, 2024 Wayback capture](https://web.archive.org/web/20240104201201/https://vox.sx/), served by **V + veb** at `vox-browser.org`. The original copy, download links, section order, colors and main browser screenshot are retained. This is a historical restoration: the benchmark claims, release links and roadmap describe that capture.

`GET /` serves the page. `GET /stats228` renders the dashboard from the existing [`~/code/traffic`](../traffic) module, with visits isolated under the `vox` site ID. `POST /stats228` handles its authenticated day notes. Static files are served under `/assets/`; source and archive files are not exposed.

## Run

Requirements: V, the `~/code/traffic` checkout, and PostgreSQL client development libraries (`brew install libpq` on macOS or `libpq-dev` on Debian/Ubuntu). Install the shared module's bot classifier once:

```sh
v install medvednikov.botdetect
make run
```

Open <http://127.0.0.1:8080>. Without `VOX_DB_CONNINFO`, the server starts in preview mode: the homepage works, no visits are recorded, and `/stats228` responds with HTTP 503 and a configuration message.

To enable collection and the dashboard, point the server at a persistent PostgreSQL database:

```sh
export VOX_DB_CONNINFO='host=127.0.0.1 port=5432 dbname=vox user=vox connect_timeout=5'
make run
```

The traffic module creates its tables and indexes at startup; the database role needs permission to do so. A configured but unreachable database fails startup instead of silently disabling collection. Database errors after startup are logged without preventing homepage delivery. `PGTZ` is set to UTC so the dashboard's days and hours match its labels.

| Variable | Default | Purpose |
| --- | --- | --- |
| `VOX_DB_CONNINFO` | empty | libpq connection string; enables traffic storage |
| `VOX_STATS_NOTES_KEY` | empty | Secret for editing day notes; empty means read-only |
| `VOX_SECURE_COOKIES` | `0` | Set to `1` when serving over HTTPS |
| `HOST` | `127.0.0.1` | Listener address |
| `PORT` | `8080` | Listener port, 1–65535 |
| `VOX_ASSETS_DIR` | `assets` | Asset directory relative to the working directory, or an absolute path |

Set `TRAFFIC_MODULE_DIR` when the traffic checkout is elsewhere, for example `make build TRAFFIC_MODULE_DIR=/srv/code/traffic`. V must be able to import that directory as `traffic`. `V` and `VFLAGS` may also be overridden.

## Traffic behavior

Human homepage visits are counted once per browser session with an HttpOnly, SameSite=Lax session cookie. The cookie contains only `1`; no visitor identifier is stored. A cookie is set only after a successful insert. Bots are classified by the shared module and counted on every request, separately from human totals. HEAD requests, assets, missing routes and dashboard requests do not add visits. The homepage and stats responses use `Cache-Control: no-store`.

The module records timestamps, normalized referrer host and URL, user agent, country code and bot classification. It does not accept or store IP addresses. Country reporting uses `CF-IPCountry`; configure a trusted proxy to supply or sanitize that header if country accuracy matters. The dashboard preserves its `day=YYYY-MM-DD` and `days=7|30` filters. Notes stay read-only until `VOX_STATS_NOTES_KEY` is set, and saving an empty note deletes it.

## Production

```sh
make build
VOX_SECURE_COOKIES=1 ./bin/vox-website
```

Run from this directory, or set `VOX_ASSETS_DIR` to the deployed asset directory. The homepage and shared dashboard templates are embedded in the binary; ship `assets/` alongside it. Keep the database on persistent storage and supply credentials and the optional notes key through the service environment, outside Git.

Terminate HTTPS at the reverse proxy and forward requests, including `/stats228`, to the configured loopback port. Preserve `Host`, `Referer`, `User-Agent` and the trusted country header. Disable proxy/CDN caching for `/` and `/stats228`; static assets may be cached. Set `VOX_SECURE_COOKIES=1` in production.

## Deploy to vpm

```sh
./deploy.sh --dry-run
./deploy.sh
# After both DNS names resolve to vpm:
./deploy.sh --https
```

The script cross-compiles a Linux x86-64 production binary locally and uploads only the binary, assets and deployment configuration to a new release directory on `vpm` (`DEPLOY_HOST` overrides that SSH alias). It does not compile on the shared 2 GiB server. `--dry-run` checks SSH and builds locally without changing the server.

The Linux target uses V's compatibility C backend (`CROSS_VFLAGS=-old-compiler`). The script imports the target server's public `libpq.so.5` for linking, so the deployed binary uses Debian's managed PostgreSQL client library. This avoids the incomplete `libpgport` stubs in V's bundled cross-compilation sysroot, which produced malformed SCRAM proofs. Install `libpq5` on the target before deployment. To build without SSH, set `LINUX_LIBPQ` to a compatible Linux library. Compiler/link commands and library/binary hashes are recorded in `build/linux-build.json`.

The mbedTLS build uses portable integer division to avoid an unresolved cross-linker runtime symbol. Password authentication and TLS support remain enabled. The build helper reuses the linker command printed by V, replacing the static PostgreSQL library and its stubs with the actual target library, and fails if it cannot find that command.

Provisioning uses the existing Nginx and PostgreSQL installations, installing missing packages on Debian when necessary. It creates a dedicated `vox` system user, PostgreSQL role and database, then runs [`vox-website.service`](deploy/vox-website.service) on `127.0.0.1:8098`. Database access uses a generated password over loopback TCP, with SCRAM authentication rules scoped to the `vox` database and role; PostgreSQL stays private. The service runs without root privileges and has a 256 MiB memory limit.

The database password and generated day-notes key are stored only on the server in `/etc/vox-website.env` (root-owned, group `vox`, mode `0640`). Later deployments preserve them. Authorized administrators can retrieve the notes key from that file; it is not included in the uploaded release or Git.

Releases live under `/var/www/vox-browser.org/releases/`; `current` points to the active release. Startup checks verify both the homepage and statistics endpoint before Nginx is reloaded. A failed application startup restores the previous release when one exists. Nginx configuration is validated before reload, and existing sites are retained. Nginx serves assets directly, preserving complete image responses.

The initial Nginx configuration accepts HTTP so DNS and ACME validation can be completed. `--https` requests a Let's Encrypt certificate for `vox-browser.org` and `www.vox-browser.org`, installs the HTTPS configuration, redirects HTTP and `www` to `https://vox-browser.org`, and leaves the ACME webroot accessible for renewals. It reuses the server's Certbot account. Existing HTTPS deployments remain on HTTPS when deploying without the flag. Provisioning enables the Certbot renewal timer and installs a hook that validates and reloads Nginx after this domain's certificate renews.

Cloudflare DNS should contain:

| Type | Name | Target |
| --- | --- | --- |
| A | `@` | `193.168.144.108` |
| CNAME | `www` | `vox-browser.org` |

Use the nameserver pair assigned to this zone by Cloudflare in Dynadot's domain-specific nameserver settings. Keep the records DNS-only during initial origin certificate issuance, then enable proxying and set Cloudflare SSL/TLS mode to **Full (strict)**. Preserve `Cache-Control: no-store` for `/` and `/stats228`; do not add a cache-everything rule for those paths. Registrar and Cloudflare account changes are performed separately from the deployment script.

## Verification

```sh
make check
make test
make smoke
```

`make check` verifies formatting and type checks the app. The V tests exercise preview routing and source-file isolation. `make smoke` builds the production binary, starts a temporary PostgreSQL cluster and the actual HTTP server, then checks page/assets, deduplication, bots, referrers, countries, per-site isolation, dashboard filters, note authorization and escaping, concurrent queries and homepage availability during a database outage. It requires PostgreSQL server tools (`initdb`, `pg_ctl`, `psql`) and cleans up its processes and temporary cluster. It does not use an existing database.

## Archive provenance

[`archive/sources.json`](archive/sources.json) records replay URLs and SHA-256 hashes of the recovered files. The unmodified homepage and stylesheet are retained in `archive/`. The stylesheet and screenshot were captured in November 2023 and replayed with the January 2024 homepage.

Restoration repairs:

- Local asset URLs, a small replacement favicon, descriptive screenshot alt text and corrected social metadata.
- Removed Google Analytics and inactive search/navigation markup copied from another site.
- Removed eleven feature illustration references that return 404 from Wayback; their text remains. No substitute artwork was invented.
- Removed unused external font imports; the archived page already uses system-font fallbacks.
- Repaired the alpha badge and screenshot overflow, made the screenshot visible on narrow screens, and added keyboard focus outlines.

The archived “Something more” placeholders and dated roadmap copy are preserved as originally published.

The homepage screenshot `assets/screen1.png` is a current capture of Vox rendering news.ycombinator.com (the full macOS Vox window with rounded corners and shadow, 1252x1120, captured with the browser's `--screenshot` window mode from `~/code/vox2`). It appears in the "Runs on Vox" section; the hero image is `assets/hero-chatgpt.png` (Vox rendering chatgpt.com). `GET /version?os=<OS version>&vox=<installed Vox version>` returns the plain version string `0.1.0` for auto-updates and, when `VOX_DB_CONNINFO` is set, inserts a row (`checked_at`, `os_version`, `vox_version`) into the `version_checks` table for every hit. The original 2023 screenshot is kept at `archive/screen1-20231122.png`.
