#!/bin/sh
# Сборка статического curl с HTTP/3 (OpenSSL native QUIC + nghttp3, musl).
#
# usage: build.sh <arch>
#   arch ∈ x86_64 i686 aarch64 arm mipsel mipssf riscv64
#
# Результат: dist/z2r-curl-h3-linux-<arch>.gz
#   бинарник strip + upx --best --lzma (если upx доступен и поддержал arch,
#   иначе без упаковки — это норма) + gzip -9.
#
# Имена arch совпадают с контрактом затора (lib/quic_media.sh: asset
# z2r-curl-h3-linux-<arch>.gz, детект z2r_quic_curl_arch).
#
# Тулчейны musl.cc (soft-float MIPS, см. таблицу в README). OpenSSL
# собирается с CC из тулчейна — cross-compile-prefix НЕ дублируется.
set -eu

ARCH=${1:?usage: build.sh <arch> (x86_64 i686 aarch64 arm mipsel mipssf riscv64)}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)   # build.sh живёт в корне репо
WORK=${Z2R_CURL_BUILD_DIR:-$ROOT/.build}/$ARCH   # per-arch: CI гонит 7 джоб параллельно
OUT=$ROOT/dist
NPROC=$(nproc 2>/dev/null || echo 2)

V_OPENSSL=${V_OPENSSL:-3.5.4}
V_NGHTTP3=${V_NGHTTP3:-1.12.0}
V_CURL=${V_CURL:-8.16.0}
CURL_TAG=$(printf '%s' "$V_CURL" | tr '.' '_')   # 8.16.0 -> curl-8_16_0

case "$ARCH" in
    x86_64)  TRIPLET=x86_64-linux-musl;    TC_TGZ=x86_64-linux-musl-cross.tgz;    OTARGET=linux-x86_64;  OEXTRA=""; CURLLIBS="" ;;
    i686)    TRIPLET=i686-linux-musl;      TC_TGZ=i686-linux-musl-cross.tgz;      OTARGET=linux-x86;     OEXTRA=""; CURLLIBS="" ;;
    aarch64) TRIPLET=aarch64-linux-musl;   TC_TGZ=aarch64-linux-musl-cross.tgz;   OTARGET=linux-aarch64; OEXTRA=""; CURLLIBS="" ;;
    # 32-битные arch без нативных 64-битных атомиков: линковка curl требует
    # libatomic (иначе curl configure не детектит OpenSSL — undefined
    # __atomic_*_8 в libcrypto).
    arm)     TRIPLET=arm-linux-musleabihf; TC_TGZ=arm-linux-musleabihf-cross.tgz; OTARGET=linux-armv4;   OEXTRA=""; CURLLIBS="-latomic" ;;
    mipsel)  TRIPLET=mipsel-linux-muslsf;  TC_TGZ=mipsel-linux-muslsf-cross.tgz;  OTARGET=linux-mips32;  OEXTRA="-DL_ENDIAN"; CURLLIBS="-latomic" ;;
    mipssf)  TRIPLET=mips-linux-muslsf;    TC_TGZ=mips-linux-muslsf-cross.tgz;    OTARGET=linux-mips32;  OEXTRA="-DB_ENDIAN"; CURLLIBS="-latomic" ;;
    riscv64) TRIPLET=riscv64-linux-musl;   TC_TGZ=riscv64-linux-musl-cross.tgz;   OTARGET=linux64-riscv64; OEXTRA=""; CURLLIBS="" ;;
    *) echo "build.sh: неизвестная архитектура: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# Скачивание с ретраями: частичный файл не пройдёт проверку размера.
# (wget под set -e справа от || убивает скрипт без сообщения — потому .part
# и явный rc-контракт dl: 0 = скачано, 1 = сообщение + exit 1 вызывающему.)
# ОПРЕДЕЛЕНИЕ ДО ПЕРВОГО ВЫЗОВА (тулчейн ниже) — иначе 127 в CI.
dl() { # dl <url> <file>
    [ -s "$2" ] && return 0
    n=0
    while :; do
        rm -f "$2.part"
        if wget -q -O "$2.part" "$1" && [ -s "$2.part" ]; then
            mv -f "$2.part" "$2"
            return 0
        fi
        n=$((n + 1))
        [ "$n" -lt 3 ] || { echo "build.sh: не скачалось $1" >&2; return 1; }
        sleep 5
    done
}

TC=$WORK/$TRIPLET-cross/bin/$TRIPLET-
if [ ! -x "${TC}gcc" ]; then
    echo "== toolchain $TRIPLET"
    # Основной источник — самохостинг (musl.cc отказывает GitHub-раннерам),
    # musl.cc — фолбэк для локальных сборок.
    TC_BASE=${Z2R_CURL_TC_BASE:-https://github.com/MarkinAlexander/z2r-curl-h3/releases/download/toolchains-v1}
    if [ "$ARCH" = mipsel ] || [ "$ARCH" = mipssf ]; then
        dl "$TC_BASE/$TC_TGZ" "$TC_TGZ" \
            || dl "https://github.com/musl-cc/musl.cc/releases/download/v0.0.1/$TC_TGZ" "$TC_TGZ" \
            || dl "https://musl.cc/$TC_TGZ" "$TC_TGZ"
    else
        dl "$TC_BASE/$TC_TGZ" "$TC_TGZ" || dl "https://musl.cc/$TC_TGZ" "$TC_TGZ"
    fi
    tar xf "$TC_TGZ"
fi
export CC=${TC}gcc AR=${TC}ar STRIP=${TC}strip RANLIB=${TC}ranlib LD=${TC}ld
export PKG_CONFIG_PATH=$WORK/stage/lib/pkgconfig

# --- OpenSSL 3.5 LTS: native QUIC API (>= 3.5) -------------------------------
OSSL=openssl-$V_OPENSSL
dl "https://github.com/openssl/openssl/releases/download/$OSSL/$OSSL.tar.gz" "$OSSL.tar.gz"
[ -d "$OSSL" ] || tar xf "$OSSL.tar.gz"
if [ ! -f "stage/lib/libssl.a" ]; then
    echo "== openssl $V_OPENSSL ($OTARGET $OEXTRA)"
    ( cd "$OSSL" \
        && make distclean >/dev/null 2>&1 || : \
        && ./Configure $OTARGET no-shared no-tests no-docs --prefix="$WORK/stage" -fPIC $OEXTRA >/dev/null \
        && make -j"$NPROC" >/dev/null \
        && make install_sw >/dev/null )
fi

# --- nghttp3: тег С v-префиксом (v1.12.0), ассет без него (nghttp3-1.12.0) ---
NG3=nghttp3-$V_NGHTTP3
dl "https://github.com/ngtcp2/nghttp3/releases/download/v$V_NGHTTP3/$NG3.tar.xz" "$NG3.tar.xz"
[ -d "$NG3" ] || tar xf "$NG3.tar.xz"
if [ ! -f "stage/lib/libnghttp3.a" ]; then
    echo "== nghttp3 $V_NGHTTP3"
    ( cd "$NG3" \
        && make distclean >/dev/null 2>&1 || : \
        && ./configure --host="$TRIPLET" --prefix="$WORK/stage" \
            --enable-static --disable-shared --enable-lib-only >/dev/null \
        && make -j"$NPROC" >/dev/null \
        && make install >/dev/null )
fi

# --- curl (тег с подчёркиваниями) --------------------------------------------
CUR=curl-$V_CURL
dl "https://github.com/curl/curl/releases/download/curl-${CURL_TAG}/$CUR.tar.xz" "$CUR.tar.xz"
[ -d "$CUR" ] || tar xf "$CUR.tar.xz"
if [ ! -f "stage/bin/curl" ]; then
    echo "== curl $V_CURL"
    # LIBS: libatomic только там, где нет нативных 64-битных атомиков.
    # AM_LDFLAGS=-all-static: ПОЛНАЯ статика бинарника (libtool съедает
    # LDFLAGS=-static и даже -all-static в LDFLAGS: переменная линка
    # бинарника — curl_LDFLAGS = $(AM_LDFLAGS)...). musl.cc-тулчейны иначе
    # дают musl-динамический бинарник — на Entware/uClibc нет ld-musl
    # => "not found" (проверено на MT7621; прод-курл кинетика тоже статика).
    ( cd "$CUR" \
        && make distclean >/dev/null 2>&1 || : \
        && ./configure --host="$TRIPLET" --prefix="$WORK/stage" \
            --with-openssl="$WORK/stage" --with-nghttp3="$WORK/stage" \
            --with-openssl-quic --disable-shared --enable-static \
            --without-libpsl --without-libidn2 --without-brotli --without-zstd \
            --without-libssh2 --without-nghttp2 --without-librtmp --without-zlib \
            --disable-ftp --disable-file --disable-ldap --disable-ldaps --disable-rtsp \
            --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
            --disable-smtp --disable-smb --disable-gopher --disable-mqtt \
            --disable-manual --disable-verbose >/dev/null \
            ${CURLLIBS:+LIBS="$CURLLIBS"} \
        && make -j"$NPROC" AM_LDFLAGS="-all-static" >/dev/null \
        && make install >/dev/null )
fi

"${TC}strip" "stage/bin/curl"

# --- Гард MIPS ABI: только soft-float (v1 собирался hard-float тулчейном) ------
# История: musl.cc-тулчейны *-musl* для mips/mipsel — hard-float по умолчанию;
# на роутерах без FPU (MT7621 и пр.) это SIGILL или медленная FPU-эмуляция
# ядром. Правильный тулчейн — отдельный *-muslsf* (см. PR #1). Гард до UPX:
# UPX-стаб не несёт .MIPS.abiflags, после упаковки ABI не проверить.
case "$ARCH" in
    mipsel|mipssf)
        if command -v readelf >/dev/null 2>&1; then
            if LC_ALL=C readelf -A "stage/bin/curl" | grep -q "FP ABI: Soft float"; then
                echo "== fp_abi: Soft float — OK"
            else
                LC_ALL=C readelf -A "stage/bin/curl" | grep "FP ABI" >&2 || :
                echo "build.sh: MIPS-бинарник не soft-float — не тот тулчейн, стоп" >&2
                exit 1
            fi
        else
            echo "build.sh: readelf недоступен — ABI-гард пропущен" >&2
        fi ;;
esac

# --- UPX: где поддержан — упаковываем (мавг-паттерн: не поддержал — едем без) -
BIN="$OUT/z2r-curl-h3-linux-$ARCH"
cp -f "stage/bin/curl" "$BIN"
if command -v upx >/dev/null 2>&1; then
    if upx --best --lzma "$BIN" >/dev/null 2>&1; then
        upx -t "$BIN" >/dev/null || { echo "build.sh: upx -t не прошёл, откат к чистому бинарнику" >&2; upx -d "$BIN" >/dev/null; }
    else
        echo "build.sh: upx не поддержал $ARCH — без упаковки (норма)" >&2
    fi
else
    echo "build.sh: upx не найден — без упаковки (норма)" >&2
fi
gzip -9n -c "$BIN" > "$BIN.gz"
rm -f "$BIN"

echo "== готово: $BIN.gz ($(du -h "$BIN.gz" | cut -f1))"
# Живой smoke после сборки невозможен на кросс-хосте для всех arch — вердикт
# даёт запуск на реальной платформе (см. README, раздел «Проверка»).
