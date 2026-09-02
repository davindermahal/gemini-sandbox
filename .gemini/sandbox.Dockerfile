# Custom Gemini CLI sandbox image for this project.
#
# Built with a plain `docker build` (see `make sandbox-image`), NOT `BUILD_SANDBOX=1 gemini` --
# that mechanism only works when gemini-cli itself is a source checkout (`npm link
# ./packages/cli` inside the gemini-cli repo), and refuses to run against a normal
# `npm install -g @google/gemini-cli`, which is what's installed here. Base image is pinned to
# match the installed CLI version rather than `FROM gemini-cli-sandbox` (the name most docs lead
# with) -- that tag is only ever produced by the source-checkout build path above and doesn't
# exist for a normal install.
FROM us-docker.pkg.dev/gemini-code-dev/gemini-cli/sandbox:0.57.0

USER root

# docker-ce-cli + docker-compose-plugin (from Docker's own apt repo -- Debian's bookworm repos
# don't carry a docker-compose-v2 package): lets `make`/`docker compose` run *inside* the sandbox,
# reaching the host's Docker daemon over the bind-mounted socket (Docker-outside-of-Docker) -- no
# Docker engine runs in this image, only the client + compose plugin.
RUN apt-get update && apt-get install -y --no-install-recommends \
        make \
        curl \
        ca-certificates \
        gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# The base image bundles its own Node (older, used internally by the gemini-cli binary re-exec'd
# inside this sandbox) at /usr/local/bin/node -- left untouched. ai-intake-mcp requires Node >=24
# and ships native addons (better-sqlite3, keytar) built against the host's Node 24, so it needs
# its own matching runtime here; NodeSource installs to /usr/bin/node, a different path, so both
# coexist. Referenced by its absolute path in .gemini/settings.json's mcpServers entry.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Align this image's `docker` group GID with the host's so the base image's non-root `node` user
# can use the bind-mounted docker.sock (group-owned, not world-writable). Override at build time
# if the host's GID differs -- check with `getent group docker`.
ARG DOCKER_GID=984
RUN groupmod -g ${DOCKER_GID} docker 2>/dev/null || groupadd -g ${DOCKER_GID} docker
RUN usermod -aG docker node

# chrome-devtools-mcp: Chromium's own internal sandbox needs unprivileged user namespaces this
# container doesn't grant (verified: fails with "No usable sandbox!" even as a non-root user with
# the default docker run flags used here) -- that's ordinary Docker+Chrome behavior, not specific
# to this image, and is worked around in .gemini/settings.json.tmpl via --chrome-arg=--no-sandbox
# on Chrome itself, not by adding container privileges. chrome-devtools-mcp declares
# engines.node "^20.19.0 || ^22.12.0 || >=23", which the base image's bundled Node (/usr/local/
# bin/node) already satisfies -- installed globally at build time (not `npx ...@latest` per
# session) for a pinned version and no per-session network fetch.
RUN apt-get update && apt-get install -y --no-install-recommends chromium \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g chrome-devtools-mcp@1.8.0 \
    && chown -R node:node /usr/local/share/npm-global 2>/dev/null || true

USER node
