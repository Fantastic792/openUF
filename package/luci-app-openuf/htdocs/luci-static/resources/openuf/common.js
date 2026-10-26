'use strict';
'require baseclass';
'require rpc';
'require fs';
'require ui';
'require uci';

// What the Overview, Settings and Setup pages share: the dependency install,
// the conversion to an access point and the first save of a tarball install.
// One copy, so the three pages cannot drift apart on any of them.

const callConvert = rpc.declare({
	object: 'luci.openuf',
	method: 'convert',
	params: [ 'address', 'gateway', 'dns', 'keep_wan_socket' ]
});

// lua-cjson encodes an empty Lua table as {}, so an empty list from the
// probe arrives as an object, never an array. Every list goes through this.
function arr(v) {
	return Array.isArray(v) ? v : [];
}

return baseclass.extend({
	arr: arr,

	// A tarball install (setup.sh / install.sh) has no `main` section in
	// /etc/config/openuf. The first save creates it, and from then on it is
	// the configuration -- so it starts from what the daemon currently runs
	// with, read off the probe, and the first save changes nothing but the
	// source.
	seedFromStatus: function(status) {
		const mm = status.modelmap || {}, id = status.identity || {}, c = status.config || {};
		uci.add('openuf', 'openuf', 'main');
		uci.set('openuf', 'main', 'modelmap', mm.name || 'auto');
		uci.set('openuf', 'main', 'ufmodel', id.name || 'auto');
		const opts = [ 'inform_url', 'neighbour_scan_interval', 'rrm_request_interval', 'roam_assist_diff_db',
			'country_override', 'bootstrap_adopt_user', 'debug_dump_file', 'debug_dump_max_bytes',
			'uplink_monitor_host' ];
		for (const k of opts)
			if (c[k] != null && c[k] !== '')
				uci.set('openuf', 'main', k, String(c[k]));
		const flags = [ 'use_only_unifi_wlan', 'l2_announce', 'rrm_enrichment', 'debug_dump_requests',
			'uplink_monitor' ];
		for (const k of flags)
			if (c[k] != null)
				uci.set('openuf', 'main', k, c[k] ? '1' : '0');
		if (arr(c.keep_wlan_sections).length)
			uci.set('openuf', 'main', 'keep_wlan_section', c.keep_wlan_sections);
	},

	// What openUF needs installed. The package brings every dependency in
	// except the hostapd build: every wpad variant provides the same names, so
	// no dependency can say "a full one", and a wpad-basic-* build rejects the
	// 802.11v option every controller WLAN carries and takes the radio down.
	// openUF refuses to start until a full build is there; this button runs
	// `openuf deps --install`, which does the swap and installs whatever else
	// is missing, then reloads the page.
	installButton: function(w, missing) {
		const swap = (w.full === false);
		const choices = arr(w.choices);
		const select = E('select', { 'class': 'cbi-input-select' },
			choices.map(c => E('option', { 'value': c, 'selected': (c == w.suggested) ? '' : null }, c)));
		const label = swap
			? (missing.length ? _('Replace hostapd with the full build and install the missing packages') : _('Replace hostapd with the full build'))
			: (missing.length ? _('Install the missing packages') : _('Install the Halo theme'));
		const btn = E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': function() {
			const chosen = swap ? select.value : null;
			ui.showModal(label, [
				swap ? E('p', {}, _('%s is removed and %s installed. The radios are down for about ten seconds in between, then brought back up on the new build, and openUF is restarted. Do this over a cable, not over WiFi.').format(w.installed || _('the basic build'), chosen))
				     : E('p', {}, _('The packages are downloaded from the OpenWrt repository and installed, then openUF is restarted. The device needs internet access for this.')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
					E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, function() {
						const args = [ 'deps', '--install' ];
						if (chosen)
							args.push('--wpad', chosen.replace(/^(wpad|hostapd)-/, ''));
						ui.showModal(_('Installing'), [ E('p', { 'class': 'spinning' }, _('Downloading and installing. This takes a minute or two; the page reloads when it is done.')) ]);
						const close = E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': function() { window.location.reload(); } }, _('Close')));
						return fs.exec_direct('/usr/bin/openuf', args, 'text', false, true).then(function(out) {
							ui.showModal(label, [ E('pre', {}, out || _('(no output)')), close ]);
						}).catch(function(e) {
							ui.showModal(label, [ E('pre', {}, String(e.message || e)), close ]);
						});
					}) }, _('Go ahead'))
				])
			]);
		} }, label);
		return E('div', {}, swap ? [ E('label', {}, _('Full build to install: ')), ' ', select, ' ', btn ] : [ btn ]);
	},

	// The conversion to an access point (openuf-convert --convert through the
	// luci.openuf backend): the address choice, then a reboot.
	showConvertModal: function() {
		const mode = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'dhcp' }, _('Take an address from the network\'s DHCP server (recommended)')),
			E('option', { 'value': 'static' }, _('Use a fixed address'))
		]);
		const ip = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '192.168.1.20/24', 'style': 'width:100%' });
		const gw = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '192.168.1.1', 'style': 'width:100%' });
		const dns = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '192.168.1.1', 'style': 'width:100%' });
		const keep = E('input', { 'type': 'checkbox' });
		const staticBox = E('div', { 'style': 'display:none; margin:.5em 0' }, [
			E('label', {}, _('Address and prefix length')), ip,
			E('label', {}, _('Gateway')), gw,
			E('label', {}, _('DNS servers, space separated')), dns
		]);
		mode.addEventListener('change', function() { staticBox.style.display = (mode.value == 'static') ? '' : 'none'; });
		ui.showModal(_('Convert this device into an access point?'), [
			E('p', {}, _('This removes the WAN interfaces, joins the WAN socket to the LAN, switches off the DHCP server, the firewall and dnsmasq, enables every radio, and reboots. The device stops routing: everything on it will reach the network through the LAN sockets. A backup of the configuration is kept so this can be undone from the Overview page.')),
			E('p', {}, _('After the reboot the device will most likely have a different address. Find it in your router\'s DHCP client list or through the controller once it is adopted; this page will not reconnect on its own.')),
			E('div', { 'style': 'margin:.5em 0' }, [ E('label', {}, _('Management address')), mode ]),
			staticBox,
			E('div', { 'style': 'margin:.5em 0' }, [ E('label', {}, [ keep, ' ', _('Leave the WAN socket out of the LAN (keep it unused)') ]) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, function() {
					const address = (mode.value == 'static') ? ip.value.trim() : 'dhcp';
					if (mode.value == 'static' && !/^\d{1,3}(\.\d{1,3}){3}\/\d{1,2}$/.test(address)) {
						ui.addNotification(null, E('p', _('The fixed address must be written as address/prefix, for example 192.168.1.20/24.')), 'danger');
						return;
					}
					return callConvert(address, gw.value.trim(), dns.value.trim(), keep.checked).then(function(r) {
						if (r.code != 0) {
							ui.hideModal();
							ui.addNotification(null, E('pre', {}, _('The conversion was refused, nothing was changed:') + '\n' + (r.output || r.code)), 'danger');
							return;
						}
						ui.showModal(_('Rebooting'), [
							E('pre', {}, r.output || ''),
							E('p', { 'class': 'spinning' }, _('The device reboots now and comes back as an access point.'))
						]);
					});
				}) }, _('Convert and reboot'))
			])
		]);
	},

	// "192.168.1.2", "unifi.lan:8443" or a full URL -> the inform URL, the
	// way setup.sh's --controller reads it. null when it is none of those.
	informUrl: function(input) {
		const v = String(input || '').trim();
		if (v == '')
			return '';
		if (/^https?:\/\/[^\s/]+(\/\S*)?$/.test(v))
			return v;
		if (/^[A-Za-z0-9.-]+:\d{1,5}$/.test(v))
			return 'http://' + v + '/inform';
		if (/^[A-Za-z0-9.-]+$/.test(v))
			return 'http://' + v + ':8080/inform';
		return null;
	}
});
