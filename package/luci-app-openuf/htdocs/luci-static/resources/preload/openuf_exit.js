'use strict';
'require ui';
'require baseclass';

// "Exit LuCI mode", beside LuCI's own indicators (Refreshing, Unsaved
// changes). Shown only while the browser came in through openUF's portal
// (the gate's openuf_luci cookie); it ends the LuCI session and returns to
// the portal. Without the portal LuCI looks exactly as it always did.
return baseclass.extend({
	__init__() {
		if (!/(^|;\s*)openuf_luci=\d+/.test(document.cookie))
			return;

		ui.showIndicator('openuf-exit', _('Exit LuCI mode'), function() {
			window.location.href = L.url('__openuf/lock');
		}, 'active');
	}
});
