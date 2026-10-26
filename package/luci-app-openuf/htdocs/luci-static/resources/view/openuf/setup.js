'use strict';
'require view';
'require rpc';
'require uci';
'require ui';
'require poll';
'require dom';
'require openuf.common as common';

// Setup: everything a router needs before openUF can run on it, in the order
// setup.sh asks it -- which board this is, the software openUF needs, where
// the controller is, region and WiFi, access-point mode, adoption. Every step
// reads the daemon's own answer (`openuf probe` through luci.openuf), so a
// step says "done" only when the device agrees. The values it edits are the
// same openuf.main options the Settings page edits; one Save & Apply writes
// them and restarts openUF.

const callStatus = rpc.declare({
	object: 'luci.openuf',
	method: 'getStatus'
});

const callPresets = rpc.declare({
	object: 'luci.openuf',
	method: 'listPresets'
});

const callConvertState = rpc.declare({
	object: 'luci.openuf',
	method: 'getConvertState'
});

const arr = common.arr;

function badge(kind, text) {
	const cls = { done: 'success', todo: 'danger', wait: 'warning', optional: 'notice' }[kind] || '';
	return E('span', { 'class': 'label ' + cls }, text);
}

function step(n, title, state, intro, body) {
	return E('div', { 'class': 'cbi-section', 'id': 'openuf-setup-step' + n }, [
		E('h3', {}, [ '%d. %s '.format(n, title), state ]),
		intro ? E('p', { 'class': 'cbi-section-descr' }, intro) : '',
		body || ''
	]);
}

function field(label, control, help) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, label),
		E('div', { 'class': 'cbi-value-field' }, [
			control,
			help ? E('div', { 'class': 'cbi-value-description' }, help) : ''
		])
	]);
}

function checkbox(checked) {
	return E('input', { 'type': 'checkbox', 'checked': checked ? '' : null });
}

// Steps 3 and 6 follow the daemon live: whether the controller answers, and
// whether it adopted the device.
function controllerState(s) {
	const h = s.health || {}, now = s.now || Math.floor(Date.now() / 1000);
	if (!s.service || !s.service.running)
		return badge('todo', _('openUF is not running'));
	if (h.last_ok && now - h.last_ok < 120)
		return badge('done', _('the controller answers'));
	if (h.last_fail_msg && /404/.test(h.last_fail_msg))
		return badge('wait', _('reached: waiting to be adopted'));
	return badge('wait', h.last_fail_msg ? _('not reached yet: %s').format(h.last_fail_msg) : _('not reached yet'));
}

function adoptionState(s) {
	return (s.state && s.state.adopted) ? badge('done', _('adopted')) : badge('wait', _('not adopted yet'));
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callStatus(), {}),
			L.resolveDefault(callPresets(), {}),
			L.resolveDefault(callConvertState(), { state: 'unknown' }),
			L.resolveDefault(uci.load('openuf'), null)
		]);
	},

	render: function(data) {
		const status = data[0] || {}, presets = data[1] || {}, convertState = data[2] || { state: 'unknown' };
		const hasFile = (data[3] != null);
		if (hasFile && !uci.get('openuf', 'main'))
			common.seedFromStatus(status);
		const adopted = !!(status.state && status.state.adopted);
		const get = function(k, dflt) {
			const v = uci.get('openuf', 'main', k);
			return (v == null || v === '') ? dflt : v;
		};

		// ── 1. this device ──
		const mm = status.modelmap || {};
		const profile = E('select', { 'class': 'cbi-input-select', 'disabled': adopted ? '' : null });
		profile.appendChild(E('option', { 'value': 'auto' }, presets.auto
			? _('Automatic (this board: %s)').format(presets.auto) : _('Automatic (no shipped profile matches this board)')));
		for (const p of arr(presets.modelmaps))
			profile.appendChild(E('option', { 'value': p.name }, p.title || p.name));
		profile.appendChild(E('option', { 'value': 'custom' }, _('Custom profile (made on the Settings page)')));
		profile.value = get('modelmap', 'auto');
		const profileOk = (profile.value == 'auto') ? !!presets.auto : true;
		const s1 = step(1, _('This device'),
			status.config_error ? badge('todo', _('the configuration does not load'))
				: (profileOk ? badge('done', mm.title || mm.name || _('profile chosen')) : badge('todo', _('choose a profile'))),
			_('openUF needs to know the board: its Ethernet sockets, its radios and its status LED. "Automatic" picks the profile shipped for this board. A board with no shipped profile can be described on the Settings page ("Custom profile"), which starts from what the board reports about itself.'),
			E('div', {}, [
				status.config_error ? E('div', { 'class': 'alert-message error' }, status.config_error) : '',
				field(_('Board'), E('strong', {}, status.board || _('unknown'))),
				field(_('Hardware profile'), profile, adopted
					? _('Locked while the device is adopted: changing it would change the address the controller knows the device by.')
					: _('Supported boards: %s.').format(arr(presets.modelmaps).map(p => p.title || p.name).join(', ')))
			]));

		// ── 2. software ──
		const d = status.deps || {}, w = d.wpad || {}, missing = arr(d.missing);
		const depsKnown = (w.full === true || w.full === false);
		const s2body = [];
		if (!depsKnown)
			s2body.push(E('p', {}, d.error || _('Could not be determined: `openuf deps --check` did not answer.')));
		else {
			s2body.push(field(_('hostapd build'), w.full ? badge('done', w.installed || _('full')) : badge('todo', _('%s: basic, openUF will not start').format(w.installed || 'wpad-basic'))));
			s2body.push(field(_('Missing packages'), missing.length ? E('span', {}, missing.join(', ')) : badge('done', _('none'))));
			if (w.full === false || missing.length)
				s2body.push(common.installButton(w, missing));
		}
		const s2 = step(2, _('Software openUF needs'),
			d.ok ? badge('done', _('everything installed')) : (depsKnown ? badge('todo', _('something to install')) : badge('wait', _('unknown'))),
			_('Every controller WiFi network needs 802.11v, which only a full hostapd build has; a few features need kernel modules a stock image lacks. The button installs what is missing from the OpenWrt repository, so the device needs internet access. Do it over a cable: the radios restart.'),
			E('div', {}, s2body));

		// ── 3. controller ──
		const st = status.state || {};
		const current = st.inform_url || get('inform_url', '');
		const ctl = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': current, 'placeholder': '192.168.1.10:8080', 'style': 'width:100%' });
		const preview = E('div', { 'class': 'cbi-value-description' });
		const showPreview = function() {
			const u = common.informUrl(ctl.value);
			preview.textContent = (u === null) ? _('Not an address: write an IP address or name, with :port if the controller does not use 8080, or a full http:// URL.')
				: (u === '' ? _('Empty: rely on discovery on the local network.') : _('openUF will send its heartbeats to %s').format(u));
		};
		ctl.addEventListener('input', showPreview);
		showPreview();
		const l2 = checkbox(get('l2_announce', '1') == '1');
		const s3 = step(3, _('Controller'),
			E('span', { 'id': 'openuf-setup-ctl' }, controllerState(status)),
			_('Where the UniFi Network Application runs. A controller on the same network finds the device by itself; give its address when it is on another network or listens on another port. In the controller, set Settings → System → Advanced → Inform Host to its own LAN address, or an adopted device is told to report to an address it cannot reach.'),
			E('div', {}, [
				field(_('Controller address'), E('div', {}, [ ctl, preview ])),
				field(_('Announce the device on the local network'), l2,
					_('Lets a controller on the same network list the device for adoption by itself (UDP port 10001).')),
				adopted ? E('p', {}, _('Adopted: the controller now tells the device where to report, and its address wins over this one.')) : ''
			]));

		// ── 4. region and WiFi ──
		const cc = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': get('country_override', ''), 'placeholder': _('for example IN'), 'maxlength': 2, 'style': 'width:6em' });
		const exclusive = checkbox(get('use_only_unifi_wlan', '1') == '1');
		const s4 = step(4, _('Region and WiFi'), badge('optional', _('optional')),
			_('The country comes from the controller\'s site setting, and so does the time zone: set both there (Settings → System). Override the country here only when this board needs a different regulatory domain than the site.'),
			E('div', {}, [
				field(_('Country code override'), cc, _('Two letters. Empty: follow the controller.')),
				field(_('Broadcast only the controller\'s WiFi networks'), exclusive,
					_('Hand-made OpenWrt WiFi networks go off the air while the controller manages the radios; unticking brings them back.'))
			]));

		// ── 5. access-point mode ──
		let s5state, s5body;
		if (convertState.state == 'ap') {
			s5state = badge('done', _('access point'));
			s5body = E('p', {}, _('This device does not route: no WAN interface, no DHCP server, no firewall.'));
		}
		else if (convertState.state == 'router') {
			s5state = badge('todo', _('still a router'));
			s5body = E('div', {}, [
				E('p', {}, _('Still set up as a router: %s.').format(arr(convertState.reasons).join('; '))),
				E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': function() { common.showConvertModal(); } },
					_('Convert to an access point and reboot'))
			]);
		}
		else {
			s5state = badge('wait', _('unknown'));
			s5body = E('p', {}, _('`openuf-convert --check` did not answer.'));
		}
		const s5 = step(5, _('Access-point mode'), s5state,
			_('An access point should not route, serve DHCP or run a firewall, and its WAN socket should be an ordinary LAN socket; otherwise the network has two routers. Do this last: the device reboots and most likely comes back on a different address.'),
			s5body);

		// ── 6. adoption ──
		const s6 = step(6, _('Adoption'), E('span', { 'id': 'openuf-setup-adopt' }, adoptionState(status)),
			_('In the controller, open UniFi Devices: this device appears as a pending access point. Click Adopt. A controller on another network needs the address in step 3 first.'),
			E('div', { 'id': 'openuf-setup-adopt-detail' }, ''));

		const warn = hasFile ? '' : E('div', { 'class': 'alert-message warning' },
			_('This device has no /etc/config/openuf file, so these settings cannot be saved. Create it once with `touch /etc/config/openuf` and reload this page.'));

		this.inputs = { profile: profile, ctl: ctl, l2: l2, cc: cc, exclusive: exclusive, adopted: adopted, hasFile: hasFile };

		poll.add(function() {
			return callStatus().then(function(s) {
				const a = document.getElementById('openuf-setup-ctl');
				const b = document.getElementById('openuf-setup-adopt');
				if (a) dom.content(a, controllerState(s));
				if (b) dom.content(b, adoptionState(s));
			});
		}, 10);

		return E('div', {}, [
			E('h2', {}, _('openUF setup')),
			E('p', { 'class': 'cbi-section-descr' }, _('What this router needs before a UniFi controller can adopt it, step by step. A step marked done is what the device itself reports. Save & Apply stores steps 1, 3 and 4 and restarts openUF.')),
			warn, s1, s2, s3, s4, s5, s6
		]);
	},

	handleSave: function(ev) {
		const i = this.inputs || {};
		if (!i.hasFile)
			return Promise.resolve();
		const url = common.informUrl(i.ctl.value);
		if (url === null) {
			ui.addNotification(null, E('p', _('The controller address is not valid: write an IP address or name, with :port if it is not 8080, or a full http:// URL.')), 'danger');
			return Promise.reject(new Error('invalid controller address'));
		}
		const cc = i.cc.value.trim().toUpperCase();
		if (cc != '' && !/^[A-Z]{2}$/.test(cc)) {
			ui.addNotification(null, E('p', _('The country code must be two letters, for example IN.')), 'danger');
			return Promise.reject(new Error('invalid country code'));
		}
		if (!i.adopted)
			uci.set('openuf', 'main', 'modelmap', i.profile.value);
		uci.set('openuf', 'main', 'inform_url', url);
		uci.set('openuf', 'main', 'l2_announce', i.l2.checked ? '1' : '0');
		uci.set('openuf', 'main', 'country_override', cc);
		uci.set('openuf', 'main', 'use_only_unifi_wlan', i.exclusive.checked ? '1' : '0');
		return uci.save();
	},

	handleReset: null
});
