module main

import net.http
import os
import veb

fn test_restored_home_and_preview_stats_routes() {
	mut app := new_app(Config{})!
	home := veb.render_request[App, Context](mut app, http.Request{ url: '/' })!
	assert home.res.status() == .ok
	assert home.res.body.contains('A completely new browser engine built from scratch')
	assert home.res.body.contains('/assets/hero-chatgpt.png?v=')
	assert home.res.body.contains('/assets/screen1.png?v=')
	assert !home.res.body.contains('googletagmanager')
	assert !home.res.body.contains('gtag(')
	assert home.res.header.get(.set_cookie) == none
	assert (home.res.header.get(.cache_control) or { '' }) == 'no-store'
	for method in [http.Method.get, .post] {
		stats := veb.render_request[App, Context](mut app, http.Request{
			method: method
			url:    '/stats228?day=2026-10-30&days=7'
		})!
		assert stats.res.status() == .service_unavailable
		assert stats.res.body.contains('VOX_DB_CONNINFO')
		assert (stats.res.header.get(.cache_control) or { '' }) == 'no-store'
	}
	missing := veb.render_request[App, Context](mut app, http.Request{ url: '/missing' })!
	assert missing.res.status() == .not_found
}

fn test_static_assets_are_served_without_exposing_source_archive() {
	mut app := new_app(Config{})!
	for asset in ['style.css', 'screen1.png', 'hero-chatgpt.png', 'favicon.svg'] {
		ctx := veb.render_request[App, Context](mut app, http.Request{
			url: '/assets/${asset}'
		})!
		assert ctx.res.status() == .ok
	}
	for path in ['/archive/index-20240104.html', '/main.v', '/v.mod'] {
		ctx := veb.render_request[App, Context](mut app, http.Request{ url: path })!
		assert ctx.res.status() == .not_found
	}
}

fn test_version_endpoint() {
	mut app := new_app(Config{})!
	ctx := veb.render_request[App, Context](mut app, http.Request{ url: '/version' })!
	assert ctx.res.status() == .ok
	assert ctx.res.body == '0.1.0'
	assert (ctx.res.header.get(.cache_control) or { '' }) == 'no-store'
}

fn test_version_endpoint_serves_the_published_release_file() {
	path := os.join_path(os.vtmp_dir(), 'vox-website-version-${os.getpid()}')
	defer {
		os.rm(path) or {}
	}
	mut app := new_app(Config{
		version_file: path
	})!
	for content, expected in {
		'0.1.1\n':    '0.1.1'
		'0.2.0':      '0.2.0'
		'':           '0.1.0'
		'<script>\n': '0.1.0'
		'1.2.3.4':    '0.1.0'
		'0..1':       '0.1.0'
	} {
		os.write_file(path, content)!
		ctx := veb.render_request[App, Context](mut app, http.Request{ url: '/version' })!
		assert ctx.res.body == expected
	}
	os.rm(path)!
	ctx := veb.render_request[App, Context](mut app, http.Request{ url: '/version' })!
	assert ctx.res.body == '0.1.0'
}

fn test_port_validation() {
	assert listen_port('8080')! == 8080
	for value in ['', 'invalid', '0', '-1', '65536'] {
		if port := listen_port(value) {
			assert false, 'Unexpectedly accepted port ${port}'
		}
	}
}
