{%
/*
 * openUF's gate in front of LuCI.
 *
 * uhttpd runs this file for every /cgi-bin/luci request in place of LuCI's
 * own /usr/share/ucode/luci/uhttpd.uc (the uci-defaults script swaps the
 * ucode_prefix entry, the package's prerm swaps it back). Like a Ubiquiti or
 * Omada device that has been adopted, an openUF AP belongs to its
 * controller, so the web interface opens on openUF's own page (/openuf/:
 * the device's state, "manage this device from <controller>", and a
 * password-protected local settings tab) instead of LuCI.
 *
 * LuCI itself is untouched and one step away: /cgi-bin/luci/__openuf/unlock
 * (what the portal's hidden "open LuCI" prompt navigates to) sets the
 * openuf_luci cookie, after which requests pass straight to LuCI's
 * dispatcher -- for as long as the LuCI login session behind them is valid,
 * plus GRACE seconds to log in. /cgi-bin/luci/__openuf/lock (LuCI's "Exit
 * LuCI mode" indicator) ends the LuCI session and returns to the portal; an
 * expired session does the same on the next page load.
 *
 * This is presentation, not access control. LuCI still asks for the root
 * password, and the rpcd/ubus endpoints LuCI's pages talk to are not behind
 * this file at all. Any error here hands the request to LuCI unchanged:
 * a bug in the gate must never lock anyone out of their router.
 */

import dispatch from 'luci.dispatcher';
import request from 'luci.http';
import { cursor } from 'uci';
import { connect } from 'ubus';
import { access } from 'fs';

const COOKIE = 'openuf_luci';
const GRACE  = 600;             // seconds to log in after unlocking
const PORTAL = '/openuf/';
const PORTAL_FILE = '/www/openuf/index.html';

// openuf.web.portal: absent or anything but an explicit off means on, so a
// fresh install locks without a configuration step. Its own section, not
// openuf.main: openUF's loader takes a `main` section as "UCI is in charge of
// the daemon", so creating one just to hold this switch would move a tarball
// install's identity.
function portal_enabled() {
	if (!access(PORTAL_FILE))
		return false;
	const v = cursor().get('openuf', 'web', 'portal');
	return !(v == '0' || v == 'false' || v == 'off' || v == 'no');
}

function sysauth_cookie_name(req) {
	return (req.getenv('HTTPS') == 'on') ? 'sysauth_https' : 'sysauth_http';
}

// The LuCI login session behind this request, if it is still valid.
function luci_session(req) {
	const sid = req.getcookie(sysauth_cookie_name(req));
	if (!sid || !match(sid, /^[0-9a-f]{32}$/))
		return null;
	const u = connect();
	const s = u ? u.call('session', 'get', { ubus_rpc_session: sid }) : null;
	return (type(s?.values) == 'object' && s.values.username) ? sid : null;
}

function set_cookie(req, value, max_age) {
	// Readable by script on purpose: the portal and LuCI's indicator read it
	// to know which mode the browser is in. It carries no secret.
	req.header('Set-Cookie', `${COOKIE}=${value}; Path=/; SameSite=Strict${max_age != null ? `; Max-Age=${max_age}` : ''}`);
}

function to_portal(req, why) {
	req.redirect(why ? `${PORTAL}?${why}` : PORTAL);
}

// Returns true when the request has been answered here.
function gate(req) {
	const path = req.getenv('PATH_INFO') ?? '';

	if (path == '/__openuf/unlock') {
		set_cookie(req, `${time()}`);
		req.redirect(req.getenv('SCRIPT_NAME') + '/');
		return true;
	}

	if (path == '/__openuf/lock') {
		const sid = luci_session(req);
		if (sid) {
			const u = connect();
			if (u) u.call('session', 'destroy', { ubus_rpc_session: sid });
		}
		// Two Set-Cookie lines do not fit req.header's one value per name;
		// the LuCI cookie is left to expire with its destroyed session.
		set_cookie(req, '', 0);
		to_portal(req, 'locked');
		return true;
	}

	if (!portal_enabled())
		return false;

	const issued = int(req.getcookie(COOKIE) ?? '');
	if (issued > 0) {
		if (luci_session(req) || (time() - issued) < GRACE)
			return false;           // in LuCI mode: let it through
		set_cookie(req, '', 0);     // the LuCI session is over
		to_portal(req, 'expired');
		return true;
	}

	to_portal(req);
	return true;
}

// uhttpd's ucode handler passes no DOCUMENT_ROOT (its CGI path does), and
// LuCI builds filesystem paths from it: L.env.documentroot comes out null,
// so LuCI asks rpcd to list "null/luci-static/resources/preload", is
// refused, and no preload script -- this package's "Exit LuCI mode"
// indicator, or any other app's -- ever loads. Supplied from uhttpd's own
// `home`, which is what the CGI path would have reported.
let docroot = null;
function document_root() {
	if (docroot == null) {
		const c = cursor();
		c.foreach('uhttpd', 'uhttpd', s => {
			if (docroot == null && s.home)
				docroot = s.home;
		});
		docroot ??= '/www';
	}
	return docroot;
}

global.handle_request = function(env) {
	if (type(env) == 'object' && !env.DOCUMENT_ROOT) {
		try { env.DOCUMENT_ROOT = document_root(); } catch (e) { }
	}

	let req = request(env, uhttpd.recv, uhttpd.send);
	let handled = false;

	try {
		handled = gate(req);
	}
	catch (e) {
		handled = false;
	}

	if (!handled)
		dispatch(req);

	req.close();
};
%}
