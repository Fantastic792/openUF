'use strict';
'require view';
'require rpc';
'require fs';
'require network';
'require poll';
'require dom';

/*
 * The dashboard (admin/dashboard, the landing page): is this access point
 * healthy, and if not, where? One screen: a verdict with the checks behind
 * it, the path from the gateway through this device to its radios and
 * networks, live throughput, the radios, the clients, the system, and how
 * the device stands with its UniFi controller. Read-only; every figure comes
 * from LuCI's own network model and rpcd, polled every five seconds. Styled
 * through the theme's tokens with fallbacks (dashboard.css), so it also works
 * under Bootstrap.
 */

const callSystemInfo = rpc.declare({ object: 'system', method: 'info' });
const callSystemBoard = rpc.declare({ object: 'system', method: 'board' });
const callOpenufStatus = rpc.declare({ object: 'luci.openuf', method: 'getStatus' });

const SAMPLES = 60;      /* five minutes of five-second polls */
const WEAK_DBM = -75;    /* a client below this is flagged */

/* --------------------------------------------------------------- format */

function fmtRate(bps) {
	if (!(bps > 0)) return '0 bit/s';
	const units = [ 'bit/s', 'kbit/s', 'Mbit/s', 'Gbit/s' ];
	let i = 0, v = bps;
	while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
	return (i === 0 || v >= 100 ? Math.round(v) : v.toFixed(1)) + ' ' + units[i];
}

function fmtBytes(n) { return String.format('%1024.1mB', Math.max(0, n || 0)); }

function fmtDuration(secs) {
	const s = Math.max(0, Math.floor(secs || 0));
	const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
	if (d) return _('%dd %dh').format(d, h);
	if (h) return _('%dh %dm').format(h, m);
	return _('%dm %ds').format(m, s % 60);
}

function pct(part, whole) { return whole > 0 ? Math.round(100 * part / whole) : 0; }

function bandOf(mhz) {
	if (!(mhz > 0)) return null;
	return mhz < 3000 ? '2.4 GHz' : mhz < 5925 ? '5 GHz' : mhz < 7200 ? '6 GHz' : '60 GHz';
}

function widthOf(htmode) {
	const m = /(\d+)/.exec(htmode || '');
	return m ? '%s MHz'.format(m[1]) : (htmode ? '20 MHz' : null);
}

function genOf(rate) {
	if (!rate) return null;
	return rate.eht ? 'Wi-Fi 7' : rate.he ? 'Wi-Fi 6' : rate.vht ? 'Wi-Fi 5' : rate.ht ? 'Wi-Fi 4' : null;
}

function signalLevel(dbm) {
	return dbm >= -55 ? 4 : dbm >= -65 ? 3 : dbm >= WEAK_DBM ? 2 : 1;
}

function text(v) { return document.createTextNode(String(v == null ? '' : v)); }

/* ------------------------------------------------------------ sparkline */

/* rates per interface, kept between polls: the byte counters' deltas */
const history = {};

function sample(key, now, rx, tx) {
	const h = history[key] || (history[key] = { rx: [], tx: [], last: null });
	const last = h.last;
	if (last && now > last.t && rx >= last.rx && tx >= last.tx) {
		const dt = (now - last.t) / 1000;
		h.rx.push(8 * (rx - last.rx) / dt);
		h.tx.push(8 * (tx - last.tx) / dt);
		if (h.rx.length > SAMPLES) { h.rx.shift(); h.tx.shift(); }
	}
	h.last = { t: now, rx, tx };
	return h;
}

function svgEl(tag, attrs) {
	const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
	for (const k in attrs) if (attrs[k] != null) el.setAttribute(k, attrs[k]);
	return el;
}

/* two series on one scale; the window is always SAMPLES wide, so a young
   series starts at the right and grows leftwards */
function sparkline(down, up) {
	const W = 300, H = 56, PAD = 2;
	const max = Math.max(1000, ...down, ...up) * 1.08;
	const x = (i, n) => W - (n - 1 - i) * (W / (SAMPLES - 1));
	const y = (v) => H - PAD - (v / max) * (H - 2 * PAD);
	const points = (arr) => arr.map((v, i) => x(i, arr.length).toFixed(1) + ',' + y(v).toFixed(1)).join(' ');

	const svg = svgEl('svg', { 'class': 'uf-spark', 'viewBox': '0 0 ' + W + ' ' + H, 'preserveAspectRatio': 'none', 'aria-hidden': 'true' });
	svg.appendChild(svgEl('line', { 'class': 'uf-grid', 'x1': 0, 'x2': W, 'y1': H - PAD, 'y2': H - PAD }));
	svg.appendChild(svgEl('line', { 'class': 'uf-grid', 'x1': 0, 'x2': W, 'y1': y(max / 2), 'y2': y(max / 2), 'stroke-dasharray': '3 4' }));
	if (down.length > 1) {
		const first = x(0, down.length).toFixed(1), last = x(down.length - 1, down.length).toFixed(1);
		svg.appendChild(svgEl('polygon', { 'class': 'uf-area', 'points': first + ',' + (H - PAD) + ' ' + points(down) + ' ' + last + ',' + (H - PAD) }));
		svg.appendChild(svgEl('polyline', { 'class': 'uf-line-down', 'points': points(down) }));
	}
	if (up.length > 1)
		svg.appendChild(svgEl('polyline', { 'class': 'uf-line-up', 'points': points(up) }));
	return { svg, max };
}

/* ----------------------------------------------------------------- view */

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load() {
		return this.collect();
	},

	/* everything the page shows, in one round of requests */
	collect() {
		network.flushCache();
		return Promise.all([
			network.getNetworks(),
			network.getDevices(),
			network.getWifiDevices(),
			network.getWifiNetworks(),
			network.getHostHints(),
			L.resolveDefault(callSystemInfo(), {}),
			L.resolveDefault(callSystemBoard(), {}),
			L.resolveDefault(callOpenufStatus(), null),
			L.resolveDefault(fs.read('/proc/cpuinfo'), '')
		]).then(([ nets, devs, radios, wnets, hints, info, board, uf, cpuinfo ]) =>
			Promise.all(wnets.map((w) => L.resolveDefault(w.getAssocList(), []))).then((lists) =>
				this.model({ nets, devs, radios, wnets, lists, hints, info, board, uf, cpuinfo })));
	},

	/* the raw answers, read into what the cards show */
	model(d) {
		const now = Date.now();
		const devByName = {};
		d.devs.forEach((dev) => { devByName[dev.getName()] = dev; });
		const bytesOf = (names) => {
			let rx = 0, tx = 0, any = false;
			names.forEach((n) => {
				const dev = devByName[n];
				if (!dev) return;
				any = true;
				rx += dev.getRXBytes() || 0;
				tx += dev.getTXBytes() || 0;
			});
			return any ? [ rx, tx ] : null;
		};

		/* the uplink: the interface carrying the default route, wan-named ones first */
		const routed = d.nets.filter((n) => n.getGatewayAddr && n.getGatewayAddr());
		const upNet = routed.find((n) => /wan/i.test(n.getName())) || routed[0] || null;
		const upDev = upNet ? (upNet.getL3Device() || upNet.getDevice()) : null;
		let uplink = null;
		if (upNet) {
			const b = upDev ? bytesOf([ upDev.getName() ]) : null;
			const h = b ? sample('up:' + upDev.getName(), now, b[0], b[1]) : null;
			uplink = {
				name: upNet.getName(),
				ifname: upDev ? upDev.getName() : null,
				gateway: upNet.getGatewayAddr(),
				dns: upNet.getDNSAddrs() || [],
				addr: upNet.getIPAddr(),
				uptime: upNet.getUptime(),
				up: upNet.isUp(),
				speed: upDev ? upDev.getSpeed() : null,
				duplex: upDev ? upDev.getDuplex() : null,
				/* for the device, received is what comes down from the internet */
				down: h ? h.rx : [], upl: h ? h.tx : []
			};
		}

		/* radios, their networks and clients */
		const clients = [];
		const radios = d.radios.map((r) => {
			const nets = d.wnets.map((w, i) => ({ w, stations: d.lists[i] || [] })).filter((n) => n.w.getWifiDeviceName() === r.getName());
			const live = nets.find((n) => n.w.isUp()) || nets[0] || null;
			const freq = live ? live.w.ubus('net', 'iwinfo', 'frequency') : null;
			const band = bandOf(freq) || ({ '2g': '2.4 GHz', '5g': '5 GHz', '6g': '6 GHz', '60g': '60 GHz' })[r.get('band')] || null;
			const ifnames = nets.map((n) => n.w.getIfname()).filter(Boolean);
			const b = bytesOf(ifnames);
			const h = b ? sample('radio:' + r.getName(), now, b[0], b[1]) : null;
			const ssids = nets.map((n) => {
				const ssid = n.w.getActiveSSID() || n.w.getSSID() || n.w.getMeshID() || '?';
				const up = n.w.isUp();
				const enc = up ? n.w.getActiveEncryption() : null;
				/* a station's peer list is the access point it joined, not a client */
				const isAP = /^(ap|master)$/i.test(n.w.getActiveMode() || n.w.getMode() || '');
				if (isAP) n.stations.forEach((s) => {
					const rate = s.tx || s.rx;
					clients.push({
						mac: s.mac,
						name: d.hints.getHostnameByMACAddr(s.mac) || null,
						ip: d.hints.getIPAddrByMACAddr(s.mac) || null,
						ssid, band, radio: r.getName(),
						signal: s.signal, noise: s.noise,
						rxRate: s.rx ? s.rx.rate : null, txRate: s.tx ? s.tx.rate : null,
						gen: genOf(rate),
						connected: s.connected_time
					});
				});
				return { ssid, up, enc, isAP, mode: n.w.getActiveMode(), ifname: n.w.getIfname(), clients: isAP ? n.stations.length : 0 };
			});
			return {
				name: r.getName(),
				up: r.isUp(),
				disabled: r.isDisabled(),
				band,
				channel: live ? live.w.getChannel() : null,
				width: widthOf(r.get('htmode')),
				txpower: live ? live.w.getTXPower() : null,
				noise: live ? live.w.getNoise() : null,
				country: live ? live.w.getCountryCode() : null,
				ssids,
				clients: ssids.reduce((n, s) => n + s.clients, 0),
				/* for a radio, what it transmits is what the clients download */
				down: h ? h.tx : [], upl: h ? h.rx : []
			};
		});
		clients.sort((a, b) => (b.signal || -200) - (a.signal || -200));

		/* system */
		const info = d.info || {}, mem = info.memory || {}, root = info.root || {};
		const cores = (String(d.cpuinfo || '').match(/^processor\s*:/gm) || []).length || null;
		const load1 = Array.isArray(info.load) ? info.load[0] / 65536 : null;
		const available = mem.available != null ? mem.available : (mem.free || 0) + (mem.buffered || 0) + (mem.cached || 0);
		const system = {
			hostname: d.board.hostname, model: d.board.model, board: d.board.board_name,
			release: d.board.release ? d.board.release.description : null, kernel: d.board.kernel,
			uptime: info.uptime, load: Array.isArray(info.load) ? info.load.map((l) => (l / 65536).toFixed(2)) : null,
			cores, load1,
			memTotal: mem.total || 0, memAvail: available,
			rootUsed: (root.used || 0) * 1024, rootTotal: (root.total || 0) * 1024
		};

		/* openUF */
		let uf = null;
		if (d.uf && typeof d.uf === 'object') {
			const st = d.uf.state || {}, h = d.uf.health || {}, c = d.uf.config || {}, id = d.uf.identity || {}, svc = d.uf.service || {};
			uf = {
				running: !!svc.running, enabled: !!svc.enabled,
				adopted: !!st.adopted,
				inform: st.inform_url || c.inform_url || null,
				lastOk: h.last_ok || null, lastFail: h.last_fail || null, lastFailMsg: h.last_fail_msg || null,
				now: d.uf.now || Math.floor(now / 1000),
				identity: id.title || id.name || null, model: id.model || null, fw: id.fw_ver || null,
				profile: d.uf.modelmap ? (d.uf.modelmap.title || d.uf.modelmap.name) : null,
				version: d.uf.version || null,
				error: d.uf.config_error || null
			};
		}

		return { now, uplink, radios, clients, system, uf, checks: this.checks({ uplink, radios, clients, system, uf }) };
	},

	/* the verdict's checks: state ok / warn / bad / off, with the one line
	   that says why */
	checks(m) {
		const out = [];
		const last = (arr) => arr.length ? arr[arr.length - 1] : 0;

		if (m.uplink) {
			const linkText = [ m.uplink.ifname, m.uplink.speed > 0 ? _('%s link').format(fmtRate(m.uplink.speed * 1e6)) : null ].filter(Boolean).join(' · ');
			out.push({ id: 'uplink', state: m.uplink.up ? 'ok' : 'bad', label: _('Uplink'),
				value: m.uplink.up ? '↓ ' + fmtRate(last(m.uplink.down)) : _('Down'),
				detail: m.uplink.up ? '↑ %s · %s'.format(fmtRate(last(m.uplink.upl)), linkText) : _('%s has no carrier').format(m.uplink.name),
				href: L.url('admin/network/network') });
		}
		else
			out.push({ id: 'uplink', state: 'bad', label: _('Uplink'), value: _('No default route'), detail: _('No interface has a gateway'), href: L.url('admin/network/network') });

		if (m.uf) {
			const age = m.uf.lastOk ? m.uf.now - m.uf.lastOk : null;
			const host = m.uf.inform ? m.uf.inform.replace(/^https?:\/\/([^/:]+).*$/, '$1') : null;
			let state, value, detail;
			if (!m.uf.running) { state = 'bad'; value = _('openUF stopped'); detail = m.uf.error ? _('Configuration does not load') : _('The service is not running'); }
			else if (!m.uf.adopted) { state = 'warn'; value = _('Not adopted'); detail = host ? _('Waiting for %s').format(host) : _('Waiting for a controller'); }
			else if (age != null && age > 120) { state = 'warn'; value = _('Adopted'); detail = _('Last contact %s ago').format(fmtDuration(age)); }
			else { state = 'ok'; value = _('Adopted'); detail = host ? '%s · %s'.format(host, age != null ? _('%ds ago').format(age) : _('in touch')) : _('in touch'); }
			out.push({ id: 'controller', state, label: _('Controller'), value, detail, href: L.url('admin/services/openuf') });
		}

		if (m.system.load1 != null) {
			const share = m.system.cores ? m.system.load1 / m.system.cores : null;
			const p = share != null ? Math.round(share * 100) : null;
			out.push({ id: 'cpu', state: p == null ? 'ok' : p >= 100 ? 'bad' : p >= 70 ? 'warn' : 'ok', label: _('CPU'),
				value: p != null ? '%d%%'.format(Math.min(p, 999)) : m.system.load1.toFixed(2),
				detail: m.system.cores ? _('Load %s · %d cores').format(m.system.load1.toFixed(2), m.system.cores) : _('Load average, 1 minute') });
		}

		if (m.system.memTotal) {
			const p = pct(m.system.memAvail, m.system.memTotal);
			out.push({ id: 'memory', state: p < 10 ? 'bad' : p < 25 ? 'warn' : 'ok', label: _('Memory'),
				value: _('%d%% available').format(p), detail: '%s of %s'.format(fmtBytes(m.system.memAvail), fmtBytes(m.system.memTotal)) });
		}

		if (m.radios.length) {
			const up = m.radios.filter((r) => r.up).length, ssids = m.radios.reduce((n, r) => n + r.ssids.filter((s) => s.up).length, 0);
			out.push({ id: 'wifi', state: up === 0 ? 'bad' : up < m.radios.length ? 'warn' : 'ok', label: _('Wi-Fi'),
				value: up === 0 ? _('All radios down') : _('%d of %d up').format(up, m.radios.length),
				detail: _('%d SSIDs · %d clients').format(ssids, m.clients.length), href: L.url('admin/network/wireless') });
		}
		else
			out.push({ id: 'wifi', state: 'off', label: _('Wi-Fi'), value: _('No radios'), detail: _('This device has no wireless hardware') });

		if (m.clients.length) {
			const weak = m.clients.filter((c) => c.signal != null && c.signal < WEAK_DBM);
			const weakest = m.clients[m.clients.length - 1];
			out.push({ id: 'signal', state: weak.length ? 'warn' : 'ok', label: _('Signal'),
				value: weak.length ? _('%d weak').format(weak.length) : _('All good'),
				detail: weak.length ? '%s · %d dBm'.format(weak[0].name || weak[0].mac, weak[0].signal) : _('All above %d dBm').format(WEAK_DBM) + (weakest ? ' · ' + weakest.signal + ' dBm' : '') });
		}
		else if (m.radios.length)
			out.push({ id: 'signal', state: 'off', label: _('Clients'), value: _('None connected'), detail: _('No station on any radio') });

		if (m.system.rootTotal) {
			const p = pct(m.system.rootUsed, m.system.rootTotal);
			out.push({ id: 'storage', state: p >= 95 ? 'bad' : p >= 80 ? 'warn' : 'ok', label: _('Storage'),
				value: _('%d%% used').format(p), detail: _('%s free').format(fmtBytes(m.system.rootTotal - m.system.rootUsed)) });
		}

		return out;
	},

	/* ------------------------------------------------------------ render */

	render(m) {
		/* the page's own stylesheet, once, versioned like LuCI's own scripts
		   (the token changes with every package install), so an upgrade is
		   never shown with the previous sheet from the browser's cache */
		const href = L.resource('openuf/dashboard.css') + (L.env.resource_version ? '?v=' + L.env.resource_version : '');
		if (!document.querySelector('link[href="' + href + '"]'))
			document.head.appendChild(E('link', { 'rel': 'stylesheet', 'href': href }));

		this.nodes = {
			head: E('div', { 'class': 'uf-head' }),
			tiles: E('div', { 'class': 'uf-tiles' }),
			path: E('div', {}),
			flow: E('div', { 'class': 'uf-flow' }),
			flowAside: E('span', { 'class': 'uf-aside uf-legend' }),
			radios: E('div', { 'class': 'uf-radio-list' }),
			radiosAside: E('span', { 'class': 'uf-aside' }),
			clients: E('div', {}),
			clientsAside: E('span', { 'class': 'uf-aside' }),
			system: E('div', { 'class': 'uf-rows' }),
			uf: E('div', { 'class': 'uf-rows' }),
			ufCard: null
		};
		const n = this.nodes;

		n.ufCard = this.card(_('UniFi controller'), n.uf, E('a', { 'class': 'uf-aside', 'href': L.url('admin/services/openuf') }, [ _('Manage openUF') ]), 'uf-span-6');

		this.root = E('div', { 'class': 'uf-dash' }, [
			n.head,
			n.tiles,
			this.card(_('Network path'), n.path, E('span', { 'class': 'uf-aside' }, [ _('Gateway, this device, its radios and networks') ])),
			this.card(_('Throughput'), n.flow, n.flowAside, 'uf-span-7'),
			this.card(_('Radios'), n.radios, n.radiosAside, 'uf-span-5'),
			this.card(_('Clients'), n.clients, n.clientsAside),
			this.card(_('System'), n.system, null, 'uf-span-6'),
			n.ufCard
		]);

		this.update(m);
		/* one failed round (a dropped request) skips a sample; LuCI's own
		   poll indicator says when the device is unreachable */
		poll.add(() => this.collect().then((model) => this.update(model)).catch(() => {}), 5);
		return this.root;
	},

	card(title, body, aside, extra) {
		return E('section', { 'class': 'uf-card' + (extra ? ' ' + extra : '') }, [
			E('div', { 'class': 'uf-card-head' }, [ E('h3', {}, [ title ]), aside || '' ]),
			body
		]);
	},

	update(m) {
		const n = this.nodes;
		const bad = m.checks.filter((c) => c.state === 'bad').length, warn = m.checks.filter((c) => c.state === 'warn').length;
		const issues = bad + warn;

		/* the verdict */
		n.head.setAttribute('data-state', bad ? 'bad' : warn ? 'warn' : 'ok');
		dom.content(n.head, [
			E('div', { 'class': 'uf-verdict', 'aria-hidden': 'true' }),
			E('div', { 'class': 'uf-head-text' }, [
				E('h2', {}, [ issues === 0 ? _('Everything looks healthy') : issues === 1 ? _('1 thing needs attention') : _('%d things need attention').format(issues) ]),
				E('p', {}, [
					E('b', {}, [ text(m.system.model || m.system.board || '?') ]), ' · ', text(m.system.hostname || ''),
					m.system.release ? ' · ' + m.system.release : '',
					' · ', m.clients.length === 1 ? _('1 client') : _('%d clients').format(m.clients.length)
				])
			]),
			E('span', { 'class': 'uf-stamp' }, [ _('Live · %s').format(new Date(m.now).toLocaleTimeString()) ])
		]);

		/* the checks */
		dom.content(n.tiles, m.checks.map((c) => E(c.href ? 'a' : 'div', { 'class': 'uf-tile', 'data-state': c.state, 'href': c.href || null }, [
			E('span', { 'class': 'uf-tile-icon', 'aria-hidden': 'true' }),
			E('div', { 'class': 'uf-tile-body' }, [
				E('span', { 'class': 'uf-tile-label' }, [ c.label ]),
				E('span', { 'class': 'uf-tile-value' }, [ text(c.value) ]),
				E('span', { 'class': 'uf-tile-detail' }, [ text(c.detail) ])
			])
		])));

		this.renderPath(m);
		this.renderFlow(m);
		this.renderRadios(m);
		this.renderClients(m);
		this.renderSystem(m);
		this.renderUF(m);
	},

	renderPath(m) {
		const n = this.nodes;
		const last = (arr) => arr.length ? arr[arr.length - 1] : 0;
		const u = m.uplink;

		const gateway = E('div', { 'class': 'uf-node uf-node-gw' }, [
			E('small', {}, [ _('Gateway') ]),
			E('b', {}, [ text(u && u.gateway ? u.gateway : _('None')) ]),
			E('span', {}, [ u && u.dns.length ? _('DNS %s').format(u.dns.join(', ')) : _('No default route') ])
		]);
		const link1 = E('div', { 'class': 'uf-link' }, u ? [
			E('span', { 'class': 'uf-down' }, [ '↓ ' + fmtRate(last(u.down)) ]),
			E('span', { 'class': 'uf-up' }, [ '↑ ' + fmtRate(last(u.upl)) ]),
			E('small', {}, [ text([ u.ifname, u.speed > 0 ? fmtRate(u.speed * 1e6).replace('bit/s', '') : null ].filter(Boolean).join(' · ')) ])
		] : [ E('small', {}, [ '—' ]) ]);
		const ap = E('div', { 'class': 'uf-node uf-node-ap' }, [
			E('small', {}, [ _('This access point') ]),
			E('b', {}, [ text(m.system.model || m.system.hostname || '?') ]),
			E('span', {}, [ text([ u && u.addr ? u.addr : null, m.system.uptime ? _('up %s').format(fmtDuration(m.system.uptime)) : null ].filter(Boolean).join(' · ')) ])
		]);

		const children = [ gateway, link1, ap ];
		if (m.radios.length) {
			children.push(E('div', { 'class': 'uf-link uf-link-fan' }, [ E('small', {}, [ m.radios.length === 1 ? _('1 radio') : _('%d radios').format(m.radios.length) ]) ]));
			children.push(E('div', { 'class': 'uf-radios' }, m.radios.map((r) => E('div', { 'class': 'uf-node uf-node-radio', 'data-up': r.up ? '1' : '0' }, [
				E('span', { 'class': 'uf-chip uf-chip-accent' }, [ text(r.band || r.name) ]),
				E('b', {}, [ text(r.channel ? _('Ch %s').format(r.channel) + (r.width ? ' · ' + r.width : '') : r.up ? r.name : _('Off')) ]),
				E('span', { 'class': 'uf-down' }, [ r.up ? '↓ ' + fmtRate(last(r.down)) : '' ]),
				E('div', { 'class': 'uf-ssids' }, r.ssids.length ? r.ssids.map((s) => E('span', { 'class': 'uf-chip' + (s.up ? '' : ' uf-chip-off') }, [
					s.enc && s.enc !== '-' && !/none/i.test(s.enc) ? E('i', { 'class': 'uf-lock', 'aria-hidden': 'true' }) : '',
					text(s.ssid), E('em', {}, [ !s.up ? _('off') : s.isAP ? text(s.clients) : _('joined') ])
				])) : [ E('span', { 'class': 'uf-chip uf-chip-off' }, [ _('No network') ]) ])
			]))));
		}
		else
			children.push(E('div', { 'class': 'uf-link' }, [ E('small', {}, [ _('No radios') ]) ]), E('div', { 'class': 'uf-empty' }, [ _('A wired-only device: nothing hangs off it over the air.') ]));

		dom.content(n.path, E('div', { 'class': 'uf-path' }, children));
	},

	renderFlow(m) {
		const n = this.nodes;
		const rows = [];
		const peak = (arr) => arr.length ? Math.max(...arr) : 0;
		const last = (arr) => arr.length ? arr[arr.length - 1] : 0;
		const row = (title, sub, down, up) => {
			const chart = sparkline(down, up);
			return E('div', { 'class': 'uf-flow-row' }, [
				E('div', { 'class': 'uf-flow-meta' }, [
					E('small', {}, [ text(title + (sub ? ' · ' + sub : '')) ]),
					E('b', { 'class': 'uf-down' }, [ '↓ ' + fmtRate(last(down)) ]),
					E('span', { 'class': 'uf-up' }, [ '↑ ' + fmtRate(last(up)) ]),
					E('span', {}, [ _('peak ↓ %s ↑ %s').format(fmtRate(peak(down)), fmtRate(peak(up))) ])
				]),
				E('div', {}, [
					chart.svg,
					E('div', { 'class': 'uf-flow-scale' }, [ E('span', {}, [ _('5 min ago') ]), E('span', {}, [ fmtRate(chart.max) ]), E('span', {}, [ _('now') ]) ])
				])
			]);
		};
		if (m.uplink) rows.push(row(_('Uplink'), m.uplink.ifname, m.uplink.down, m.uplink.upl));
		m.radios.forEach((r) => { if (r.up) rows.push(row(r.band || r.name, r.name, r.down, r.upl)); });

		const have = rows.length && (m.uplink ? m.uplink.down.length : 0) + m.radios.reduce((k, r) => k + r.down.length, 0) > 0;
		dom.content(n.flow, rows.length ? rows : E('div', { 'class': 'uf-empty' }, [ _('No interface to measure.') ]));
		dom.content(n.flowAside, [
			E('span', {}, [ E('i', { 'aria-hidden': 'true' }), _('Download') ]),
			E('span', {}, [ E('i', { 'class': 'uf-up', 'aria-hidden': 'true' }), _('Upload') ]),
			E('span', {}, [ have ? _('last 5 minutes') : _('collecting…') ])
		]);
	},

	renderRadios(m) {
		const n = this.nodes;
		dom.content(n.radiosAside, [ m.radios.length ? _('%d of %d up').format(m.radios.filter((r) => r.up).length, m.radios.length) : '' ]);
		if (!m.radios.length) {
			dom.content(n.radios, E('div', { 'class': 'uf-empty' }, [ _('This device has no wireless radios.') ]));
			return;
		}
		const kv = (label, value, quiet) => E('div', { 'class': 'uf-kv' }, [ E('small', {}, [ label ]), E('span', { 'class': quiet ? 'uf-quiet' : null }, [ text(value == null || value === '' ? '—' : value) ]) ]);
		dom.content(n.radios, m.radios.map((r) => E('div', { 'class': 'uf-radio' }, [
			E('div', { 'class': 'uf-radio-head' }, [
				E('span', { 'class': 'uf-chip uf-chip-accent' }, [ text(r.band || r.name) ]),
				E('b', {}, [ r.channel ? _('Ch %s').format(r.channel) : r.name, r.width ? E('small', {}, [ r.width ]) : '' ]),
				E('span', { 'class': 'uf-state' }, [ E('i', { 'class': 'uf-dot', 'data-up': r.up ? '1' : '0', 'aria-hidden': 'true' }), r.disabled ? _('Disabled') : r.up ? _('Up') : _('Down') ])
			]),
			kv(_('Clients'), r.clients),
			kv(_('TX power'), r.txpower != null ? _('%d dBm').format(r.txpower) : null),
			kv(_('Noise'), r.noise ? _('%d dBm').format(r.noise) : _('not reported'), !r.noise),
			kv(_('Country'), r.country, true),
			E('div', { 'class': 'uf-ssids' }, r.ssids.map((s) => E('span', { 'class': 'uf-chip' + (s.up ? '' : ' uf-chip-off') }, [
				s.enc && s.enc !== '-' && !/none/i.test(s.enc) ? E('i', { 'class': 'uf-lock', 'aria-hidden': 'true' }) : '',
				text(s.ssid), E('em', {}, [ !s.up ? _('off') : !s.isAP ? _('joined as a station') : s.clients === 1 ? _('1 client') : _('%d clients').format(s.clients) ])
			])))
		])));
	},

	renderClients(m) {
		const n = this.nodes;
		dom.content(n.clientsAside, [ m.clients.length === 1 ? _('1 connected') : _('%d connected').format(m.clients.length) ]);
		if (!m.clients.length) {
			dom.content(n.clients, E('div', { 'class': 'uf-empty' }, [ m.radios.length ? _('No client is connected right now.') : _('No radios, so no wireless clients.') ]));
			return;
		}
		const rows = m.clients.map((c) => {
			const level = c.signal != null ? signalLevel(c.signal) : 0;
			return E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td', 'data-title': _('Device') }, [ E('div', { 'class': 'uf-client-name' }, [
					E('b', {}, [ text(c.name || _('Unknown device')) ]),
					E('small', {}, [ text(c.mac + (c.ip ? ' · ' + c.ip : '')) ])
				]) ]),
				E('div', { 'class': 'td', 'data-title': _('Network') }, [ text(c.ssid), c.band ? E('em', { 'class': 'uf-quiet' }, [ ' · ' + c.band ]) : '' ]),
				E('div', { 'class': 'td', 'data-title': _('Signal') }, [
					E('span', { 'class': 'uf-bars', 'data-level': level, 'aria-hidden': 'true' }, [ E('i'), E('i'), E('i'), E('i') ]),
					E('span', { 'class': c.signal != null && c.signal < WEAK_DBM ? 'uf-weak' : null }, [ c.signal != null ? _('%d dBm').format(c.signal) : '—' ])
				]),
				E('div', { 'class': 'td', 'data-title': _('Rate') }, [ E('div', { 'class': 'uf-rate-pair' }, [
					E('span', { 'class': 'uf-down' }, [ '↓ ' + (c.txRate ? fmtRate(c.txRate * 1000) : '—') ]),
					E('span', { 'class': 'uf-up' }, [ '↑ ' + (c.rxRate ? fmtRate(c.rxRate * 1000) : '—') ])
				]) ]),
				E('div', { 'class': 'td', 'data-title': _('Standard') }, [ text(c.gen || '—') ]),
				E('div', { 'class': 'td', 'data-title': _('Connected') }, [ c.connected != null ? fmtDuration(c.connected) : '—' ])
			]);
		});
		dom.content(n.clients, E('div', { 'class': 'table' }, [
			E('div', { 'class': 'tr table-titles' }, [
				E('div', { 'class': 'th' }, [ _('Device') ]), E('div', { 'class': 'th' }, [ _('Network') ]), E('div', { 'class': 'th' }, [ _('Signal') ]),
				E('div', { 'class': 'th' }, [ _('Rate') ]), E('div', { 'class': 'th' }, [ _('Standard') ]), E('div', { 'class': 'th' }, [ _('Connected') ])
			])
		].concat(rows)));
	},

	renderSystem(m) {
		const s = m.system;
		const row = (label, value) => E('div', { 'class': 'uf-row' }, [ E('small', {}, [ label ]), E('div', {}, Array.isArray(value) ? value : [ text(value == null ? '—' : value) ]) ]);
		const bar = (used, total, text_) => {
			const p = pct(used, total), level = p >= 95 ? 'bad' : p >= 80 ? 'warn' : null;
			const fill = E('i', { 'data-level': level });
			fill.style.width = Math.min(100, p) + '%';
			return [ E('div', { 'class': 'uf-bar' }, [ fill ]), E('span', { 'class': 'uf-bar-text' }, [ text_ ]) ];
		};
		dom.content(this.nodes.system, [
			row(_('Firmware'), s.release),
			row(_('Kernel'), s.kernel),
			row(_('Uptime'), s.uptime ? fmtDuration(s.uptime) : null),
			row(_('Load'), s.load ? s.load.join(' · ') + (s.cores ? ' · ' + (s.cores === 1 ? _('1 core') : _('%d cores').format(s.cores)) : '') : null),
			row(_('Memory'), s.memTotal ? bar(s.memTotal - s.memAvail, s.memTotal, _('%s in use · %s available of %s').format(fmtBytes(s.memTotal - s.memAvail), fmtBytes(s.memAvail), fmtBytes(s.memTotal))) : null),
			row(_('Storage'), s.rootTotal ? bar(s.rootUsed, s.rootTotal, _('%s used · %s free of %s').format(fmtBytes(s.rootUsed), fmtBytes(s.rootTotal - s.rootUsed), fmtBytes(s.rootTotal))) : null)
		]);
	},

	renderUF(m) {
		const card = this.nodes.ufCard;
		if (!m.uf) { card.hidden = true; return; }
		card.hidden = false;
		const u = m.uf;
		const row = (label, value) => E('div', { 'class': 'uf-row' }, [ E('small', {}, [ label ]), E('div', {}, Array.isArray(value) ? value : [ text(value == null ? '—' : value) ]) ]);
		const state = !u.running ? 'bad' : u.adopted ? 'ok' : 'warn';
		const age = (ts) => ts ? _('%s ago').format(fmtDuration(u.now - ts)) : null;
		dom.content(this.nodes.uf, [
			row(_('Adoption'), [ E('span', { 'class': 'uf-pill', 'data-state': state }, [ !u.running ? _('openUF is not running') : u.adopted ? _('Adopted') : _('Not adopted yet') ]) ]),
			row(_('Controller'), u.inform),
			row(_('Last contact'), u.lastOk ? age(u.lastOk) : _('none yet')),
			row(_('Last failure'), u.lastFail ? [ text(age(u.lastFail)), u.lastFailMsg ? E('span', { 'class': 'uf-quiet' }, [ ' · ' + u.lastFailMsg ]) : '' ] : _('none')),
			row(_('Presented as'), u.identity ? [ text(u.identity), u.model ? E('span', { 'class': 'uf-quiet' }, [ ' (' + u.model + ')' ]) : '', u.fw ? E('span', { 'class': 'uf-quiet' }, [ ' · ' + _('firmware %s').format(u.fw) ]) : '' ] : null),
			row(_('Hardware profile'), u.profile),
			row(_('openUF version'), u.version),
			u.error ? row(_('Problem'), [ E('span', { 'class': 'uf-weak' }, [ text(u.error) ]) ]) : ''
		]);
	}
});
