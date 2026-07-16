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

RUN apk add --no-cache build-base pkgconf gawk curl unzip \
        luajit-dev enet-dev isa-l-dev libseccomp-dev \
        sqlite-dev libsodium-dev

# third-party Lua bindings, pinned versions
WORKDIR /deps
RUN curl -fsSL -o lsqlite3.zip 'http://lua.sqlite.org/home/zip/lsqlite3_fsl09y.zip' \
 && unzip -q lsqlite3.zip \
 && curl -fsSL -o luasodium.src.rock 'https://luarocks.org/luasodium-2.3.0-1.src.rock' \
 && unzip -q luasodium.src.rock \
 && tar xzf luasodium-2.3.0.tar.gz \
 && curl -fsSL 'https://github.com/antirez/linenoise/archive/master.tar.gz' | tar xz \
 && curl -fsSL -o stb_image.h 'https://raw.githubusercontent.com/nothings/stb/master/stb_image.h' \
 && curl -fsSL 'https://github.com/lunarmodules/luafilesystem/archive/refs/tags/v1_8_0.tar.gz' | tar xz

COPY lsd/ /build
WORKDIR /build
RUN make clean && make OPTS='-DWITH_ANYASCII -DNO_DEFAULT_SANDBOX -DWITH_LIBSECCOMP'

# lsqlite3 -> exec/lsqlite3.so
RUN cc -O2 -fPIC -shared $(pkg-config --cflags luajit) \
        /deps/lsqlite3_fsl09y/lsqlite3.c -lsqlite3 -o exec/lsqlite3.so

# luasodium (all core modules in one .so; luasodium.c exports luaopen_luasodium)
RUN cc -O2 -fPIC -shared $(pkg-config --cflags luajit) \
        /deps/luasodium-2.3.0/c/luasodium/luasodium.c \
        /deps/luasodium-2.3.0/c/luasodium/*/core.c \
        -lsodium -o exec/luasodium.so

# linenoise (stdio_console), stb_image (lib_stbimage), lfs (babel/emote)
RUN cc -O2 -fPIC -shared /deps/linenoise-master/linenoise.c -o exec/liblinenoise.so \
 && printf '#define STB_IMAGE_IMPLEMENTATION\n#include "stb_image.h"\n' \
    | cc -O2 -fPIC -shared -I /deps -x c - -lm -o exec/libstbimage.so \
 && cc -O2 -fPIC -shared $(pkg-config --cflags luajit) \
        /deps/luafilesystem-1_8_0/src/lfs.c -o exec/lfs.so


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
VOLUME /lsd/rw

ENTRYPOINT ["docker-entrypoint.sh"]
