'use strict';
'require baseclass';
'require ui';

/*
 * Halo's shell: LuCI's menu tree as one sidebar.
 *
 *   level 1 (Status, System, Network...)  a row with an icon and the name;
 *                                         a section opens to show its pages
 *   level 2 (Overview, Interfaces...)     the pages, nested under the section
 *   level 3 and deeper                    segmented tabs above the page
 *
 * The sidebar has three shapes, chosen before first paint (header.ut) and
 * kept up to date here: "side", the full sidebar; "rail", icons only with
 * the section's pages in a flyout (narrow screens, or collapsed by the
 * person -- remembered per browser); "bar", a bottom bar and a sheet on
 * phones. Also here: the breadcrumb, the appearance toggle (automatic /
 * light / dark, remembered per browser), LuCI's indicators dressed as
 * pills, and two tidy-ups of stock pages that CSS alone cannot do: a heading
 * that only repeats the breadcrumb is hidden from view (screen readers keep
 * it), and the Status overview's memory and storage tables become meters.
 * Every tidy-up leaves LuCI's own nodes in the DOM and re-runs when LuCI
 * redraws, so nothing LuCI does breaks when the theme is wrong about a page.
 */

const ICONS = [ 'dashboard', 'status', 'system', 'services', 'network', 'vpn', 'statistics', 'nas', 'docker', 'logout' ];
const THEME_KEY = 'halo.theme';
const NAV_KEY = 'halo.nav';
const OPEN_KEY = 'halo.nav.open';

function storageGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
function storageSet(k, v) { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) { /* private mode */ } }

function icon(name) {
	return E('span', {
		'class': 'halo-icon',
		'data-icon': ICONS.indexOf(name) > -1 ? name : null,
		'aria-hidden': 'true'
	});
}

function headingKey(text) {
	return String(text || '').replace(/\s+/g, ' ').replace(/[\s:]+$/, '').trim().toLowerCase();
}

/* ---------------------------------------------------------------------------
 * Status -> Overview meters. LuCI draws memory and storage as a table with
 * one progress bar per row and the figures only in each bar's title. Halo
 * reads those figures and draws a meter in front of the table; the table
 * stays in the DOM, hidden, because the include owns it and redraws it on
 * every poll (the observer then builds a fresh meter from the fresh table).
 * A pass over a table it has already handled changes nothing.
 * ------------------------------------------------------------------------ */

const UNIT = { K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4, P: 1024 ** 5 };

/* a bar's title, "27.0 MiB / 98.3 MiB (27%)", as [ value, total ] in bytes */
function readBar(bar) {
	const m = /^\s*([\d.]+)\s*([KMGTP]?)i?B\s*\/\s*([\d.]+)\s*([KMGTP]?)i?B/.exec(bar.getAttribute('title') || '');
	if (!m) return null;
	const value = parseFloat(m[1]) * (UNIT[m[2]] || 1), total = parseFloat(m[3]) * (UNIT[m[4]] || 1);
	return total > 0 ? [ value, total ] : null;
}

function bytes(n) { return String.format('%1024.1mB', Math.max(0, n || 0)); }
function pct(part, whole) { return whole > 0 ? Math.round(100 * part / whole) : 0; }

/* the overview section titled `title` and its still-untouched table, read
   into { label -> [ value, total ] } */
function overviewTable(title) {
	const heads = document.querySelectorAll('#view .cbi-section > .cbi-title > h3, #view .cbi-section > h3:first-child');
	for (const h of heads) {
		const text = h.firstChild && h.firstChild.nodeType === 3 ? h.firstChild.data.trim() : '';
		if (text !== title) continue;
		const section = h.closest('.cbi-section');
		const table = section.querySelector(':scope > div > table.table');
		if (!table || table.hasAttribute('data-halo-meter')) return null;
		const rows = new Map();
		table.querySelectorAll('tr').forEach((tr) => {
			const bar = tr.querySelector('.cbi-progressbar');
			rows.set(tr.firstElementChild.textContent.trim(), bar ? readBar(bar) : null);
		});
		return { table, rows };
	}
	return null;
}

/* a bar: [ [ className, share ] ... ], shares as fractions of the width */
function drawBar(parts, label, thin) {
	const bar = E('div', { 'class': 'halo-meter-bar' + (thin ? ' is-thin' : ''), 'role': 'img', 'aria-label': label });
	parts.forEach(([ cls, share ]) => {
		const seg = E('span', { 'class': 'halo-seg ' + cls });
		seg.style.width = (Math.max(0, Math.min(1, share)) * 100).toFixed(2) + '%';
		bar.appendChild(seg);
	});
	return bar;
}

function showMeter(table, meter) {
	table.setAttribute('data-halo-meter', '1');
	table.classList.add('halo-src-hidden');
	const old = table.previousElementSibling;
	if (old && old.classList.contains('halo-enhanced')) old.remove();
	meter.classList.add('halo-enhanced');
	table.parentNode.insertBefore(meter, table);
}

/* Memory: LuCI's rows are "Total Available", "Used" (= total - free),
   "Buffered", "Cached" and maybe "Swap free". In use is what is not
   available; the rest of the available part is cache the kernel can drop. */
function memoryMeter() {
	const found = overviewTable(_('Memory'));
	if (!found) return;
	const used = found.rows.get(_('Used')), avail = found.rows.get(_('Total Available'));
	if (!used) return;
	const total = used[1];
	const free = Math.max(0, total - used[0]);
	const available = Math.min(total, Math.max(free, avail ? avail[0] : free));
	const inUse = total - available, cache = available - free;
	const level = pct(inUse, total) >= 90 ? ' is-crit' : pct(inUse, total) >= 75 ? ' is-warn' : '';

	const legend = (cls, name, value, note) => E('li', {}, [
		E('span', { 'class': 'halo-key ' + cls }), E('span', {}, [ name ]), E('b', {}, [ bytes(value) ]),
		note ? E('em', {}, [ note ]) : ''
	]);

	const meter = E('div', { 'class': 'halo-meter' }, [
		E('div', { 'class': 'halo-meter-head' }, [
			E('span', { 'class': 'halo-meter-big' }, [ pct(available, total) + '%', E('small', {}, [ _('available') ]) ]),
			E('span', { 'class': 'halo-meter-sub' }, [ bytes(available) + ' / ' + bytes(total) ])
		]),
		drawBar([ [ 'halo-seg-used' + level, inUse / total ], [ 'halo-seg-cache', cache / total ] ],
			'%s: %s %s, %s %s, %s %s'.format(_('Memory'), bytes(inUse), _('In use'), bytes(cache), _('Cache'), bytes(free), _('Free'))),
		E('ul', { 'class': 'halo-meter-legend', 'aria-hidden': 'true' }, [
			legend('halo-seg-used', _('In use'), inUse),
			legend('halo-seg-cache', _('Cache'), cache, _('reclaimable')),
			legend('halo-seg-free', _('Free'), free)
		])
	]);

	const swap = found.rows.get(_('Swap free'));
	if (swap) {
		const swapUsed = swap[1] - swap[0];
		meter.appendChild(E('div', { 'class': 'halo-meter-rows' }, [
			E('div', { 'class': 'halo-meter-row' }, [
				E('span', { 'class': 'halo-meter-label' }, [ _('Swap') ]),
				drawBar([ [ 'halo-seg-used', swapUsed / swap[1] ] ], '%s: %s / %s'.format(_('Swap'), bytes(swapUsed), bytes(swap[1])), true),
				E('span', { 'class': 'halo-meter-val' }, [ E('b', {}, [ bytes(swapUsed) ]), ' / ' + bytes(swap[1]) ])
			])
		]));
	}

	showMeter(found.table, meter);
}

/* Storage: a thin bar per mount, the figures beside it */
function storageMeter() {
	const found = overviewTable(_('Storage'));
	if (!found || !found.rows.size) return;

	const rows = E('div', { 'class': 'halo-meter-rows' });
	found.rows.forEach((pair, name) => {
		/* "efivars (/sys/firmware/efi/efivars)": the mount point leads, the device under it */
		const m = /^(.*) \((\/.*)\)$/.exec(name);
		const label = E('span', { 'class': 'halo-meter-label' }, m ? [ m[2], E('small', {}, [ m[1] ]) ] : [ name ]);
		let bar, value;
		if (pair) {
			const [ used, size ] = pair, share = used / size;
			bar = drawBar([ [ 'halo-seg-used' + (share >= .95 ? ' is-crit' : share >= .8 ? ' is-warn' : ''), share ] ],
				'%s: %s %s, %s %s'.format(name, bytes(used), _('used'), bytes(size - used), _('free')), true);
			value = E('span', { 'class': 'halo-meter-val' }, [
				E('b', {}, [ bytes(used) ]), ' %s · %s %s · %s'.format(_('used'), bytes(size - used), _('free'), bytes(size))
			]);
		}
		else {
			bar = E('div', { 'class': 'halo-meter-bar is-thin' });
			value = E('span', { 'class': 'halo-meter-val' }, [ '?' ]);
		}
		rows.appendChild(E('div', { 'class': 'halo-meter-row' }, [ label, bar, value ]));
	});

	showMeter(found.table, rows);
}

/* Wireless: a band chip on each radio box, from its "Channel: 6 (2.437 GHz)" line */
function radioBands() {
	document.querySelectorAll('#view .network-status-table > .ifacebox').forEach((box) => {
		const head = box.querySelector(':scope > .ifacebox-head');
		if (!head || head.hasAttribute('data-halo-band')) return;
		const line = Array.prototype.find.call(box.querySelectorAll('.ifacebox-body .nowrap'), (n) => {
			const s = n.querySelector('strong');
			return s && s.textContent.indexOf(_('Channel')) === 0;
		});
		const m = line && /(\d+(?:\.\d+)?)\s*GHz/.exec(line.textContent);
		if (!m) return;
		const ghz = parseFloat(m[1]);
		head.setAttribute('data-halo-band', ghz < 3 ? '2.4 GHz' : ghz < 5.9 ? '5 GHz' : ghz < 7.2 ? '6 GHz' : '60 GHz');
	});
}

function watchOverview() {
	const view = document.getElementById('view');
	if (!view || !window.MutationObserver) return;
	if (!/^admin(-status(-overview)?)?$/.test(document.body.getAttribute('data-page') || '')) return;
	let running = false;
	const pass = () => {
		if (running) return;
		running = true;
		try { memoryMeter(); storageMeter(); radioBands(); }
		catch (e) { if (window.console) console.warn('halo: overview meters', e); }
		running = false;
	};
	new MutationObserver(pass).observe(view, { childList: true, subtree: true });
	pass();
}

return baseclass.extend({
	__init__() {
		this.root = document.documentElement;
		this.mqNarrow = window.matchMedia('(max-width: 1100px)');
		this.mqPhone = window.matchMedia('(max-width: 720px)');
		this.trail = { all: new Set(), page: new Set() };
		this.cats = [];
		this.openCat = null;

		this.setupTheme();
		this.setupNavShape();
		this.setupIndicators();
		this.bindNav();
		watchOverview();

		ui.menu.load().then((tree) => this.render(tree));
	},

	/* ------------------------------------------------------------ menu */

	render(tree) {
		const mode = this.pickMode(tree);
		if (!mode) return;

		this.mode = mode;
		this.dp = (L.env.dispatchpath || []).slice();

		this.cats = ui.menu.getChildren(mode.node).map((c) => {
			const raw = mode.node.children[c.name];
			return {
				name: c.name,
				title: _(c.title),
				leaf: !(c.action && c.action.type === 'firstchild'),
				pages: ui.menu.getChildren(c).map((p) => ({
					name: p.name,
					title: _(p.title),
					raw: raw && raw.children ? raw.children[p.name] : null
				}))
			};
		}).filter((c) => c.leaf || c.pages.length);

		this.renderNav();
		this.renderSubnav(this.activeCat());
		this.renderCrumbs();
		this.renderTabs();
		this.setupRepeats();
	},

	/* the top level of the tree is the mode, normally just "admin" */
	pickMode(tree) {
		const children = ui.menu.getChildren(tree);
		let active = null;

		children.forEach((child, index) => {
			const isActive = L.env.requestpath.length
				? child.name === L.env.requestpath[0]
				: index === 0;
			if (isActive)
				active = { node: child, name: child.name };
		});

		const ul = document.querySelector('#modemenu');
		if (ul && children.length > 1) {
			children.forEach((child) => {
				ul.appendChild(E('li', { 'class': active && child.name === active.name ? 'active' : '' }, [
					E('a', { 'href': L.url(child.name) }, [ _(child.title) ])
				]));
			});
			ul.hidden = false;
		}

		return active;
	},

	activeCat() {
		return this.cats.find((c) => c.name === this.dp[1]) || null;
	},

	/* the sidebar: one row per section, its pages nested under it */
	renderNav() {
		const list = document.getElementById('halo-nav');
		const foot = document.getElementById('halo-nav-logout');
		if (!list) return;

		const remembered = this.readOpen();
		list.textContent = '';

		this.cats.forEach((cat) => {
			const active = (cat.name === this.dp[1]);
			const parts = [ icon(cat.name), E('span', { 'class': 'halo-nav-label' }, [ cat.title ]) ];

			if (cat.leaf) {
				const link = E('a', {
					'class': 'halo-nav-link',
					'href': L.url(this.mode.name, cat.name),
					'data-label': cat.title,
					'aria-current': active ? 'page' : null
				}, parts);
				if (cat.name === 'logout') {
					if (foot) foot.appendChild(link);
					return;
				}
				list.appendChild(E('li', { 'class': 'halo-nav-item is-leaf' + (active ? ' is-active' : ''), 'data-cat': cat.name }, [ link ]));
				return;
			}

			const open = active || remembered.indexOf(cat.name) > -1;
			const sub = E('ul', { 'class': 'halo-nav-sub', 'id': 'halo-sub-' + cat.name });
			cat.pages.forEach((page) => {
				const current = active && page.name === this.dp[2];
				sub.appendChild(E('li', { 'class': current ? 'active' : '' }, [
					E('a', { 'href': L.url(this.mode.name, cat.name, page.name), 'aria-current': current ? 'page' : null }, [ page.title ])
				]));
			});

			const head = E('button', {
				'type': 'button',
				'class': 'halo-nav-link',
				'data-label': cat.title,
				'aria-expanded': open ? 'true' : 'false',
				'aria-controls': 'halo-sub-' + cat.name
			}, parts.concat([ E('span', { 'class': 'halo-chevron', 'aria-hidden': 'true' }) ]));

			const item = E('li', {
				'class': 'halo-nav-item' + (open ? ' is-open' : '') + (active ? ' is-active' : ''),
				'data-cat': cat.name
			}, [ head, sub ]);

			/* the full sidebar: the row opens and closes the section's pages
			   in place; the rail and the bar: it opens them as a flyout or sheet */
			head.addEventListener('click', (ev) => {
				ev.preventDefault();
				if (this.navShape() !== 'side') {
					if (this.openCat === cat.name) this.closeNav(true);
					else this.openNav(cat, ev.detail === 0);
					return;
				}
				const now = !item.classList.contains('is-open');
				item.classList.toggle('is-open', now);
				head.setAttribute('aria-expanded', now ? 'true' : 'false');
				const kept = this.readOpen().filter((n) => n !== cat.name);
				if (now) kept.push(cat.name);
				this.writeOpen(kept);
			});

			list.appendChild(item);
		});

		const current = list.querySelector('.halo-nav-sub li.active > a');
		if (current && current.scrollIntoView && this.navShape() === 'side')
			current.scrollIntoView({ block: 'nearest' });
	},

	readOpen() {
		try { return JSON.parse(storageGet(OPEN_KEY) || '[]') || []; }
		catch (e) { return []; }
	},

	writeOpen(list) {
		storageSet(OPEN_KEY, list.length ? JSON.stringify(list) : null);
	},

	renderSubnav(cat) {
		const nav = document.getElementById('halo-subnav');
		const head = document.getElementById('halo-subnav-head');
		const list = document.getElementById('halo-subnav-list');
		if (!nav || !head || !list) return;

		head.textContent = '';
		list.textContent = '';
		nav.hidden = !cat;
		if (!cat) return;

		head.appendChild(icon(cat.name));
		head.appendChild(E('span', { 'class': 'halo-subnav-title', 'id': 'halo-subnav-title' }, [ cat.title ]));
		nav.setAttribute('aria-labelledby', 'halo-subnav-title');
		nav.setAttribute('data-cat', cat.name);

		const isActiveCat = (cat.name === this.dp[1]);
		cat.pages.forEach((page) => {
			const current = isActiveCat && page.name === this.dp[2];
			list.appendChild(E('li', { 'class': current ? 'active' : '' }, [
				E('a', {
					'href': L.url(this.mode.name, cat.name, page.name),
					'aria-current': current ? 'page' : null
				}, [ page.title ])
			]));
		});

		const current = list.querySelector('li.active > a');
		if (current && current.scrollIntoView && !this.mqNarrow.matches)
			current.scrollIntoView({ block: 'nearest' });
	},

	/* narrow screens: the page list as a flyout beside the rail (a sheet
	   above the bottom bar on phones) */
	openNav(cat, focusFirst) {
		this.renderSubnav(cat);
		this.openCat = cat.name;
		document.body.classList.add('halo-nav-open');
		const scrim = document.getElementById('halo-scrim');
		if (scrim) scrim.hidden = false;

		document.querySelectorAll('#halo-nav > .halo-nav-item').forEach((li) => {
			const on = li.getAttribute('data-cat') === cat.name;
			li.classList.toggle('is-flyout', on);
		});

		if (focusFirst) {
			const first = document.querySelector('#halo-subnav-list a[aria-current]') || document.querySelector('#halo-subnav-list a');
			if (first) first.focus();
		}
	},

	closeNav(refocus) {
		if (!this.openCat) return;
		const was = this.openCat;
		this.openCat = null;
		document.body.classList.remove('halo-nav-open');
		const scrim = document.getElementById('halo-scrim');
		if (scrim) scrim.hidden = true;
		document.querySelectorAll('#halo-nav > .halo-nav-item.is-flyout').forEach((li) => {
			li.classList.remove('is-flyout');
		});
		/* the list goes back to the current section, so a resize to a wide
		   screen shows the right pages */
		this.renderSubnav(this.activeCat());
		if (refocus) {
			const link = document.querySelector('#halo-nav > .halo-nav-item[data-cat="' + was + '"] > .halo-nav-link');
			if (link) link.focus();
		}
	},

	bindNav() {
		const scrim = document.getElementById('halo-scrim');
		const subnav = document.getElementById('halo-subnav');

		if (scrim)
			scrim.addEventListener('click', () => this.closeNav(false));

		document.addEventListener('keydown', (ev) => {
			if (ev.key === 'Escape' && this.openCat) {
				ev.preventDefault();
				this.closeNav(true);
			}
		});

		document.addEventListener('click', (ev) => {
			if (!this.openCat) return;
			if (ev.target.closest('#halo-subnav, #halo-side')) return;
			this.closeNav(false);
		});

		if (subnav)
			subnav.addEventListener('click', (ev) => {
				if (this.openCat && ev.target.closest && ev.target.closest('a[href]'))
					this.closeNav(false);
			});

	},

	/* ---------------------------------------------------- nav shape */

	navShape() {
		return this.root.getAttribute('data-nav') || 'side';
	},

	/* "bar" on phones, "rail" on narrow screens or when collapsed by the
	   person (remembered), "side" otherwise; the flyout closes whenever the
	   shape changes, and the collapse button says what it will do */
	applyNavShape() {
		const pref = storageGet(NAV_KEY);
		const shape = this.mqPhone.matches ? 'bar' : (pref === 'rail' || this.mqNarrow.matches) ? 'rail' : 'side';
		if (this.root.getAttribute('data-nav') !== shape) {
			this.root.setAttribute('data-nav', shape);
			this.closeNav(false);
		}
		const btn = document.getElementById('halo-collapse');
		if (btn) {
			const collapsed = pref === 'rail';
			const label = collapsed ? _('Expand navigation') : _('Collapse navigation');
			btn.setAttribute('aria-pressed', collapsed ? 'true' : 'false');
			btn.setAttribute('aria-label', label);
			btn.setAttribute('data-label', label);
			btn.setAttribute('title', label);
			const text = btn.querySelector('.halo-nav-label');
			if (text) text.textContent = collapsed ? _('Expand') : _('Collapse');
			/* on a narrow screen the rail is the only shape: nothing to toggle */
			btn.hidden = this.mqNarrow.matches;
		}
	},

	setupNavShape() {
		const btn = document.getElementById('halo-collapse');
		if (btn)
			btn.addEventListener('click', () => {
				storageSet(NAV_KEY, storageGet(NAV_KEY) === 'rail' ? null : 'rail');
				this.applyNavShape();
			});
		const listen = (mq) => {
			const fn = () => this.applyNavShape();
			if (mq.addEventListener) mq.addEventListener('change', fn);
			else if (mq.addListener) mq.addListener(fn);
		};
		listen(this.mqNarrow);
		listen(this.mqPhone);
		window.addEventListener('storage', (ev) => { if (ev.key === NAV_KEY) this.applyNavShape(); });
		this.applyNavShape();
	},

	/* ------------------------------------------------- crumbs + tabs */

	/* "Network › Interfaces › General Setup" from the dispatch path; every
	   crumb but the last is a link */
	renderCrumbs() {
		const box = document.getElementById('halo-crumbs');
		if (!box) return;

		const parts = [];
		let node = this.mode.node;

		for (let i = 1; i < this.dp.length && i <= 3 && node; i++) {
			node = node.children ? node.children[this.dp[i]] : null;
			if (!node || !node.title) break;
			parts.push({ title: _(node.title), segs: [ this.mode.name ].concat(this.dp.slice(1, i + 1)) });
		}

		if (!parts.length && L.env.nodespec && L.env.nodespec.title)
			parts.push({ title: _(L.env.nodespec.title), segs: null });

		box.textContent = '';
		parts.forEach((p, i) => {
			const last = (i === parts.length - 1);
			if (i > 0)
				box.appendChild(E('span', { 'class': 'halo-crumb-sep', 'aria-hidden': 'true' }, [ '›' ]));
			box.appendChild((last || !p.segs)
				? E('span', { 'class': 'halo-crumb halo-crumb-current', 'aria-current': 'page' }, [ p.title ])
				: E('a', { 'class': 'halo-crumb', 'href': L.url.apply(L, p.segs) }, [ p.title ]));
		});

		parts.forEach((p, i) => {
			this.trail.all.add(headingKey(p.title));
			/* the category, unless it is the page itself */
			if (i || parts.length === 1) this.trail.page.add(headingKey(p.title));
		});
	},

	/* the menu's third level (and deeper) as segmented tabs above the page */
	renderTabs() {
		const container = document.getElementById('tabmenu');
		if (!container || this.dp.length < 3) return;

		let node = this.mode.node, url = this.mode.name;
		for (let i = 1; i < 3 && node; i++) {
			node = node.children ? node.children[this.dp[i]] : null;
			url += '/' + this.dp[i];
		}
		if (!node) return;

		const render = (tree, base, level) => {
			const children = ui.menu.getChildren(tree);
			if (children.length < 2) return;

			const ul = E('ul', { 'class': 'halo-pagetabs', 'role': 'list' });
			let activeNode = null;

			children.forEach((child) => {
				const isActive = (this.dp[3 + level] == child.name);
				ul.appendChild(E('li', { 'class': isActive ? 'active' : '' }, [
					E('a', { 'href': L.url(base, child.name), 'aria-current': isActive ? 'page' : null }, [ _(child.title) ])
				]));
				if (isActive) activeNode = child;
			});

			container.appendChild(ul);
			container.hidden = false;

			if (activeNode)
				render(activeNode, base + '/' + activeNode.name, level + 1);
		};

		render(node, url, 0);
	},

	/* A heading that says what the breadcrumb already says is noise: a page
	   title (h2) equal to any crumb, a card heading (h3) equal to the page,
	   to the map's title or to its own tab. Those are hidden from view and
	   kept for screen readers. A heading with a control in it (the overview's
	   Hide / Show) is never touched. Runs again whenever LuCI redraws. */
	setupRepeats() {
		this.markRepeats();
		const view = document.getElementById('view');
		if (!view || !window.MutationObserver) return;
		let pending = false;
		new MutationObserver(() => {
			if (pending) return;
			pending = true;
			window.requestAnimationFrame(() => { pending = false; this.markRepeats(); });
		}).observe(view, { childList: true, subtree: true });
	},

	markRepeats() {
		const says = (node, key) => !!node && headingKey(node.tagName ? node.textContent : node) === key;
		document.querySelectorAll('#maincontent > h2, #view h2, #view .cbi-section > h3:first-child').forEach((h) => {
			const key = headingKey(h.textContent);
			let repeat = false;
			if (key && !h.querySelector('a, button, input, select, .label, [data-clickable], [tabindex]')) {
				if (h.tagName === 'H2')
					repeat = this.trail.all.has(key);
				else {
					const map = h.closest('.cbi-map'), pane = h.closest('[data-tab-title]');
					repeat = this.trail.page.has(key)
						|| says(map && map.querySelector(':scope > h2'), key)
						|| (!!pane && headingKey(pane.getAttribute('data-tab-title')) === key);
				}
			}
			if (h.classList.contains('halo-repeat') !== repeat)
				h.classList.toggle('halo-repeat', repeat);
		});
	},

	/* -------------------------------------------------------- theme */

	themePref() {
		const p = storageGet(THEME_KEY);
		return (p === 'light' || p === 'dark') ? p : 'auto';
	},

	applyTheme() {
		/* a pinned variant (Halo Dark / Halo Light) is the user's choice in
		   LuCI itself: the template set it and renders no toggle */
		if (this.root.hasAttribute('data-pinned')) return;

		const pref = this.themePref();
		const sysDark = !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
		const dark = (pref === 'dark') || (pref === 'auto' && sysDark);
		this.root.setAttribute('data-darkmode', dark ? 'true' : 'false');
		this.root.setAttribute('data-theme', pref);

		const btn = document.getElementById('halo-theme');
		if (btn) {
			const names = { auto: _('Automatic'), light: _('Light'), dark: _('Dark') };
			const label = '%s: %s'.format(_('Appearance'), names[pref]);
			btn.setAttribute('aria-label', label);
			btn.setAttribute('data-label', label);
			btn.setAttribute('title', label);
		}
	},

	setupTheme() {
		const btn = document.getElementById('halo-theme');
		const order = { auto: 'light', light: 'dark', dark: 'auto' };
		if (btn)
			btn.addEventListener('click', () => {
				const next = order[this.themePref()];
				storageSet(THEME_KEY, next === 'auto' ? null : next);
				this.applyTheme();
			});
		const mq = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)');
		if (mq && mq.addEventListener)
			mq.addEventListener('change', () => { if (this.themePref() === 'auto') this.applyTheme(); });
		window.addEventListener('storage', (ev) => { if (ev.key === THEME_KEY) this.applyTheme(); });
		this.applyTheme();
	},

	/* --------------------------------------------------- indicators */

	/* LuCI's indicators (Refreshing, Unsaved Changes: N, and any an app adds):
	   a count at the end of the text becomes a badge (data-count, with the
	   words in data-label), the text is the tooltip, and a clickable one is
	   reachable from the keyboard. LuCI's text node is left as it is. */
	setupIndicators() {
		const box = document.getElementById('indicators');
		if (!box) return;

		const setAttr = (el, name, value) => {
			if (value == null) { if (el.hasAttribute(name)) el.removeAttribute(name); }
			else if (el.getAttribute(name) !== value) el.setAttribute(name, value);
		};

		const pass = () => {
			box.querySelectorAll('span[data-indicator]').forEach((el) => {
				const text = (el.firstChild && el.firstChild.nodeType === 3) ? el.firstChild.data : el.textContent;
				const count = /^(.*\S)\s*:\s*(\d+)\s*$/.exec(text || '');
				setAttr(el, 'data-label', count ? count[1] : null);
				setAttr(el, 'data-count', count ? count[2] : null);
				setAttr(el, 'title', text);
				if (el.hasAttribute('data-clickable') && !el.hasAttribute('tabindex')) {
					el.setAttribute('tabindex', '0');
					el.setAttribute('role', 'button');
					el.addEventListener('keydown', (ev) => {
						if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); el.click(); }
					});
				}
			});
		};

		if (window.MutationObserver)
			new MutationObserver(pass).observe(box, { childList: true, subtree: true, characterData: true });
		pass();
	}
});
