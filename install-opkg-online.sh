#!/bin/sh
# Установка awgsplit одной командой на роутере с OpenWrt 24.10:
#
#   wget -O /tmp/awgsplit-opkg-online.sh https://raw.githubusercontent.com/cbytl/awgsplit-kroks/refs/heads/main/install-opkg-online.sh && sh /tmp/awgsplit-opkg-online.sh
#
# Скачивает архив репозитория с GitHub и запускает install.sh.
# Аргументы передаются установщику, например: sh /tmp/awgsplit-opkg-online.sh --no-deps

REPO="${AWGSPLIT_REPO:-cbytl/awgsplit-kroks}"
REF="${AWGSPLIT_REF:-main}"
TMP=/tmp/awgsplit-src

rm -rf "$TMP" && mkdir -p "$TMP" || { echo "Не смог создать $TMP"; exit 1; }

echo "Скачиваю awgsplit ($REPO, ветка $REF)..."
if ! wget -q -T 30 -O "$TMP/src.tar.gz" "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF"; then
	echo "Не скачалось. Проверьте интернет и дату на роутере (date): при неверном времени HTTPS не работает."
	exit 1
fi

if ! tar -xzf "$TMP/src.tar.gz" -C "$TMP" 2>/dev/null; then
	gzip -dc "$TMP/src.tar.gz" | tar -xf - -C "$TMP" || { echo "Не смог распаковать архив"; exit 1; }
fi

dir=$(find "$TMP" -maxdepth 2 -type f -name install-opkg.sh | head -1)
dir=${dir%/install-opkg.sh}
[ -n "$dir" ] && [ -f "$dir/files/usr/bin/awgsplit" ] || { echo "В архиве нет установщика"; exit 1; }

cd "$dir" && sh ./install-opkg.sh "$@"
