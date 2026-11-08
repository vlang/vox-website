module main

import db.pg
import x.json2
import net.http
import os
import strconv
import sync
import time
import traffic
import veb

const home_html = $embed_file('index.html').to_string()
const visit_cookie_name = 'vox_session_visit'
const vox_version = '0.1.0'
const releases_url = 'https://github.com/vox-browser/vox/releases'
const releases_api_url = 'https://api.github.com/repos/vox-browser/vox/releases'
const download_size_marker = '<!--dmg-size-->'
const download_size_retry = 10 * time.minute

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
	download_size &DownloadSize = unsafe { nil }
}

struct ReleaseAsset {
	name string
	size i64
}

struct Release {
	assets []ReleaseAsset
}

// DownloadSize caches the published DMG's size. It is looked up once per
// release in the background, so page requests never wait for GitHub.
struct DownloadSize {
mut:
	lock      sync.Mutex
	version   string
	bytes     i64
	pending   bool
	looked_up time.Time
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
		download_size:    &DownloadSize{}
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
	return ctx.html(home_html.replace(download_size_marker, app.download_size_label()))
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

// The download button follows the release that /version announces. vox2's
// deploy.vsh uploads Vox-<version>-arm64.dmg before it publishes the version.
@['/download/macos'; get; head]
pub fn (mut app App) download_macos(mut ctx Context) veb.Result {
	ctx.set_header(.cache_control, 'no-store')
	if version := app.release_file_version() {
		return ctx.redirect('${releases_url}/download/${version}/${dmg_name(version)}',
			typ: .found
		)
	}
	// Without a published version, the latest release page lists its downloads.
	return ctx.redirect('${releases_url}/latest', typ: .found)
}

fn dmg_name(version string) string {
	return 'Vox-${version}-arm64.dmg'
}

// The download button shows the published DMG's size once it is known.
fn (mut app App) download_size_label() string {
	version := app.release_file_version() or { return '' }
	bytes := app.download_size.get(version)
	if bytes <= 0 {
		return ''
	}
	return '<span class="download-button__size">${format_download_size(bytes)}</span>'
}

fn format_download_size(bytes i64) string {
	return '${f64(bytes) / 1_000_000:.0f} MB'
}

// get returns the known size of version's DMG, or 0 while it is being looked up.
// A failed lookup is retried after download_size_retry.
fn (mut size DownloadSize) get(version string) i64 {
	size.lock.lock()
	defer {
		size.lock.unlock()
	}
	if size.version == version && size.bytes > 0 {
		return size.bytes
	}
	if !size.pending && (size.version != version || time.since(size.looked_up) > download_size_retry) {
		size.version = version
		size.bytes = 0
		size.pending = true
		size.looked_up = time.now()
		spawn size.look_up(version)
	}
	return 0
}

fn (mut size DownloadSize) look_up(version string) {
	bytes := release_dmg_size(version) or {
		eprintln('Could not look up the size of the Vox ${version} DMG: ${err}')
		i64(0)
	}
	size.lock.lock()
	if size.version == version {
		size.bytes = bytes
	}
	size.pending = false
	size.lock.unlock()
}

fn release_dmg_size(version string) !i64 {
	response := http.fetch(
		url:    '${releases_api_url}/tags/${version}'
		header: http.new_header(key: .user_agent, value: 'vox-website')
	)!
	if response.status_code != 200 {
		return error('GitHub returned HTTP ${response.status_code}')
	}
	release := json2.decode[Release](response.body)!
	name := dmg_name(version)
	for asset in release.assets {
		if asset.name == name && asset.size > 0 {
			return asset.size
		}
	}
	return error('the release has no ${name}')
}

// Without a valid version file, /version serves vox_version.
fn (app &App) published_version() string {
	return app.release_file_version() or { vox_version }
}

// vox2's deploy.vsh replaces the version file after uploading each release, so
// a release needs no website deploy.
fn (app &App) release_file_version() ?string {
	if app.version_file == '' {
		return none
	}
	version := (os.read_file(app.version_file) or { return none }).trim_space()
	return if is_release_version(version) { version } else { none }
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
