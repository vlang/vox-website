#!/usr/bin/env python3
"""Exercise the real veb server and shared traffic module in a disposable database."""

import concurrent.futures
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parent.parent


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def postgres_binary(name):
    for candidate in [shutil.which(name), f"/opt/homebrew/opt/postgresql/bin/{name}"]:
        if candidate and Path(candidate).is_file():
            return candidate
    raise SystemExit(f"Missing {name}; install PostgreSQL and add its bin directory to PATH.")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def main():
    binaries = {name: postgres_binary(name) for name in ["initdb", "pg_ctl", "psql"]}
    binary = ROOT / "bin/vox-website"
    if not binary.is_file():
        raise SystemExit("Run make build first.")
    db_port, site_port = free_port(), free_port()
    with tempfile.TemporaryDirectory(prefix="vox-site-smoke-") as directory:
        work = Path(directory)
        data = work / "db"
        server = None
        database_started = False
        with (work / "postgres.log").open("w") as pg_log, (work / "site.log").open("w") as site_log:
            try:
                subprocess.run([binaries["initdb"], "-D", str(data), "-A", "trust", "-U", "vox_test",
                                "--no-locale", "-E", "UTF8"], check=True, stdout=pg_log, stderr=pg_log)
                subprocess.run([binaries["pg_ctl"], "-D", str(data), "-l", str(work / "database.log"),
                                "-o", f"-h 127.0.0.1 -p {db_port} -k {work}", "-w", "start"],
                               check=True, stdout=pg_log, stderr=pg_log)
                database_started = True
                conninfo = f"host=127.0.0.1 port={db_port} dbname=postgres user=vox_test connect_timeout=2"

                def sql(query):
                    return subprocess.check_output([binaries["psql"], conninfo, "-XAt", "-v",
                                                    "ON_ERROR_STOP=1", "-c", query], text=True).strip()

                environment = dict(os.environ, VOX_DB_CONNINFO=conninfo, VOX_STATS_NOTES_KEY="smoke-key",
                                   VOX_SECURE_COOKIES="1", HOST="127.0.0.1", PORT=str(site_port))
                server = subprocess.Popen([str(binary)], cwd=ROOT, env=environment,
                                          stdout=site_log, stderr=site_log)
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

                def request(path="/", method="GET", headers=None, form=None):
                    body = urllib.parse.urlencode(form).encode() if form is not None else None
                    req = urllib.request.Request(f"http://127.0.0.1:{site_port}{path}", data=body,
                                                 method=method, headers=headers or {})
                    try:
                        response = opener.open(req, timeout=15)
                    except urllib.error.HTTPError as error:
                        response = error
                    with response:
                        return response.status, response.headers, response.read()

                deadline = time.monotonic() + 20
                while True:
                    if server.poll() is not None:
                        raise RuntimeError("Website exited during startup")
                    try:
                        assert request(method="HEAD")[0] == 200
                        break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(0.1)

                assert sql("SELECT COUNT(*) FROM visits") == "0", "HEAD must not count"
                human = {"User-Agent": "Mozilla/5.0", "Referer": "https://www.example.org/story/",
                         "CF-IPCountry": "DE"}
                status, headers, body = request(headers=human)
                assert status == 200 and b"A completely new browser engine" in body
                cookie = headers["Set-Cookie"]
                for expected in ["vox_session_visit=1", "HttpOnly", "Secure", "SameSite=Lax", "Path=/"]:
                    assert expected.lower() in cookie.lower(), cookie
                assert "expires=" not in cookie.lower() and "max-age=" not in cookie.lower()
                assert headers["Cache-Control"] == "no-store"
                repeated = dict(human, Cookie="vox_session_visit=1")
                assert request(headers=repeated)[0] == 200
                assert sql("SELECT COUNT(*) FROM visits WHERE site='vox' AND NOT is_bot") == "1"
                assert sql("SELECT referral || '|' || referral_url || '|' || country FROM visits") == (
                    "example.org|example.org/story|DE")

                # Bots retain every event even if they send the human session cookie.
                bot = {"User-Agent": "Googlebot/2.1 (+http://www.google.com/bot.html)",
                       "Cookie": "vox_session_visit=1"}
                for _ in range(2):
                    _, bot_headers, _ = request(headers=bot)
                    assert "Set-Cookie" not in bot_headers
                assert sql("SELECT COUNT(*) FROM visits WHERE site='vox' AND is_bot") == "2"

                for _ in range(2):
                    status, _, body = request("/version?os=macOS%2015.1&vox=0.0.1")
                    assert status == 200 and json.loads(body) == {"version": "0.1"}
                assert sql("SELECT os_version || '|' || vox_version FROM version_checks") == (
                    "macOS 15.1|0.0.1\nmacOS 15.1|0.0.1")

                for path, mime in [("/assets/style.css", "text/css"),
                                   ("/assets/screen1.png", "image/png"),
                                   ("/assets/favicon.svg", "image/svg+xml")]:
                    status, asset_headers, content = request(path)
                    assert status == 200 and mime in asset_headers["Content-Type"] and content
                for path in ["/missing", "/archive/index-20240104.html", "/main.v", "/v.mod"]:
                    assert request(path)[0] == 404
                assert request("/", method="POST")[0] in (404, 405)
                assert sql("SELECT COUNT(*) FROM visits") == "3"

                # Confirm isolation when another website shares the same visits table.
                sql("INSERT INTO visits (site, visited_at, referral, referral_url, user_agent, country) "
                    "VALUES ('other-site', NOW(), 'other-site.example', '', 'Mozilla/5.0', 'FR')")
                day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
                status, stats_headers, stats = request(f"/stats228?day={day}&days=7")
                assert status == 200 and b"Vox traffic statistics" in stats
                assert b"example.org/story" in stats and b"other-site.example" not in stats
                assert stats_headers["Cache-Control"] == "no-store"
                assert b"/stats228" in stats and b"smoke-key" not in stats
                form = dict(day=day, note="Launch <test>", key="incorrect", days="7")
                assert request("/stats228", method="POST", form=form)[0] == 400
                assert sql("SELECT COUNT(*) FROM traffic_day_notes") == "0"
                form["key"] = "smoke-key"
                status, note_headers, _ = request("/stats228", method="POST", form=form)
                assert status == 303
                assert note_headers["Location"] == f"/stats228?day={day}&days=7#traffic-hourly"
                stats = request(f"/stats228?day={day}&days=7")[2]
                assert b"Launch &lt;test&gt;" in stats and b"Launch <test>" not in stats
                invalid = dict(form, day="invalid")
                assert request("/stats228", method="POST", form=invalid)[0] == 400
                form["note"] = ""
                assert request("/stats228", method="POST", form=form)[0] == 303
                assert sql("SELECT COUNT(*) FROM traffic_day_notes") == "0"

                # Concurrent dashboard reads and writes must not share an active pg query.
                with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                    responses = list(pool.map(lambda i: request("/" if i % 2 else "/stats228",
                                                               headers=human)[0], range(12)))
                assert responses == [200] * 12
                assert sql("SELECT COUNT(*) FROM visits WHERE site='vox' AND NOT is_bot") == "7"
                assert sql("SELECT COUNT(*) FROM visits WHERE site='other-site'") == "1"

                # A database outage must not make the restored site unavailable, nor set
                # a deduplication cookie for an event that was never stored.
                subprocess.run([binaries["pg_ctl"], "-D", str(data), "-m", "fast", "-w", "stop"],
                               check=True, stdout=pg_log, stderr=pg_log)
                database_started = False
                status, outage_headers, _ = request(headers=human)
                assert status == 200 and "Set-Cookie" not in outage_headers
                print(json.dumps({"passed": True, "checks": ["home and assets", "session deduplication",
                      "bot classification", "referrer and country", "site isolation", "stats dashboard",
                      "authenticated day notes", "concurrent requests", "database outage"]}))
            except BaseException:
                site_log.flush()
                pg_log.flush()
                print((work / "site.log").read_text())
                print((work / "postgres.log").read_text())
                raise
            finally:
                if server is not None:
                    server.terminate()
                    try:
                        server.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()
                if database_started:
                    subprocess.run([binaries["pg_ctl"], "-D", str(data), "-m", "fast", "-w", "stop"],
                                   stdout=pg_log, stderr=pg_log, check=True)


if __name__ == "__main__":
    main()
