#!/bin/sh
# Установщик awgsplit под opkg (OpenWrt 24.10).
# Запускать НА РОУТЕРЕ из распакованной папки.
#   ./install-opkg.sh            — полная установка
#   ./install-opkg.sh --no-deps  — только файлы, без установки пакетов

cd "$(dirname "$0")" || exit 1

GREEN=''; RED=''; YELL=''; NC=''
if [ -t 1 ]; then
	GREEN='\033[0;32m'; RED='\033[0;31m'; YELL='\033[0;33m'; NC='\033[0m'
fi
ok()   { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
warn() { printf "${YELL}[!!]${NC}   %s\n" "$*"; }
err()  { printf "${RED}[ERR]${NC}  %s\n" "$*"; }
step() { printf "\n=== %s ===\n" "$*"; }
die()  { err "$*"; exit 1; }

NODEPS=0
[ "$1" = "--no-deps" ] && NODEPS=1

[ -f /etc/openwrt_release ] || die "Это не OpenWrt"
. /etc/openwrt_release
ok "OpenWrt $DISTRIB_RELEASE / $DISTRIB_TARGET"
command -v opkg >/dev/null 2>&1 || die "opkg не найден: эта версия установщика для OpenWrt 24.10"
[ -f files/usr/bin/awgsplit ] || die "Запускайте install.sh из распакованной папки awgsplit"

# Задаём постоянный каталог для резервных копий
BK=/root/awgsplit-backup
mkdir -p "$BK" || die "Не удалось создать каталог резервных копий $BK"

# Функция has_nftset() проверяет, поддерживает ли установленный dnsmasq функцию nftset.
has_nftset() {
	case " $(dnsmasq --version 2>/dev/null | sed -n 's/^Compile time options: //p') " in
		*" nftset "*) return 0 ;;
	esac
	return 1
}

# opkg: список установленных в виде «имя версия», ищем точное имя пакета
pkg_installed() { opkg list-installed 2>/dev/null | grep -q "^$1 "; }

# Функция ask_yn() запрашивает у пользователя ответ «да/нет» и возвращает код завершения в зависимости от ответа.
ask_yn() {
    printf "%s [y/n]: " "$1"
    while true; do
        read -r answer || { echo; return 1; }
        answer=$(printf '%s' "$answer" | tr 'A-Z' 'a-z')
        case "$answer" in
            y|yes|да) return 0 ;;
            n|no|нет) return 1 ;;
            *) printf "Ответьте y или n: " ;;
        esac
    done
}



if [ "$NODEPS" = 0 ]; then

	step "dnsmasq-full"
	if has_nftset; then
		ok "dnsmasq уже умеет nftset"
	else
		warn "Меняю dnsmasq на dnsmasq-full (настройки DHCP/DNS сохраняются)"
		cp /etc/config/dhcp "$BK/dhcp" || die "Не смог сохранить /etc/config/dhcp"
		RB=/tmp/awgsplit-rollback
		rm -rf "$RB"; mkdir -p "$RB"
		opkg update >/dev/null 2>&1 || warn "opkg update прошёл с ошибками — пробую дальше"
		# копия старого dnsmasq для отката — ДО удаления (opkg download кладёт .ipk в текущий каталог)
		( cd "$RB" && opkg download dnsmasq >/dev/null 2>&1 ) || warn "Не смог сохранить копию dnsmasq для отката"
		# dnsmasq-full конфликтует с dnsmasq, поэтому сносим старый и ставим новый
		# на время замены DNS у роутера нет — подменяем резолвер на внешний
		cp /etc/resolv.conf "$BK/resolv.conf"
		opkg remove dnsmasq > "$RB/log" 2>&1
		echo "nameserver 8.8.8.8" > /etc/resolv.conf
		opkg install dnsmasq-full >> "$RB/log" 2>&1
		# восстанавливаем — dnsmasq-full подхватит свои настройки
		cp "$BK/resolv.conf" /etc/resolv.conf
		tail -5 "$RB/log"
		if pkg_installed dnsmasq-full && has_nftset; then
			cp "$BK/dhcp" /etc/config/dhcp
			/etc/init.d/dnsmasq restart >/dev/null 2>&1
			ok "dnsmasq-full установлен"
		else
			err "dnsmasq-full не встал — откатываю"
			pkg_installed dnsmasq-full && opkg remove dnsmasq-full >/dev/null 2>&1
			if ! pkg_installed dnsmasq; then
				ls "$RB"/dnsmasq_*.ipk >/dev/null 2>&1 && opkg install "$RB"/dnsmasq_*.ipk >/dev/null 2>&1
			fi
			cp "$BK/dhcp" /etc/config/dhcp
			/etc/init.d/dnsmasq enable >/dev/null 2>&1
			/etc/init.d/dnsmasq restart >/dev/null 2>&1
			pkg_installed dnsmasq || pkg_installed dnsmasq-full \
				|| err "dnsmasq не установлен! Верните его: opkg install dnsmasq"
			die "Установка остановлена. Лог opkg: $RB/log"
		fi
	fi

	step "nftables"
	if command -v nft >/dev/null 2>&1; then ok "nftables есть"
	elif opkg install nftables >/dev/null 2>&1; then ok "nftables поставлен"
	else die "Нет nftables и не смог его поставить"; fi

	# conntrack: при переключении туннеля сбрасываем соединения сразу
	if command -v conntrack >/dev/null 2>&1; then ok "conntrack есть"
	elif opkg install conntrack >/dev/null 2>&1; then ok "conntrack поставлен"
	else warn "Не смог поставить conntrack — не страшно, при переключении туннеля соединения переподключатся чуть дольше"; fi

	step "AmneziaWG"

	if ask_yn "Установить AmneziaWG? "; then

		# ---------------------------------------------------------------- зависимости
		CF=/etc/opkg/customfeeds.conf
		FEED="https://2grey.github.io/awg-openwrt/${DISTRIB_RELEASE}/${DISTRIB_TARGET}/packages"
		# после sysupgrade в фиде 2Grey может остаться старая версия OpenWrt — чиним
		if [ -f "$CF" ] && grep -q '2grey\.github\.io/awg-openwrt' "$CF"; then
			sed -i '\#2grey\.github\.io/awg-openwrt#d' "$CF"
		fi
		echo "src/gz awg-openwrt ${FEED}" >> "$CF"
		ok "Фид AmneziaWG добавлен для $DISTRIB_RELEASE"

		if [ -f /lib/netifd/proto/amneziawg.sh ] && [ -x /usr/bin/awg ]; then
			ok "AmneziaWG уже установлен ($(opkg list-installed 2>/dev/null | grep '^amneziawg-tools ' | cut -d' ' -f2))"
		elif [ -f /lib/netifd/proto/amneziawg3.sh ]; then
			ok "Найден amneziawg3 — буду использовать его"
		else
			warn "Ставлю AmneziaWG из фида 2Grey/awg-openwrt"
			mkdir -p /etc/opkg/keys
			# usign-ключ фида: имя файла — ID ключа (проверьте на странице репозитория)
			if wget -q -O /etc/opkg/keys/5f90c8b31e6d4c5f https://2grey.github.io/awg-openwrt/keys/awg-openwrt-feed.pub; then
				opkg update > /tmp/awgsplit-awg.log 2>&1
				opkg install kmod-amneziawg amneziawg-tools luci-proto-amneziawg >> /tmp/awgsplit-awg.log 2>&1
				tail -5 /tmp/awgsplit-awg.log
				if pkg_installed kmod-amneziawg && pkg_installed amneziawg-tools; then
					opkg install luci-i18n-amneziawg-ru >/dev/null 2>&1
					ok "AmneziaWG установлен"
					warn "После установки нужна перезагрузка роутера, чтобы сеть узнала новый протокол"
					NEED_REBOOT=1
				else
					warn "Не получилось поставить AmneziaWG (нет пакетов под $DISTRIB_RELEASE/$DISTRIB_TARGET?)"
					warn "Инструкция: https://github.com/2Grey/awg-openwrt"
				fi
			else
				warn "Не скачался ключ фида 2Grey — проверьте интернет. Инструкция: https://github.com/2Grey/awg-openwrt"
			fi
		fi

	else
		echo "без AmneziaWG"
	fi

fi

# ---------------------------------------------------------------- файлы
step "Копирую файлы"

put() { # mode src dst — атомарно, без утилиты install (её нет в BusyBox)
	mkdir -p "${3%/*}" && cp "$2" "$3.awgnew" && sed -i 's/\r$//' "$3.awgnew" \
		&& chmod "$1" "$3.awgnew" && mv -f "$3.awgnew" "$3" || die "Не смог записать $3"
}

put 0755 files/usr/bin/awgsplit                  /usr/bin/awgsplit
put 0755 files/etc/init.d/awgsplit               /etc/init.d/awgsplit
put 0755 files/usr/share/awgsplit/import-awg.sh  /usr/share/awgsplit/import-awg.sh
put 0755 files/usr/libexec/rpcd/luci.awgsplit    /usr/libexec/rpcd/luci.awgsplit
put 0644 files/usr/share/rpcd/acl.d/luci-app-awgsplit.json /usr/share/rpcd/acl.d/luci-app-awgsplit.json
put 0644 files/usr/share/luci/menu.d/luci-app-awgsplit.json /usr/share/luci/menu.d/luci-app-awgsplit.json
for f in overview tunnels import diag; do
	put 0644 "files/www/luci-static/resources/view/awgsplit/$f.js" "/www/luci-static/resources/view/awgsplit/$f.js"
done
put 0644 files/www/awgsplit-down.html            /www/awgsplit-down.html
put 0755 files/www/cgi-bin/awgsplit-state        /www/cgi-bin/awgsplit-state
if [ -z "$(uci -q get uhttpd.main.error_page)" ]; then
	uci -q set uhttpd.main.error_page='/awgsplit-down.html' && uci -q commit uhttpd \
		&& /etc/init.d/uhttpd reload >/dev/null 2>&1 && ok "uhttpd: страница 404 → /awgsplit-down.html"
fi
[ -f README.md ] && put 0644 README.md /usr/share/awgsplit/README
mkdir -p /usr/share/awgsplit/lists
ok "Файлы скопированы"

if [ -f /etc/config/awgsplit ]; then
	cp /etc/config/awgsplit "$BK/awgsplit.$(date +%Y%m%d-%H%M%S)"
	ok "Ваш /etc/config/awgsplit оставлен как есть (копия в $BK)"
else
	put 0644 files/etc/config/awgsplit /etc/config/awgsplit
	ok "Установлен стартовый /etc/config/awgsplit (ваши домены уже внутри)"
fi

grep -qx '/etc/config/awgsplit' /etc/sysupgrade.conf 2>/dev/null || echo '/etc/config/awgsplit' >> /etc/sysupgrade.conf

/etc/init.d/rpcd restart >/dev/null 2>&1 && ok "rpcd перезапущен"
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
ok "Кэш LuCI сброшен"

# ---------------------------------------------------------------- списки
step "Качаю списки доменов"
if /usr/bin/awgsplit update; then
	ok "Списки скачаны"
else
	warn "Часть списков не скачалась: $(cat /usr/share/awgsplit/lists/.failed 2>/dev/null)"
	warn "Служба докачает их сама, когда появится интернет"
fi

# ---------------------------------------------------------------- запуск
step "Запуск"
	D='dhcp.@dnsmasq[0]'
	if uci -q get "$D.server" | grep -q '127\.0\.0\.42'; then
		cp /etc/config/dhcp "$BK/dhcp.podkop"
		uci -q del_list "$D.server=127.0.0.42#53"
		uci -q del_list "$D.server=127.0.0.42"
		for v in $(uci -q get "$D.podkop_server"); do uci -q add_list "$D.server=$v"; done
		v=$(uci -q get "$D.podkop_noresolv"); uci -q set "$D.noresolv=${v:-0}"
		v=$(uci -q get "$D.podkop_cachesize"); [ -n "$v" ] && uci -q set "$D.cachesize=$v"
		uci -q delete "$D.podkop_server"; uci -q delete "$D.podkop_noresolv"; uci -q delete "$D.podkop_cachesize"
		uci commit dhcp
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
		warn "Убрал из dnsmasq остатки Podkop (сервер 127.0.0.42), копия dhcp в $BK"
	fi
	/etc/init.d/awgsplit enable && ok "Автозапуск включён"
	/etc/init.d/awgsplit stop >/dev/null 2>&1
	/etc/init.d/awgsplit start && ok "awgsplit запущен"

step "Готово"
cat <<EOF

Дальше:
  1. LuCI: Сервисы → AWG Split → «Импорт конфига»: загрузите .conf от AmneziaVPN,
     имя интерфейса awg_main (для второго сервера — awg_second)
  2. «Туннели и списки»: проверьте туннель, списки, свои домены → «Сохранить и применить»
  3. «Обзор»: связь туннеля должна стать «Работает»

Проверка из SSH:  awgsplit status   /   awgsplit dump main
EOF
[ "$NEED_REBOOT" = 1 ] && warn "Не забудьте перезагрузить роутер после установки AmneziaWG: reboot"
exit 0
