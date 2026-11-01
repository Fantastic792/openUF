'use strict';
'require view';
'require rpc';

// The unhandled ledger (openuf/unhandled.lua, /etc/openuf/unhandled.json):
// every response type, cmd, mgmt_cfg key, setparam field and system_cfg key
// shape the controller sent that openUF does not act on. Read-only: the
// ledger has no reset, and the samples were redacted when they were recorded.
const callUnhandled = rpc.declare({
	object: 'luci.openuf',
	method: 'getUnhandled'
});

const SAMPLE_CHARS = 200;

function sample(payload) {
	if (payload == null)
		return '';
	let s;
	try {
		s = JSON.stringify(payload);
	}
	catch (e) {
		s = String(payload);
	}
	return s.length > SAMPLE_CHARS ? s.substring(0, SAMPLE_CHARS) + '…' : s;
}

return view.extend({
	load: function() {
		return callUnhandled().catch(function(e) {
			return { error: e.message };
		});
	},

	render: function(doc) {
		doc = doc || {};
		const entries = Array.isArray(doc.entries) ? doc.entries : [];
		let body;
		if (doc.error)
			body = E('p', { 'class': 'alert-message warning' },
				_('Unable to read %s: %s').format(doc.file || _('the ledger'), doc.error));
		else if (!entries.length)
			body = E('p', {}, _('Nothing unhandled'));
		else
			body = E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Category')),
					E('th', { 'class': 'th' }, _('Key')),
					E('th', { 'class': 'th' }, _('Count')),
					E('th', { 'class': 'th' }, _('First seen')),
					E('th', { 'class': 'th' }, _('Last seen')),
					E('th', { 'class': 'th' }, _('Sample'))
				])
			].concat(entries.map(function(e) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, e.category),
					E('td', { 'class': 'td' }, E('code', {}, e.key)),
					E('td', { 'class': 'td' }, String(e.count)),
					E('td', { 'class': 'td' }, e.first_seen || ''),
					E('td', { 'class': 'td' }, e.last_seen || ''),
					E('td', { 'class': 'td' }, E('code', { 'style': 'word-break:break-all' }, sample(e.payload)))
				]);
			})));

		return E('div', {}, [
			E('h2', {}, _('Unhandled messages')),
			E('p', { 'class': 'cbi-section-descr' },
				_('What the controller sent that openUF does not act on: message types, commands and configuration keys, with how often and when each arrived. Secrets in the samples were replaced when they were recorded.')),
			doc.updated ? E('p', {}, _('Ledger last written %s').format(doc.updated)) : '',
			body
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
