module main

import db.pg
import net.http
import os
import strconv
import sync
import traffic
import veb

const home_html = $embed_file('index.html').to_string()
const visit_cookie_name = 'vox_session_visit'
const vox_version = '0.1.0'

pub struct Context {
	veb.Context
}

pub struct App {
	veb.StaticHandler
	tracking_enabled bool
	secure_cookies   bool
	version_file     string
mut:
	tracker       &traffic.Tracker = unsafe { nil }
	stats_tracker &traffic.Tracker = unsafe { nil }
	visit_lock    sync.Mutex
	stats_lock    sync.Mutex
	version_lock  sync.Mutex
	version_db    pg.DB
}

struct Config {
	conninfo       string
	notes_key      string
	assets_dir     string = 'assets'
	secure_cookies bool
	version_file   string
}

fn new_app(config Config) !&App {
	mut app := &App{
		tracking_enabled: config.conninfo != ''
		secure_cookies:   config.secure_cookies
		version_file:     config.version_file
	}
	app.mount_static_folder_at(config.assets_dir, '/assets')!
	if app.tracking_enabled {
		// Recording and dashboard queries use separate connections. Each connection
		// has its own lock because veb dispatches requests concurrently.
		app.tracker = traffic.new(traffic.Config{
			conninfo: config.conninfo
			site_id:  'vox'
		})!
		app.stats_tracker = traffic.new(traffic.Config{
			conninfo:  config.conninfo
			site_id:   'vox'
			notes_key: config.notes_key
		})!
		mut db := pg.connect_with_conninfo(config.conninfo, pg.PoolConfig{})!
		db.exec('CREATE TABLE IF NOT EXISTS version_checks (id BIGSERIAL PRIMARY KEY, checked_at TIMESTAMPTZ NOT NULL DEFAULT now(), os_version TEXT NOT NULL, vox_version TEXT NOT NULL)')!
		app.version_db = *db
	}
	return app
}

@['/'; get; head]
pub fn (mut app App) index(mut ctx Context) veb.Result {
	// HEAD requests, assets and dashboard requests do not count as page visits.
	if app.tracking_enabled && ctx.req.method == .get {
		user_agent := ctx.req.header.get(.user_agent) or { '' }
		is_bot := traffic.is_bot_request(user_agent, ctx.req.url)
		visit_cookie := ctx.get_cookie(visit_cookie_name) or { '' }
		if is_bot || visit_cookie != '1' {
			if app.record_visit(ctx) && !is_bot {
				// A session cookie deduplicates human reloads without storing an ID.
				ctx.set_cookie(http.Cookie{
					name:      visit_cookie_name
					value:     '1'
					path:      '/'
					secure:    app.secure_cookies
					http_only: true
					same_site: .same_site_lax_mode
				})
			}
		}
	}
	// A shared cache must not bypass collection or replay another visitor's cookie.
	ctx.set_header(.cache_control, 'no-store')
	return ctx.html(home_html)
}

// Updaters report their state as /version?os=<OS version>&vox=<installed Vox version>.
@['/version'; get; head]
pub fn (mut app App) version(mut ctx Context) veb.Result {
	ctx.set_header(.cache_control, 'no-store')
	if app.tracking_enabled {
		os_version := clip_param(ctx.query['os'])
		installed := clip_param(ctx.query['vox'])
		if !app.record_version_check(os_version, installed) {
			ctx.res.set_status(.internal_server_error)
			return ctx.text('Could not record version check\n')
		}
	}
	return ctx.text(app.published_version())
}

// vox2's deploy.vsh replaces the version file after uploading each release, so
// a release needs no website deploy. Without a valid file, serve vox_version.
fn (app &App) published_version() string {
	if app.version_file == '' {
		return vox_version
	}
	version := (os.read_file(app.version_file) or { return vox_version }).trim_space()
	return if is_release_version(version) { version } else { vox_version }
}

// Match the browser's update check: one to three numeric components.
fn is_release_version(version string) bool {
	parts := version.split('.')
	if parts.len > 3 {
		return false
	}
	for part in parts {
		if part.len == 0 || part.len > 9 || !part.bytes().all(it.is_digit()) {
			return false
		}
	}
	return true
}

fn clip_param(value string) string {
	trimmed := value.trim_space()
	return if trimmed.len > 128 { trimmed[..128] } else { trimmed }
}

fn (mut app App) record_version_check(os_version string, installed string) bool {
	app.version_lock.lock()
	defer {
		app.version_lock.unlock()
	}
	app.version_db.exec_param_many('INSERT INTO version_checks (os_version, vox_version) VALUES ($1, $2)',
		[os_version, installed]) or {
		eprintln('Could not record Vox version check: ${err}')
		return false
	}
	return true
}

fn (mut app App) record_visit(ctx Context) bool {
	app.visit_lock.lock()
	defer {
		app.visit_lock.unlock()
	}
	app.tracker.record(traffic.Request{
		url:        ctx.req.url
		referer:    ctx.get_header(.referer) or { '' }
		user_agent: ctx.req.header.get(.user_agent) or { '' }
		country:    ctx.get_custom_header('CF-IPCountry') or { '' }
	}) or {
		eprintln('Could not record Vox visit: ${err}')
		return false
	}
	return true
}

@['/stats228'; get; head]
pub fn (mut app App) stats228(mut ctx Context) veb.Result {
	ctx.set_header(.cache_control, 'no-store')
	if !app.tracking_enabled {
		ctx.res.set_status(.service_unavailable)
		return ctx.text('Traffic statistics are unavailable. Configure VOX_DB_CONNINFO to enable them.\n')
	}
	app.stats_lock.lock()
	defer {
		app.stats_lock.unlock()
	}
	return ctx.html(app.stats_tracker.stats_html(ctx.req.url, traffic.PageConfig{
		site_name:  'Vox'
		page_title: 'Vox traffic statistics'
		home_url:   '/'
		stats_path: '/stats228'
	}))
}

@['/stats228'; post]
pub fn (mut app App) save_stats_note(mut ctx Context) veb.Result {
	ctx.set_header(.cache_control, 'no-store')
	if !app.tracking_enabled {
		ctx.res.set_status(.service_unavailable)
		return ctx.text('Traffic statistics are unavailable. Configure VOX_DB_CONNINFO to enable them.\n')
	}
	app.stats_lock.lock()
	defer {
		app.stats_lock.unlock()
	}
	day := ctx.form['day']
	app.stats_tracker.save_day_note(day, ctx.form['note'], ctx.form['key']) or {
		return ctx.request_error('Could not save the note: ${err}\n')
	}
	range_query := if ctx.form['days'] == '7' { '&days=7' } else { '' }
	return ctx.redirect('/stats228?day=${day}${range_query}#traffic-hourly', typ: .see_other)
}

fn listen_port(value string) !int {
	port := strconv.atoi(value)!
	if port < 1 || port > 65535 {
		return error('PORT must be between 1 and 65535')
	}
	return port
}

fn main() {
	// The dashboard labels its dates in UTC; libpq applies PGTZ to both sessions.
	os.setenv('PGTZ', 'UTC', true)
	port := listen_port(os.getenv_opt('PORT') or { '8080' }) or { panic(err) }
	mut app := new_app(Config{
		conninfo:       os.getenv('VOX_DB_CONNINFO')
		notes_key:      os.getenv('VOX_STATS_NOTES_KEY')
		assets_dir:     os.getenv_opt('VOX_ASSETS_DIR') or { 'assets' }
		secure_cookies: os.getenv('VOX_SECURE_COOKIES') == '1'
		version_file:   os.getenv('VOX_VERSION_FILE')
	}) or { panic('Could not initialize Vox website: ${err}') }
	if !app.tracking_enabled {
		eprintln('Preview mode: set VOX_DB_CONNINFO to enable visit collection and /stats228.')
	}
	veb.run_at[App, Context](mut app,
		host:   os.getenv_opt('HOST') or { '127.0.0.1' }
		port:   port
		family: .ip
	) or { panic(err) }
}
