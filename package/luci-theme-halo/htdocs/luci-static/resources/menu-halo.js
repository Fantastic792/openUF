'use strict';
'require baseclass';
'require ui';

/*
 * Halo's navigation: LuCI's menu tree as a sidebar.
 *
 *   level 1 (Status, System, Network...)  a group in the sidebar, with an icon
 *   level 2 (Overview, Interfaces...)     a link inside its group
 *   level 3 and deeper                    tabs above the page (#tabmenu), as
 *                                         luci-theme-bootstrap renders them
 *
 * A level-1 entry without children (Log out) is a plain link; "logout"
 * goes to the foot of the sidebar. Which groups are open is remembered in
 * localStorage, per browser; the active one is always open.
 */

const ICONS = [ 'status', 'system', 'services', 'network', 'vpn', 'statistics', 'nas', 'docker', 'logout' ];
const OPEN_KEY = 'halo.nav.open';

function readOpen() {
	try { return JSON.parse(localStorage.getItem(OPEN_KEY) || '[]') || []; }
	catch (e) { return []; }
}

function writeOpen(list) {
	try { localStorage.setItem(OPEN_KEY, JSON.stringify(list)); }
	catch (e) { /* private mode: not remembered, still works */ }
}

function icon(name) {
	return E('span', {
		'class': 'halo-icon',
		'data-icon': ICONS.indexOf(name) > -1 ? name : null,
		'aria-hidden': 'true'
	});
}

return baseclass.extend({
	__init__() {
		this.bindDrawer();
		ui.menu.load().then((tree) => this.render(tree));
	},

	render(tree) {
		const mode = this.renderModeMenu(tree);

		if (mode) {
			this.renderSidebar(mode.node, mode.name);
			this.renderCrumbs(mode.node, mode.name);
		}

		let node = tree;
		let url = '';

		if (L.env.dispatchpath.length >= 3) {
			for (let i = 0; i < 3 && node; i++) {
				node = node.children[L.env.dispatchpath[i]];
				url = url + (url ? '/' : '') + L.env.dispatchpath[i];
			}

			if (node)
				this.renderTabMenu(node, url);
		}
	},

	/* The top level of the tree is the mode (normally just "admin"). */
	renderModeMenu(tree) {
		const ul = document.querySelector('#modemenu');
		const children = ui.menu.getChildren(tree);
		let active = null;

		children.forEach((child, index) => {
			const isActive = L.env.requestpath.length
				? child.name === L.env.requestpath[0]
				: index === 0;

			ul.appendChild(E('li', { 'class': isActive ? 'active' : '' }, [
				E('a', { 'href': L.url(child.name) }, [ _(child.title) ])
			]));

			if (isActive)
				active = { node: child, name: child.name };
		});

		if (ul.children.length > 1)
			ul.style.display = '';

		return active;
	},

	renderSidebar(modeNode, modeName) {
		const nav = document.querySelector('#topmenu');
		const foot = document.querySelector('#halo-sidebar-foot');
		const remembered = readOpen();
		const activeCat = L.env.dispatchpath[1];
		const activePage = L.env.dispatchpath[2];

		ui.menu.getChildren(modeNode).forEach((cat) => {
			const pages = ui.menu.getChildren(cat);
			const catUrl = L.url(modeName, cat.name);

			if (!pages.length) {
				const link = E('a', {
					'class': 'halo-link' + (cat.name === activeCat ? ' active' : ''),
					'href': catUrl,
					'data-name': cat.name
				}, [ icon(cat.name), E('span', { 'class': 'label-text' }, [ _(cat.title) ]) ]);

				if (cat.name === 'logout')
					foot.appendChild(link);
				else
					nav.appendChild(E('li', { 'class': 'halo-group' }, [ link ]));

				return;
			}

			const isActive = (cat.name === activeCat);
			const open = isActive || remembered.indexOf(cat.name) > -1;
			const sub = E('ul', { 'class': 'halo-sub', 'id': 'halo-sub-' + cat.name });

			pages.forEach((page) => {
				sub.appendChild(E('li', { 'class': (isActive && page.name === activePage) ? 'active' : '' }, [
					E('a', {
						'href': L.url(modeName, cat.name, page.name),
						'aria-current': (isActive && page.name === activePage) ? 'page' : null
					}, [ _(page.title) ])
				]));
			});

			const head = E('button', {
				'class': 'halo-group-head',
				'type': 'button',
				'aria-expanded': open ? 'true' : 'false',
				'aria-controls': 'halo-sub-' + cat.name
			}, [
				icon(cat.name),
				E('span', { 'class': 'label-text' }, [ _(cat.title) ]),
				E('span', { 'class': 'halo-chevron', 'aria-hidden': 'true' })
			]);

			const group = E('li', {
				'class': 'halo-group' + (open ? ' open' : '') + (isActive ? ' active' : ''),
				'data-name': cat.name
			}, [ head, sub ]);

			head.addEventListener('click', () => {
				const nowOpen = !group.classList.contains('open');
				group.classList.toggle('open', nowOpen);
				head.setAttribute('aria-expanded', nowOpen ? 'true' : 'false');

				const list = readOpen().filter((n) => n !== cat.name);
				if (nowOpen)
					list.push(cat.name);
				writeOpen(list);
			});

			nav.appendChild(group);
		});

		nav.style.display = '';

		/* keep the current page in view in a long menu */
		const current = nav.querySelector('.halo-sub li.active > a');
		if (current && current.scrollIntoView)
			current.scrollIntoView({ block: 'nearest' });
	},

	/* "Network › Interfaces › General Setup", from the dispatch path. */
	renderCrumbs(modeNode, modeName) {
		const box = document.querySelector('#halo-crumbs');
		const path = L.env.dispatchpath;
		const parts = [];
		let node = modeNode;

		for (let i = 1; i < path.length && node; i++) {
			node = node.children ? node.children[path[i]] : null;
			if (node && node.title)
				parts.push({ title: _(node.title), url: L.url.apply(L, path.slice(0, i + 1)) });
		}

		if (!parts.length && L.env.nodespec && L.env.nodespec.title)
			parts.push({ title: _(L.env.nodespec.title) });

		parts.forEach((p, i) => {
			const last = (i === parts.length - 1);

			if (i > 0)
				box.appendChild(E('span', { 'class': 'sep', 'aria-hidden': 'true' }, [ '›' ]));

			box.appendChild(last
				? E('span', { 'class': 'current', 'aria-current': 'page' }, [ p.title ])
				: E('a', { 'class': 'crumb-parent', 'href': p.url, 'style': 'color:inherit' }, [ p.title ]));
		});
	},

	renderTabMenu(tree, url, level) {
		const container = document.querySelector('#tabmenu');
		const ul = E('ul', { 'class': 'tabs' });
		const children = ui.menu.getChildren(tree);
		let activeNode = null;

		children.forEach((child) => {
			const isActive = (L.env.dispatchpath[3 + (level || 0)] == child.name);

			ul.appendChild(E('li', { 'class': 'tabmenu-item-%s%s'.format(child.name, isActive ? ' active' : '') }, [
				E('a', { 'href': L.url(url, child.name) }, [ _(child.title) ])
			]));

			if (isActive)
				activeNode = child;
		});

		if (ul.children.length == 0)
			return E([]);

		container.appendChild(ul);
		container.style.display = '';

		if (activeNode)
			this.renderTabMenu(activeNode, url + '/' + activeNode.name, (level || 0) + 1);

		return ul;
	},

	/* The sidebar is a drawer on narrow screens. */
	bindDrawer() {
		const body = document.body;
		const burger = document.querySelector('#halo-burger');
		const scrim = document.querySelector('#halo-scrim');
		const sidebar = document.querySelector('#halo-sidebar');

		if (!burger || !sidebar)
			return;

		const set = (open) => {
			body.classList.toggle('halo-nav-open', open);
			burger.setAttribute('aria-expanded', open ? 'true' : 'false');
		};

		burger.addEventListener('click', () => set(!body.classList.contains('halo-nav-open')));

		if (scrim)
			scrim.addEventListener('click', () => set(false));

		document.addEventListener('keydown', (ev) => {
			if (ev.key === 'Escape' && body.classList.contains('halo-nav-open'))
				set(false);
		});

		sidebar.addEventListener('click', (ev) => {
			if (ev.target.closest && ev.target.closest('a[href]'))
				set(false);
		});
	}
});
