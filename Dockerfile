# lsd-docker: the LSD Ace of Spades server, its script catalog, and the
# lsdctl tool that administers it -- one image, one server.
#
# Server source lives in the ./lsd git submodule; this project adds the
# packaging. Everything compiles inside the image: the server plus the
# native Lua modules the stock scripts need.
#
# Alpine/musl is used on purpose: the seccomp allowlist in
# src/sandbox/linux_seccomp.c is written against musl's syscalls, so the
# sandbox works as designed.
#
# Of the four layers src/sandbox/linux.c applies, two are compiled out.
# unshare + pivot_root is what the container already does, and inside one
# it fails for want of CAP_SYS_ADMIN -- and its failure is exit(1).
# Landlock, without that pivot_root to build its new root, only lets
# ./exec/ be executed, so luasodium.so and lsqlite3.so could not map
# libsodium and libsqlite3 from /usr/lib. no_new_privs and seccomp stay:
# the same seccomp-only sandbox this image always ran -- on the arches
# upstream's seccomp filter supports; see below.

FROM alpine:3.22 AS build

RUN apk add --no-cache build-base pkgconf unzip \
        luajit-dev enet-dev isa-l-dev linux-headers \
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

# Our changes to LSd's C, applied onto upstream's source (patches/lsd/README):
# the build stops here if upstream moved under one.
COPY patches/lsd/ /patches/
RUN for p in /patches/*.patch; do patch -p1 --forward < "$p" || exit 1; done

# The server stamps itself with the commit it was built from, for /version:
# upstream's Makefile has `src/commit.h: .git` and runs `git rev-parse` into
# that header. Neither half of it works here, for a reason on each side.
#
# .dockerignore keeps lsd/.git out of the build context deliberately -- it is a
# submodule, so its .git is a file pointing into the superproject's
# .git/modules, and copying the history in would both bloat the image and
# invalidate this layer on every commit to it. Nothing in the image has git
# installed either.
#
# So the commit arrives as a build argument and the header is written here. The
# empty .git is what the Makefile's rule wants -- a prerequisite to take a
# timestamp from, nothing more -- and dating it to 2000 keeps it older than the
# header, so make leaves both alone instead of running a `git rev-parse` that
# would fail.
#
# A build that does not pass the argument still works and reports "unknown",
# which is the honest answer for a build that cannot say.
ARG LSD_COMMIT=unknown
RUN touch -d '2000-01-01 00:00:00' .git \
 && printf '#ifndef GIT_COMMIT\n#define GIT_COMMIT "%s"\n#endif\n' \
        "$LSD_COMMIT" > src/commit.h

# The forced include is a missing upstream include: linux_seccomp.c calls
# syscall() and only gets its declaration from the unshare and landlock
# files, which are compiled out here. musl declares it in <unistd.h> only
# under _GNU_SOURCE, which a forced <unistd.h> would arrive before, so the
# prototype itself -- musl's own -- is what gets included.
#
# Seccomp goes in where upstream's filter knows the syscall table --
# x86_64, i386 and 32-bit arm -- and is compiled out elsewhere, which is
# arm64: linux_seccomp.c stops with "unknown seccomp arch" there. Such
# an image keeps no_new_privs and the container's own isolation, and
# `lsdctl status` says which sandbox it has.
#
# SANDBOX=none forces it out on any arch: for running an amd64 image
# under emulation, which cannot install a seccomp filter (EINVAL).
ARG TARGETARCH
ARG SANDBOX=auto
RUN printf 'long syscall(long, ...);\n' > /deps/syscall_decl.h \
 && case "$SANDBOX:$TARGETARCH" in \
        seccomp:*|auto:amd64|auto:386|auto:arm|auto:) sandbox=seccomp ;; \
        *) sandbox=none ;; \
    esac \
 && extra= && if [ "$sandbox" = none ]; then extra=-DWITHOUT_SECCOMP; fi \
 && make OPTS="-DWITH_ANYASCII -DWITHOUT_UNSHARE -DWITHOUT_LANDLOCK $extra -include /deps/syscall_decl.h" \
 && echo "$sandbox" > exec/SANDBOX

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

# socat: lsdctl talks to the server's console socket
# su-exec: the server and lsdctl run as lsd, the entrypoint as root
# tini: reaps and forwards signals to the server supervisor
# curl, jq: map downloads, and `update`'s Docker Engine API calls
RUN apk add --no-cache luajit enet isa-l sqlite-libs libsodium \
        socat su-exec tini curl jq \
 && adduser -D -H -u 1000 -h /lsd lsd

WORKDIR /lsd
COPY --from=build /build/server ./server
COPY --from=build /build/exec ./exec
# upstream's scripts, kept apart: the entrypoint assembles scripts/
# from them, the catalog and the data volume at every start
COPY --from=build /build/scripts ./scripts.dist
COPY catalog ./catalog
COPY image/config.lua ./config.lua
COPY image/entrypoint.sh /usr/local/bin/entrypoint
COPY image/ctl/lsdctl.sh /usr/local/bin/lsdctl
COPY image/ctl/lsdctl.lua image/ctl/selfupdate.sh /usr/local/lib/lsdctl/

ARG VERSION=dev
ARG LSD_COMMIT=unknown
RUN printf '%s\n' "$VERSION" > VERSION \
 && printf '%s\n' "$LSD_COMMIT" > LSD_COMMIT \
 && chmod +x /usr/local/bin/entrypoint /usr/local/bin/lsdctl \
        /usr/local/lib/lsdctl/selfupdate.sh \
 && mkdir -p scripts /data \
 && ln -s /data/maps maps \
 && chown lsd:lsd scripts /data

LABEL org.opencontainers.image.title="lsd-docker" \
      org.opencontainers.image.description="LSD Ace of Spades server with a script catalog, administered with lsdctl" \
      org.opencontainers.image.source="https://github.com/Fran6nd/lsd-docker" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.version="$VERSION"

ENV LSD_NO_STDIO_CONSOLE=1 \
    LSD_SETTINGS_FILE=/data/settings
VOLUME /data
EXPOSE 32887/udp
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
    CMD test -S /data/rw/console.sock

ENTRYPOINT ["/sbin/tini", "--", "entrypoint"]
CMD ["serve"]
