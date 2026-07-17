# Build and run the LSD server (lsd-dev.fran6nd.online).
# Server source lives in the ./lsd git submodule; this project adds the
# packaging. Everything compiles inside the image: the server plus the
# native Lua modules the stock scripts need.
#
# Alpine/musl is used on purpose: the seccomp allowlist in src/sandbox.c
# is written against musl's syscalls, so the sandbox works as designed.
# The container replaces the pivot_root/userns half of the sandbox, so
# the server is built like the Makefile's serverstatic-crust target:
# no unshare, seccomp kept.

FROM alpine:3.22 AS build

RUN apk add --no-cache build-base pkgconf unzip \
        luajit-dev enet-dev isa-l-dev libseccomp-dev \
        sqlite-dev libsodium-dev

# third-party Lua bindings, pinned by version/commit and checksummed so
# a nightly rebuild can't silently pick up different upstream code
ARG LINENOISE_REF=a473823d74b93eab2ba83480df16ed37617493f2
ARG STB_REF=31c1ad37456438565541f4919958214b6e762fb4
WORKDIR /deps
RUN wget -q -O lsqlite3.zip 'https://lua.sqlite.org/home/zip/lsqlite3_fsl09y.zip' \
 && unzip -q lsqlite3.zip \
 && wget -q -O luasodium.src.rock 'https://luarocks.org/luasodium-2.3.0-1.src.rock' \
 && wget -q -O linenoise.c "https://raw.githubusercontent.com/antirez/linenoise/${LINENOISE_REF}/linenoise.c" \
 && wget -q -O linenoise.h "https://raw.githubusercontent.com/antirez/linenoise/${LINENOISE_REF}/linenoise.h" \
 && wget -q -O stb_image.h "https://raw.githubusercontent.com/nothings/stb/${STB_REF}/stb_image.h" \
 && wget -q -O lfs.c 'https://raw.githubusercontent.com/lunarmodules/luafilesystem/v1_8_0/src/lfs.c' \
 && wget -q -O lfs.h 'https://raw.githubusercontent.com/lunarmodules/luafilesystem/v1_8_0/src/lfs.h' \
 && printf '%s\n' \
        'a3de0d56dcdd7df85e334174cd46e70451f996bc843e735ab1d8a8e8804f9486  lsqlite3_fsl09y/lsqlite3.c' \
        '3048e0555e0d2737d9b42ae70c7ee1c6aebd35961c1f15ba2aa938034f6fce78  luasodium.src.rock' \
        '4bc28faf2a46ccaea11d07aa056e21aa2e9a748b4dc6962346a3f658593103a8  linenoise.c' \
        '5f94c6295e3b62e0f8b4b62b0a2f351433d0b6b21029607aec0c9abbc60acff7  linenoise.h' \
        '594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3  stb_image.h' \
        '2ac573292943a04824ca76c6410a72768d7b00ffada8e472ecc95e11dd101b46  lfs.c' \
        '10a7d3e095a8f3fed9a4b29f8ed9c8dccd576caf04426bfc51322bf79ce4727e  lfs.h' \
    | sha256sum -c - \
 && unzip -q luasodium.src.rock \
 && tar xzf luasodium-2.3.0.tar.gz

COPY lsd/ /build
WORKDIR /build
RUN make OPTS='-DWITH_ANYASCII -DNO_DEFAULT_SANDBOX -DWITH_LIBSECCOMP'

# lsqlite3 -> exec/lsqlite3.so
RUN cc -O2 -fPIC -shared $(pkg-config --cflags luajit) \
        /deps/lsqlite3_fsl09y/lsqlite3.c -lsqlite3 -o exec/lsqlite3.so

# luasodium (all core modules in one .so; luasodium.c exports luaopen_luasodium)
RUN cc -O2 -fPIC -shared $(pkg-config --cflags luajit) \
        /deps/luasodium-2.3.0/c/luasodium/luasodium.c \
        /deps/luasodium-2.3.0/c/luasodium/*/core.c \
        -lsodium -o exec/luasodium.so

# linenoise (stdio_console), stb_image (lib_stbimage), lfs (babel/emote)
RUN cc -O2 -fPIC -shared /deps/linenoise.c -o exec/liblinenoise.so \
 && printf '#define STB_IMAGE_IMPLEMENTATION\n#include "stb_image.h"\n' \
    | cc -O2 -fPIC -shared -I /deps -x c - -lm -o exec/libstbimage.so \
 && cc -O2 -fPIC -shared $(pkg-config --cflags luajit) \
        /deps/lfs.c -o exec/lfs.so


FROM alpine:3.22

# socat is only for `lsdctl console` (attach to sock_console in rw/)
RUN apk add --no-cache luajit enet isa-l libseccomp sqlite-libs libsodium socat \
 && adduser -D -H -h /lsd lsd

WORKDIR /lsd
COPY --from=build /build/server ./server
COPY --from=build /build/exec ./exec
# upstream scripts are baked as scripts.dist; the entrypoint assembles
# the runtime scripts/ dir from them plus the scripts.local/ mount
COPY --from=build /build/scripts ./scripts.dist
# default config baked in; compose mounts the live one from the host
COPY config.lua ./config.lua
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
 && mkdir -p rw maps scripts && chown lsd:lsd rw maps scripts

USER lsd
# override at run time: -e LSD_PORT=... -e LSD_CONFIG=/path/inside/container
ENV LSD_PORT=32887 \
    LSD_CONFIG=config.lua \
    LSD_NO_STDIO_CONSOLE=1
EXPOSE 32887/udp

ENTRYPOINT ["docker-entrypoint.sh"]
