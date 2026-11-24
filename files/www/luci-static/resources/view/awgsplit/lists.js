'use strict';
'require view';
'require form';
'require uci';
'require rpc';

var callInterfaces = rpc.declare({
	object: 'luci.awgsplit',
	method: 'interfaces',
	expect: { interfaces: [] }
});

// Готовые списки itdoginfo/allow-domains (те же, что в Podkop)
var COMMUNITY = [
	[ 'russia_inside',  'Россия внутри — заблокированное в РФ + зарубежные сервисы, блокирующие РФ-IP (для роутера в России)' ],
	[ 'russia_outside', 'Россия снаружи — российские сервисы, доступные только с РФ-IP (для роутера за границей; в зарубежный туннель не включать)' ],
	[ 'telegram',       'Telegram (домены + подсети)' ],
	[ 'meta',           'Meta: Instagram, Facebook, WhatsApp (домены + подсети)' ],
	[ 'twitter',        'Twitter / X (домены + подсети)' ],
	[ 'discord',        'Discord (домены + голосовые подсети)' ],
	[ 'youtube',        'YouTube' ],
	[ 'tiktok',         'TikTok' ],
	[ 'google_ai',      'Google AI: Gemini, AI Studio' ],
	[ 'google_play',    'Google Play' ],
	[ 'google_meet',    'Google Meet (домены + подсети)' ],
	[ 'cloudflare',     'Cloudflare (домены + подсети)' ],
	[ 'cloudfront',     'Amazon CloudFront (домены + подсети)' ],
	[ 'hdrezka',        'HDRezka' ],
	[ 'roblox',         'Roblox (домены + подсети)' ],
	[ 'digitalocean',   'DigitalOcean (домены + подсети)' ],
	[ 'hetzner',        'Hetzner (домены + подсети)' ],
	[ 'ovh',            'OVH (домены + подсети)' ],
	[ 'geoblock',       'Геоблок — сервисы, закрывшие доступ из РФ' ],
	[ 'block',          'Заблокированные в РФ (категория)' ],
	[ 'news',           'Новости' ],
	[ 'anime',          'Аниме' ],
	[ 'porn',           'Для взрослых' ],
	[ 'hodca',          'HODCA' ]
];

var RE_SECTION = /^[A-Za-z][A-Za-z0-9_]{0,23}$/;
var RE_IP4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;

function parseMark(v) {
	v = String(v == null ? '' : v).trim();
	var n = NaN;
	if (/^0x[0-9a-f]{1,8}$/i.test(v)) n = parseInt(v, 16);
	else if (/^[1-9][0-9]{0,9}$/.test(v)) n = parseInt(v, 10);
	return (n > 0 && n <= 0xffffffff) ? n : NaN;
}

function otherTunnels(section_id) {
	return uci.sections('awgsplit', 'tunnel').filter(function(s) {
		return s['.name'] !== section_id;
	});
}

function nextFree(key, parse, from, to) {
	var used = {};
	uci.sections('awgsplit', 'tunnel').forEach(function(s) { used[parse(s[key])] = true; });
	for (var i = from; i <= to; i++)
		if (!used[i]) return i;
	return from;
}

function checkSectionName(section_id) {
	return RE_SECTION.test(section_id) ? true :
		'Имя секции «' + section_id + '» не подходит: латиница, цифры и _, с буквы, до 24 символов. Удалите и создайте заново.';
}

function normDomain(d) {
	d = d.toLowerCase().replace(/^\*\./, '').replace(/^\.+/, '').replace(/\.+$/, '');
	if (!d || d.length > 253 || /[^a-z0-9.-]/.test(d)) return null;
	var labels = d.split('.');
	for (var i = 0; i < labels.length; i++)
		if (!labels[i].length || labels[i].length > 63 || /^-|-$/.test(labels[i])) return null;
	return d;
}

function domainTokens(text) {
	var out = [];
	String(text || '').split(/\n/).forEach(function(line) {
		line.replace(/#.*/, '').split(/[\s,;]+/).forEach(function(t) {
			if (t) out.push(t);
		});
	});
	return out;
}

return view.extend({
	load: function() {
		return Promise.all([
			callInterfaces().catch(function() { return []; }),
			uci.load('awgsplit'),
			uci.load('network')
		]);
	},

	render: function(data) {
		var ifaces = Array.isArray(data[0]) ? data[0] : [];
		var m, s, o;

		m = new form.Map('awgsplit', 'Списки',
			'Каждый туннель — отдельный интерфейс AmneziaWG со своей таблицей маршрутизации. ' +
			'Домены и подсети из его списков идут в этот туннель, всё остальное — напрямую через провайдера. ' +
			'Если адрес подходит нескольким туннелям, порядок такой: свои подсети → свои домены → ' +
			'домены готовых списков → подсети готовых списков; на одном уровне побеждает туннель с меньшим приоритетом. ' +
			'Более точный домен (api.example.com) всегда главнее общего (example.com).');

		// ------------------------------------------------ свои домены
		s = m.section(form.GridSection, 'domains', 'Свои списки доменов',
			'Один домен на строку (можно через пробел или запятую), # — комментарий. ' +
			'Поддомены покрываются автоматически: example.com захватит и api.example.com.');
		s.addremove = true;
		s.anonymous = false;
		s.nodescriptions = true;
		s.addbtntitle = 'Добавить список';

		o = s.option(form.Flag, 'enabled', 'Вкл');
		o.editable = true;
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'label', 'Название списка');
		o.placeholder = 'Мой список';
		o.editable = true;

		o = s.option(form.Flag, 'killswitch', 'Kill switch',
			'Трафик этих доменов не пропускается мимо туннеля: если туннель недоступен, соединения сбрасываются, а не идут напрямую.');
		o.editable = true;
		o.default = '0';
		o.rmempty = true;

		o = s.option(form.ListValue, 'tunnel', 'В какой туннель');
		o.value('', '— не назначен —');
		var tunnelNames = {};
		uci.sections('awgsplit', 'tunnel', function(sc) {
			tunnelNames[sc['.name']] = true;
			o.value(sc['.name'], sc.label || sc['.name']);
		});
		// список, привязанный к удалённому туннелю, показываем как есть — не подменяем молча первым туннелем
		uci.sections('awgsplit', 'domains', function(sc) {
			if (sc.tunnel && !tunnelNames[sc.tunnel]) {
				tunnelNames[sc.tunnel] = true;
				o.value(sc.tunnel, sc.tunnel + ' (туннель не найден)');
			}
		});
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return value ? true : 'Выберите туннель (сначала создайте его выше)';
		};

		o = s.option(form.TextValue, 'domains', 'Домены');
		o.rows = 20;
		o.wrap = 'off';
		o.modalonly = true;
		o.placeholder = 'example.com\nanother.org';
		o.validate = function(section_id, value) {
			var bad = domainTokens(value).filter(function(t) { return normDomain(t) === null; });
			if (bad.length)
				return 'Некорректные записи: ' + bad.slice(0, 3).join(', ') +
					(bad.length > 3 ? ' и ещё ' + (bad.length - 3) : '');
			return true;
		};

		o = s.option(form.DummyValue, '_count', 'Доменов');
		o.cfgvalue = function(section_id) {
			return String(domainTokens(uci.get('awgsplit', section_id, 'domains')).length);
		};

		return m.render();
	}
});
