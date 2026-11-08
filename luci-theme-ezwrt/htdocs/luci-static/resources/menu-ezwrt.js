'use strict';
'require baseclass';
'require ui';

return baseclass.extend({
	__init__: function() {
		var toggle = document.querySelector('.ez-menu-toggle');
		var sidebar = document.getElementById('ez-sidebar');
		var close = function() {
			document.body.classList.remove('ez-menu-open');
			toggle.setAttribute('aria-expanded', 'false');
		};
		if (toggle && sidebar) {
			toggle.addEventListener('click', function() {
				var open = document.body.classList.toggle('ez-menu-open');
				toggle.setAttribute('aria-expanded', String(open));
			});
			document.addEventListener('keydown', function(event) {
				if (event.key === 'Escape' && document.body.classList.contains('ez-menu-open')) {
					close();
					toggle.focus();
				}
			});
			document.addEventListener('click', function(event) {
				if (!sidebar.contains(event.target) && !toggle.contains(event.target))
					close();
			});
		}
		return ui.menu.load().then(this.render.bind(this));
	},

	render: function(tree) {
		var path = L.env.dispatchpath;
		var modes = ui.menu.getChildren(tree);
		var mode = modes.filter(function(child) { return child.name === path[0]; })[0] || modes[0];
		if (!mode)
			return;

		var menu = document.getElementById('topmenu');
		var symbols = { status: '◫', system: '⚙', services: '◇', network: '⇄', logout: '↗' };
		ui.menu.getChildren(mode).forEach(function(group) {
			var active = path[1] === group.name;
			var children = ui.menu.getChildren(group);
			var label = [E('span', { 'class': 'ez-nav-icon', 'aria-hidden': 'true' }, symbols[group.name] || '·'), _(group.title)];
			if (!children.length) {
				menu.appendChild(E('li', {}, E('a', {
					'href': L.url(mode.name, group.name),
					'aria-current': active ? 'page' : null
				}, label)));
				return;
			}
			var list = E('ul', { 'class': 'ez-submenu' });
			children.forEach(function(child) {
				var selected = active && path[2] === child.name;
				list.appendChild(E('li', {}, E('a', {
					'href': L.url(mode.name, group.name, child.name),
					'aria-current': selected ? 'page' : null
				}, _(child.title))));
			});
			menu.appendChild(E('li', {}, E('details', {
				'open': active ? '' : null,
				'class': active ? 'ez-active-group' : ''
			}, [E('summary', {}, label), list])));
		});

		var modeMenu = document.getElementById('modemenu');
		modes.forEach(function(child) {
			modeMenu.appendChild(E('li', {}, E('a', { 'href': L.url(child.name) }, _(child.title))));
		});
		if (modes.length > 1)
			modeMenu.style.display = '';

		var node = tree;
		for (var i = 0; i < 3 && node; i++)
			node = node.children && node.children[path[i]];
		if (node)
			this.renderTabs(node, path.slice(0, 3), 3);
	},

	renderTabs: function(tree, path, depth) {
		var children = ui.menu.getChildren(tree);
		if (!children.length)
			return;
		var tabs = E('ul', { 'class': 'tabs' });
		var active;
		children.forEach(function(child) {
			var selected = L.env.dispatchpath[depth] === child.name;
			tabs.appendChild(E('li', { 'class': selected ? 'active' : '' }, E('a', {
				'href': L.url.apply(L, path.concat(child.name)),
				'aria-current': selected ? 'page' : null
			}, _(child.title))));
			if (selected)
				active = child;
		});
		var container = document.getElementById('tabmenu');
		container.appendChild(tabs);
		container.style.display = '';
		if (active)
			this.renderTabs(active, path.concat(active.name), depth + 1);
	}
});
