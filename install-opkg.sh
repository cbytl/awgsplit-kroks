#!/bin/sh
# Установщик awgsplit под opkg (Kroks KNdRt41R1 OpenWrt 24.10).
# Запускать НА РОУТЕРЕ из распакованной папки.
#   ./install-opkg.sh            — полная установка
#   ./install-opkg.sh --no-deps  — только файлы, без установки пакетов

cd "$(dirname "$0")" || exit 1

# Управляет цветным выводом сообщений в терминале.
RED=''; GREEN=''; YELL=''; CYAN=''; NC=''

if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELL='\033[0;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
fi

# Набор вспомогательных функций для вывода сообщений установщика
ok()   { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn() { printf "${YELL}[!!!]${NC}   %s\n" "$*"; }
err()  { printf "${RED}[ERR]${NC}   %s\n" "$*"; }
info() { printf "${CYAN}[INFO]${NC}    %s\n" "$*"; }
step() { printf "\n${CYAN}=== %s ===${NC}\n" "$*"; }
die()  { err "$*"; exit 1; }

NODEPS=0
[ "$1" = "--no-deps" ] && NODEPS=1

# Выполняем предварительную проверку системы перед установкой.
[ -f /etc/openwrt_release ] || die "Это не OpenWrt"
. /etc/openwrt_release
ok "OpenWrt $DISTRIB_RELEASE / $DISTRIB_TARGET"
command -v opkg >/dev/null 2>&1 || die "opkg не найден: эта версия установщика для OpenWrt 24.10"
[ -f files/usr/bin/awgsplit ] || die "Запускайте install.sh из распакованной папки awgsplit"

# Задаём постоянный каталог для резервных копий
BK="/root/awgsplit-backup"
mkdir -p "$BK" || die "Не удалось создать каталог резервных копий $BK"

# opkg: список установленных в виде «имя версия», ищем точное имя пакета
pkg_installed() { opkg list-installed 2>/dev/null | grep -q "^$1 "; }

# Функция ask_yn() запрашивает у пользователя ответ «да/нет» и возвращает код завершения в зависимости от ответа.
ask_yn() {
    printf "%s [y/N]: " "$1"
    while true; do
        read -r answer || { echo; return 1; }
        answer=$(printf '%s' "$answer" | tr 'A-Z' 'a-z')

        [ -z "$answer" ] && return 1

        case "$answer" in
            y|yes|да) return 0 ;;
            n|no|нет) return 1 ;;
            *) printf "Ответьте y или n: " ;;
        esac
    done
}

#--------------------------------------------------------------------------------------------------------
if [ "$NODEPS" = 0 ]; then
	
	step "opkg update — обновляем списки доступных пакетов. Это займет некоторое время. Подождите....."
		opkg update || die "opkg update прошёл с ошибками — пробую дальше"
	
	step "dnsmasq-full"
	DHCP="/etc/config/dhcp"
	DHCP_BAK="${BK}/dhcp.before-dnsmasq-full"
	DNS="/etc/resolv.conf"
	DNS_BAK="${BK}/dns.before-dnsmasq-full"
	# Проверяем, установлен ли dnsmasq-full
	if opkg list-installed 2>/dev/null | grep -q '^dnsmasq-full '; then
	    ok "dnsmasq-full уже установлен"
	else
    	# Сохраняем конфигурацию DHCP
    	[ -f "${DHCP}" ] || die "Не найден файл ${DHCP}"
   		cp -p "${DHCP}" "${DHCP_BAK}" || die "Не удалось сохранить конфигурацию DHCP"
		ok "Конфигурация DHCP сохранена: ${DHCP_BAK}"
    	# Сохраняем конфигурацию DNS
    	[ -f "${DNS}" ] || die "Не найден файл ${DNS}"
   		cp -p "${DNS}" "${DNS_BAK}" || die "Не удалось сохранить конфигурацию DNS"
		ok "Конфигурация DNS сохранена: ${DNS_BAK}"
	    # Запоминаем, был ли установлен обычный dnsmasq
 	   	DNSMASQ_OLD=0
 	   	if opkg list-installed 2>/dev/null | grep -q '^dnsmasq '; then
  	      	DNSMASQ_OLD=1
 	   	fi
	    # Заранее загружаем dnsmasq-full и его зависимости
 	   	if ! opkg install --download-only dnsmasq-full; then
        	die "Не удалось загрузить dnsmasq-full и его зависимости"
 	   	fi
 	   	# Удаляем обычный dnsmasq, если он установлен
 	   	if [ "${DNSMASQ_OLD}" -eq 1 ]; then
  	    	if ! opkg remove dnsmasq; then
	        	die "Не удалось удалить обычный dnsmasq"
 	       	fi
	    fi
	    # Устанавливаем dnsmasq-full
	    if opkg install dnsmasq-full && opkg list-installed 2>/dev/null | grep -q '^dnsmasq-full '; then
	    	# Восстанавливаем конфигурацию DHCP
	        cp -p "${DHCP_BAK}" "${DHCP}" || die "dnsmasq-full установлен, но не удалось восстановить DHCP"
			# Восстанавливаем конфигурацию DNS
	        cp -p "${DNS_BAK}" "${DNS}" || die "dnsmasq-full установлен, но не удалось восстановить DNS"
	        if /etc/init.d/dnsmasq restart; then
	            ok "dnsmasq-full успешно установлен и запущен"
			else
				warn "dnsmasq-full установлен, но служба не перезапустилась"
			fi
		else
	        err "Не удалось установить dnsmasq-full"
			# Возвращаем обычный dnsmasq, если он был установлен изначально
    	    if [ "${DNSMASQ_OLD}" -eq 1 ]; then
				warn "Пытаюсь восстановить обычный dnsmasq"
	   	        if opkg install dnsmasq; then
					if cp -p "${DHCP_BAK}" "${DHCP}" && cp -p "${DNS_BAK}" "${DNS}" && /etc/init.d/dnsmasq restart; then
						ok "Обычный dnsmasq восстановлен"
					else
						err "dnsmasq установлен, но восстановление конфигурации или запуск не удались"
    				fi
				else
        	        err "Не удалось восстановить обычный dnsmasq"
				fi
			fi
	        die "Замена dnsmasq на dnsmasq-full не выполнена"
	    fi
	fi

	# Проверяем наличие nftables и при необходимости устанавливаем пакет.
	step "nftables"
	if command -v nft >/dev/null 2>&1; then ok "nftables есть"
	elif opkg install nftables >/dev/null 2>&1; then ok "nftables поставлен"
	else die "Нет nftables и не смог его поставить"; fi

	# conntrack: при переключении туннеля сбрасываем соединения сразу
	# Проверяем наличие conntrack и при необходимости устанавливаем пакет.
	step "conntrack"
	if command -v conntrack >/dev/null 2>&1; then ok "conntrack есть"
	elif opkg install conntrack >/dev/null 2>&1; then ok "conntrack поставлен"
	else warn "Не смог поставить conntrack — не страшно, при переключении туннеля соединения переподключатся чуть дольше"; fi

	# Проверяем наличие AmneziaWG и при необходимости устанавливаем.
	step "AmneziaWG"
	info "https://2grey.github.io/awg-openwrt/${DISTRIB_RELEASE}/${DISTRIB_TARGET}"
	if ask_yn "Установить AmneziaWG? "; then
		CF=/etc/opkg/customfeeds.conf
		# Формируем адрес репозитория с учётом версии OpenWrt и целевой платформы.
		FEED="https://2grey.github.io/awg-openwrt/${DISTRIB_RELEASE}/${DISTRIB_TARGET}"
		# Проверяем, существует ли файл и есть ли в нём строка с адресом репозитория 2Grey.
		if [ -f "$CF" ] && grep -q '2grey\.github\.io/awg-openwrt' "$CF"; then
  			# Удаляем все строки, содержащие этот адрес.
			sed -i '\#2grey\.github\.io/awg-openwrt#d' "$CF" ||
     		    die "Не удалось удалить старый фид AmneziaWG"
		fi
		#--------------------------------------------------------------------------------------------------------
		# Формируем адрес репозитория и добавляем его в конец файла, не удаляя существующие записи.
		printf 'src/gz awg %s\n' "$FEED" >> "$CF" ||
   		    die "Не удалось добавить фид AmneziaWG"
		ok "Фид AmneziaWG добавлен для OpenWrt $DISTRIB_RELEASE"
  		#--------------------------------------------------------------------------------------------------------
		# Добавления ключа
		if wget -q -O /tmp/awg-openwrt-feed.pub "https://2grey.github.io/awg-openwrt/keys/awg-openwrt-feed.pub"; then
			[ -s /tmp/awg-openwrt-feed.pub ] || die "Скачанный ключ AmneziaWG пустой"
			if opkg-key add /tmp/awg-openwrt-feed.pub; then
       			ok "Ключ репозитория AmneziaWG добавлен"
   			else
       			rm -f /tmp/awg-openwrt-feed.pub
       			die "Не удалось добавить ключ репозитория AmneziaWG"
   			fi
			rm -f /tmp/awg-openwrt-feed.pub
		else
			die "Не скачался ключ фида 2Grey — проверьте интернет. Инструкция: https://github.com/2Grey/awg-openwrt"
		fi
		#--------------------------------------------------------------------------------------------------------
		if [ -f /lib/netifd/proto/amneziawg.sh ] && [ -x /usr/bin/awg ]; then
			ok "AmneziaWG уже установлен ($(opkg list-installed 2>/dev/null | grep '^amneziawg-tools ' | cut -d' ' -f2))"
		elif [ -f /lib/netifd/proto/amneziawg3.sh ]; then
			ok "Найден amneziawg3 — буду использовать его"
		else
			warn "Ставлю AmneziaWG из фида 2Grey/awg-openwrt"
			if ! opkg update > /tmp/awgsplit-awg.log 2>&1; then
        		cat /tmp/awgsplit-awg.log
        		die "Не удалось обновить списки пакетов"
    		fi
			if opkg install amneziawg-tools kmod-amneziawg luci-proto-amneziawg >> /tmp/awgsplit-awg.log 2>&1; then
        		ok "Пакеты AmneziaWG установлены"
				opkg install luci-i18n-amneziawg-ru >/dev/null 2>&1
				warn "После установки нужна перезагрузка роутера, чтобы сеть узнала новый протокол"
				NEED_REBOOT=1
    		else
				warn "Нет пакетов под ${DISTRIB_RELEASE}/${DISTRIB_TARGET}?"
				warn "Инструкция: https://github.com/2Grey/awg-openwrt"
				cat /tmp/awgsplit-awg.log
        		die "Не удалось установить пакеты AmneziaWG"
    		fi
			tail -5 /tmp/awgsplit-awg.log
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
	if /etc/init.d/awgsplit start; then
    	ok "awgsplit запущен"
	else
    	die "Не удалось запустить awgsplit"
	fi
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
