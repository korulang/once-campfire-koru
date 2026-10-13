# syntax = docker/dockerfile:1
#
# Production image for the Koru/Orisha port. A drop-in for the reference
# image contract: uid 1000, /rails workdir, storage mounted at
# /rails/storage/{db,files,logs}, bin/boot entrypoint,
# HTTP_PORT/TARGET_PORT env contract.
#
# Self-contained: everything the compile needs lives in vendor/ — the koru
# toolchain (zig sources + koru_std), orisha, and the koru-libs packages —
# snapshotted at the revisions in vendor/VENDOR.md. No sibling checkouts,
# no network fetches beyond base images and the zig toolchain.
#
#   docker build -t once-campfire-koru:app .
#
# The compile runs inside the image: stage `toolchain` builds koruc,
# stage `app-build` runs `koruc build main.k --build=linux --release=fast`,
# which emits the epoll pump, the generated Zig, and links the binary.

ARG DEBIAN_RELEASE=trixie
ARG ZIG_VERSION=0.15.2


# --- toolchain: zig + the compiler -----------------------------------------
FROM docker.io/library/debian:${DEBIAN_RELEASE} AS toolchain
ARG ZIG_VERSION
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl xz-utils ca-certificates \
      zlib1g-dev libsqlite3-dev libssl-dev libyyjson-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
RUN arch=$(uname -m) && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
      | tar -xJ -C /opt && \
    ln -s "/opt/zig-${arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

COPY vendor/koru/ /src/koru/
WORKDIR /src/koru
RUN zig build -Doptimize=ReleaseSafe


# --- the app compile: koruc emits the backend driver and the final binary ---
FROM toolchain AS app-build
# koru.json resolves these relative to the app dir; keep the same layout
# inside the container.
COPY . /src/once-campfire-koru/
COPY vendor/orisha/ /src/orisha/.claude/worktrees/ws-fanout/
COPY vendor/koru-libs/ /src/koru-libs/.claude/worktrees/cf-deps/
RUN mkdir -p /src/koru-libs/.claude/worktrees/bcrypt-pkg/bcrypt && \
    cp -r /src/once-campfire-koru/vendor/bcrypt/. /src/koru-libs/.claude/worktrees/bcrypt-pkg/bcrypt/
WORKDIR /src/once-campfire-koru
ENV PATH=/src/koru/zig-out/bin:$PATH
RUN koruc build main.k --build=linux --release=fast && \
    install -D -m 755 a.out /out/campfire


FROM docker.io/library/debian:${DEBIAN_RELEASE}-slim

# Runtime linkage of the emitted binary: -lz -lsqlite3 -lssl -lcrypto -lyyjson.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates zlib1g libsqlite3-0 libssl3t64 libyyjson0 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ARG OCI_DESCRIPTION
LABEL org.opencontainers.image.description="${OCI_DESCRIPTION}"
ARG OCI_SOURCE
LABEL org.opencontainers.image.source="${OCI_SOURCE}"
LABEL org.opencontainers.image.licenses="MIT"

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash

WORKDIR /rails

COPY --from=app-build /out/campfire /usr/local/bin/campfire

COPY --chmod=755 <<'EOF' /rails/bin/boot
#!/bin/sh
exec /usr/local/bin/campfire
EOF

RUN mkdir -p /rails/storage/db /rails/storage/files /rails/storage/backups /rails/storage/logs && \
    chown -R 1000:1000 /rails

USER 1000:1000

ENV RAILS_ENV="production"
# The harness mounts the seed at /rails/storage/{db,files}; the app reads
# these, falling back to dev defaults when unset.
ENV CAMPFIRE_DATABASE_PATH="/rails/storage/db/production.sqlite3"
ENV CAMPFIRE_FILES_PATH="/rails/storage/files"
ENV CAMPFIRE_STORAGE_PATH="/rails/storage"

ARG APP_VERSION
ENV APP_VERSION=$APP_VERSION
ARG GIT_REVISION
ENV GIT_REVISION=$GIT_REVISION

EXPOSE 80 443

CMD ["bin/boot"]
