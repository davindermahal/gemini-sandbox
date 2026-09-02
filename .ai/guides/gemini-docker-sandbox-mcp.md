# Gemini CLI Docker sandbox + MCP: findings and a portable playbook

Audience: an AI agent (this was written to be followed by Gemini itself, with no access to this
conversation) reimplementing "Gemini CLI, sandboxed in Docker, with an MCP server reachable
inside that sandbox, able to drive Docker-outside-of-Docker for a project's own containers" in a
**different** project. Everything here was verified by hand against a real installation
(`@google/gemini-cli` v0.57.0, installed via plain `npm install -g`, on Debian-family Linux with
Docker 29.7.2) on 2026-09-01/02. Version numbers and exact behavior can change — Section 2 shows
you how to re-verify every claim below against whatever version you actually have, rather than
trusting these numbers blindly.

If you only read one section, read Section 1.4 and Section 1.5 — they are the two failures that
cost the most time before this was worked out, and neither is obvious from the public docs.
Adding a new MCP server or a browser/headless-Chrome MCP specifically? Skip straight to Section 5.

## 1. Root causes, in the order they'll bite you

### 1.1 `GEMINI_SANDBOX=docker` re-execs the *entire* CLI inside the container

This is the single fact that explains most of the rest. Public docs (`docs/cli/sandbox.md`)
describe the sandbox as isolating "potentially dangerous operations" (shell, file writes), which
reads like only *tool calls* get sandboxed while the CLI process itself keeps running on the
host. That is not what happens.

**Source** (installed CLI's own bundle — path and how to find it in Section 2.1), function that
launches the sandbox:

```js
debugLogger.log(`hopping into sandbox (command: ${command2}) ...`);
...
sandboxProcess2 = spawn2(config.command, args2, { stdio: "inherit" });
```

`args2` is a full `docker run ...` argv that re-launches the *same gemini binary* (baked into the
sandbox image) inside the new container, with the current argv/stdin piped through. The original
host process becomes a thin wrapper around that child. Consequence: **anything the CLI process
itself does at runtime — including spawning `mcpServers` over stdio — happens from inside the
container**, not on the host. An MCP server registered as `{"command": "node", "args":
[...]}` is spawned by the re-exec'd (sandboxed) process, so `node` and the server's code must
exist inside the sandbox image/mounts, not just wherever you normally run it.

This is almost certainly why "sandbox works, MCP doesn't" is the default experience: every
tutorial gets the sandbox running (that part just works), then registers an MCP server the normal
way, and it silently fails because the server was never reachable from inside the container.

### 1.2 `BUILD_SANDBOX=1` — documented as *the* way to customize the image, but gated to source checkouts

This is the "documentation says you can, but actually you can't" issue.

**What the docs say** (`docs/cli/sandbox.md`, and every third-party tutorial that cites it):
create `.gemini/sandbox.Dockerfile` in your project, then run:

```bash
BUILD_SANDBOX=1 GEMINI_SANDBOX=docker gemini -s
```

...and it will build your custom Dockerfile and use it. No caveats are mentioned.

**What the installed code actually does** (same bundle, inside the sandbox-launch function,
before it even gets to the docker-run step):

```js
if (process.env["BUILD_SANDBOX"]) {
  if (!gcPath.includes("gemini-cli/packages/")) {
    throw new FatalSandboxError(
      "Cannot build sandbox using installed gemini binary; run `npm link ./packages/cli` under gemini-cli repo to switch to linked binary."
    );
  } else {
    // ... execSync(`cd ${gcRoot} && node scripts/build_sandbox.js -s ${buildArgs}`, ...)
  }
}
```

`gcPath` is `process.argv[1]` (the actual script being executed). For a normal
`npm install -g @google/gemini-cli`, that path is something like
`/usr/local/share/npm-global/lib/node_modules/@google/gemini-cli/bundle/gemini.js` — it does
**not** contain the substring `gemini-cli/packages/`, which only appears when you've cloned the
`google-gemini/gemini-cli` monorepo and run `npm link ./packages/cli` inside it. So for any
normal install, `BUILD_SANDBOX=1` throws `FatalSandboxError` immediately. It is a maintainer/dev
workflow feature that the public docs present as if it were universally available.

**The workaround**, also verified from source: the function that decides whether an image needs
building or pulling (`ensureSandboxImageIsPresent`) only checks whether the image named by
`GEMINI_SANDBOX_IMAGE` already exists locally (`docker images` under the hood):

```js
async function ensureSandboxImageIsPresent(sandbox, image, cliConfig) {
  if (await imageExists(sandbox, image)) return true;   // <-- this is the only path we need
  if (image === LOCAL_DEV_SANDBOX_IMAGE_NAME) return false;  // "gemini-cli-sandbox" specifically
  // ...otherwise tries to `docker pull` it from a registry
}
```

So: build your custom image yourself with a **plain `docker build`** (no `gemini`/`BUILD_SANDBOX`
involved at all), tag it anything you like, and set `GEMINI_SANDBOX_IMAGE=<your-tag>` before
running `gemini`. It will find the image locally and use it as-is. This is what
`make sandbox-image` + `bin/gemini-sandbox` do in this repo.

One more trap this creates: `LOCAL_DEV_SANDBOX_IMAGE_NAME = "gemini-cli-sandbox"` — this is the
name most docs use in `FROM gemini-cli-sandbox` for a custom `.gemini/sandbox.Dockerfile`. That
tag is only ever produced by the source-checkout `BUILD_SANDBOX` path above; it does not exist,
and is not pullable, for a normal install. **`FROM gemini-cli-sandbox` will fail to build** unless
you've done the monorepo dance. Instead, `FROM` the real published image directly — see 1.6.

### 1.3 `SANDBOX_MOUNTS` silently defaults to read-only

From the same bundle, the `SANDBOX_MOUNTS` parser:

```js
let [from, to, opts] = mount.trim().split(":");
to = to || from;
opts = opts || "ro";     // <-- defaults to read-only if you omit the third field
```

If you mount `/var/run/docker.sock` via `SANDBOX_MOUNTS` without an explicit `:rw`, Docker's CLI
inside the sandbox can connect to the socket but can't issue commands — this fails in a way that's
easy to misdiagnose as a permissions/group problem (see 1.7) rather than a mount-mode problem.
Always write it as `/var/run/docker.sock:/var/run/docker.sock:rw` explicitly.

(Contrast: passing the same thing via `SANDBOX_FLAGS` as a raw `-v host:container` docker arg
defaults to `rw`, Docker's own native default — so if you see an example using `SANDBOX_FLAGS`
for the socket instead of `SANDBOX_MOUNTS`, that's why; either works as long as the mode is right.)

### 1.4 What's auto-mounted already (don't redo this yourself)

Verified from source, in this order, every time the docker sandbox launches:

1. The current working directory, at the **exact same absolute path** inside the container.
2. `$HOME/.gemini` (host) → mounted to a fixed `/home/node/.gemini` inside the container, **and**
   (on Linux, where the container's own home differs from the host's, e.g. `/home/alice` vs
   `/home/node`) *also* mounted again at the host's own literal absolute path — so global
   `~/.gemini/settings.json` (including any global `mcpServers` entries) is visible inside the
   sandbox without you doing anything.
3. The host's temp dir (`os.tmpdir()`).
4. `$HOME/.config/gcloud`, read-only, if it exists.
5. The file named by `GOOGLE_APPLICATION_CREDENTIALS`, read-only, if that env var is set (and the
   env var itself is rewritten to the in-container path).
6. `--add-host host.docker.internal:host-gateway` — so `host.docker.internal` resolves from
   inside the sandbox even without explicit network config.
7. Whatever you add via `SANDBOX_MOUNTS` (see 1.3) or `config.allowedPaths` (always read-only).

None of this needs to be reproduced by hand. What it does mean: if a *global* MCP server is
already registered in the host's `~/.gemini/settings.json`, it will be *visible* inside the
sandbox (mount #2) but will still fail unless the command it points to is *also* reachable inside
the container per 1.1 — visibility of the config isn't the same as reachability of the binary.

### 1.5 Network access is on by default — don't add anything for it

```js
let networkAccess = true;
networkAccess = config.networkAccess ?? true;   // settings.json object form can override
...
if (!config.networkAccess || proxyCommand) { /* put sandbox on an --internal network */ }
```

Default is full network access. `apt-get`, `npm`, `composer`, and calls out to something like
Jira all work inside the sandbox with zero extra configuration. Only worry about this if you
explicitly see `networkAccess: false` somewhere in a `tools.sandbox` settings object.

### 1.6 Base image: pin to the real published tag, not `gemini-cli-sandbox`

Following on from 1.2: point your custom Dockerfile at the actual image the installed CLI would
otherwise pull:

```js
const image = process.env["GEMINI_SANDBOX_IMAGE"]
  ?? "us-docker.pkg.dev/gemini-code-dev/gemini-cli/sandbox:0.57.0"   // hardcoded per-version default
  ?? customImage
  ?? packageJson?.config?.sandboxImageUri;
```

(Note the hardcoded string as the second `??` operand means `customImage` and
`packageJson?.config?.sandboxImageUri` are dead — a non-null literal always short-circuits the
chain. The *only* real override is the `GEMINI_SANDBOX_IMAGE` env var. Verify the version number
matches your installed CLI's `gemini --version` — the pin is version-specific.)

```dockerfile
FROM us-docker.pkg.dev/gemini-code-dev/gemini-cli/sandbox:0.57.0
```

That published image (Debian 12 "bookworm" as of this writing) already has: Node (older, e.g.
v20.x — the CLI's own runtime, don't touch it), `git`, `make`, `python3`, `curl`, `apt-get`. It
does **not** have a `docker` client, and its default user is a non-root `node` (uid/gid 1000).

### 1.7 Debian's `docker.io` doesn't ship `docker compose` v2 on this base

`apt-get install docker.io docker-compose-v2` fails — `docker-compose-v2` isn't a resolvable
package name on this image's apt sources (Debian bookworm's default repos). Use Docker's own apt
repo instead, which is the standard, version-controlled way to get `docker compose` v2 as a CLI
plugin without a full engine:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends make curl ca-certificates gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*
```

This installs only the **client** (`docker-ce-cli`) and the compose plugin — no daemon runs
inside the sandbox; all commands go out over the mounted socket to the host's daemon (DooD).

### 1.8 The non-root sandbox user needs the host's `docker` group GID, exactly

The socket is owned `root:docker` on the host, mode `srw-rw----` (group-writable, nothing else).
Docker enforces this by **numeric GID**, not by group name. The base image's `node` user (uid
1000) isn't in any `docker` group by default, and even after `apt-get install docker-ce-cli`
creates a `docker` group inside the image, its GID is whatever the next-free GID happens to be —
essentially never the same number as the host's. Get the host's real GID and force it:

```bash
getent group docker | cut -d: -f3     # e.g. 984 -- varies per machine, do not hardcode blindly
```

```dockerfile
ARG DOCKER_GID=984
RUN groupmod -g ${DOCKER_GID} docker 2>/dev/null || groupadd -g ${DOCKER_GID} docker
RUN usermod -aG docker node
```

Pass `--build-arg DOCKER_GID=$(getent group docker | cut -d: -f3)` at build time so this isn't
hardcoded per-machine. Symptom if you get this wrong: `docker` commands inside the sandbox fail
with a permission-denied talking to the socket, even though the mount itself (1.3) is `:rw`.

### 1.9 MCP servers with native addons need a Node version match — check `engines`, don't assume

The sandbox's bundled Node (1.6, e.g. v20.x) is *not* automatically the right runtime for every
MCP server. If the server's `package.json` declares `"engines": {"node": ">=X"}` and depends on
native addons (anything with compiled `.node` bindings — `better-sqlite3`, `keytar`, etc.), those
binaries are ABI-locked (`NODE_MODULE_VERSION`) to the major Node version they were built against.
Running them under a different major version throws at `require()`/`import` time with an ABI
mismatch error, not a helpful "wrong Node version" message.

Fix: install the Node major version the server actually needs, at a **different absolute path**
than the bundled one, so you don't disturb the CLI's own runtime:

```dockerfile
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*
```

NodeSource installs to `/usr/bin/node`; the base image's own Node lives at `/usr/local/bin/node`
(check with `command -v node` inside the base image before assuming) — different paths, no
collision, and `/usr/local/bin` precedes `/usr/bin` on `$PATH` so bare `node` still resolves to
the bundled one unless you reference the new binary by its full path. Point the MCP server's
`command` at that full path explicitly, e.g. `"command": "/usr/bin/node"`.

If the server's native addons were built on a *different host* than the sandbox (the common case:
you bind-mount an already-built `node_modules` from your normal dev machine, see 1.10), this
still works as long as both are the **same Node major version** and the same OS/libc family
(glibc Linux, which both your dev host and a Debian-based sandbox image are) —
`NODE_MODULE_VERSION` is stable across an entire major release line, not just one exact version.

### 1.10 Don't bake a second copy of the MCP server into the image — bind-mount the real one

If the MCP server's own docs/Dockerfile say it must run as a plain `node` child process sharing
its caller's working directory (common for anything that does `git rev-parse --show-toplevel` or
similar cwd-relative resolution), then per 1.1, the "caller" is now the sandboxed, re-exec'd CLI
process — and a *second*, separately-baked copy of the server inside the sandbox image would
resolve paths against the image's filesystem, not the real project. Instead, bind-mount the
server's real, already-built location (source + `node_modules` + config) into the sandbox at the
same absolute path it already lives at on the host, via `SANDBOX_MOUNTS`, read-only if nothing
needs to write there. This also means you never need to rebuild the sandbox image when the MCP
server's own code changes — only when the sandbox's own system packages change.

### 1.11 Headless verification gotchas (don't waste turns on these)

- `gemini -p "..."` in a directory that isn't yet trusted refuses to run. In an unattended/CI-like
  context there's no interactive prompt to answer, so pass `--skip-trust` explicitly (a per-run
  flag, doesn't persist anything) or set `GEMINI_CLI_TRUST_WORKSPACE=true`.
- Tool calls (running shell commands, calling MCP tools) require approval by default. In headless
  `-p` mode there is nothing to answer that approval prompt, so the process just hangs until your
  own timeout kills it — this looks exactly like a sandbox/network hang and is easy to
  misdiagnose as one. Pass `-y`/`--yolo` (or `--approval-mode yolo`) for unattended verification
  runs where you already trust what you're asking it to do.
- Slash commands (e.g. `/mcp list`) are a REPL affordance and don't reliably work as the literal
  text of a `-p` prompt (the model treats it as natural language, not a command to execute
  as-is). To verify an MCP tool is reachable, ask in plain language for the model to *call* a
  specific tool and report the result (e.g. "call the ai-intake health_check tool and report
  exactly what it returns") rather than trying to script `/mcp list`.
- The Gemini API free tier has a small daily request cap (as low as 20/day on some models as of
  this writing). Budget your live verification calls; prove the mechanism once, then rely on
  static checks (reading generated config files, `docker run --entrypoint sh <image> -c '...'`
  probes of the image itself) for anything you'd otherwise re-verify redundantly.

### 1.12 Don't collide with the target project's own reserved filenames

Not a Gemini/sandbox issue, but cost real time in this implementation and will cost it again in a
different stack: if your sandbox/MCP config needs a per-developer `.env`-style file, do **not**
put it at a path a framework already owns. Symfony (like many frameworks) treats root `.env` as
its own committed-by-convention config file; overwriting it with sandbox-specific variables
silently destroys framework configuration with no error from any tool (a plain file write
succeeds fine — nothing knows the two purposes collided). Put orchestration config under your own
clearly-scoped path instead (this repo uses `.gemini/env`, sibling to `.gemini/settings.json.tmpl`
and `.gemini/sandbox.Dockerfile` — nothing framework-owned lives under `.gemini/`).

### 1.13 The Policy Engine (`~/.gemini/policies/*.toml`) and the sandbox

There are **two different systems in gemini-cli that both use the word "sandbox" and both use
TOML**, and they are easy to conflate:

1. **The Policy Engine** (`docs/reference/policy-engine.md`) — the general allow/deny/ask_user
   system for tool calls, `[[rule]]` tables, files at `~/.gemini/policies/*.toml` (User tier) and
   `/etc/gemini-cli/policies` on Linux (Admin tier, or supplied via `--admin-policy`). This is
   almost certainly what "TOML allow/deny policies" refers to, and is the one covered below.
2. **`SandboxPolicyManager`** (`packages/core/src/policy/sandboxPolicyManager.ts`, config at
   `~/.gemini/policies/sandbox.toml`, default shipped in the CLI's own bundle at
   `policies/sandbox-default.toml`) — despite the name and the `[[rules]]` (plural!) section it
   also contains, this is **not** the Policy Engine and does **not** control the Docker
   container. Verified from source: its `network`/`readonly`/`approvedTools` fields are consumed
   by `sandboxPolicyManager.getModeConfig(mode)` / `.getCommandPermissions(rootCommand)` inside
   the shell tool's own approval logic — it's a per-**approval-mode** (`plan`/`default`/
   `accepting_edits`) allowlist of commands that get silently pre-approved (e.g. `cat`, `ls`,
   `grep` in `default` mode), unrelated to whether the Docker sandbox container itself has
   network access (that's the separate `networkAccess` flag from Section 1.5). Don't confuse
   `sandbox.toml`'s `[modes.*]` with the Policy Engine's `[[rule]]` schema — different files,
   different schemas, different purposes, despite living in the same `~/.gemini/policies/`
   directory.

**Does the (real) Policy Engine work inside the Docker sandbox?** Reasoned from source, not yet
live-verified end-to-end (see the caveat at the end of this section):

- **User-tier** (`~/.gemini/policies/*.toml`): yes. The entire CLI re-execs inside the sandbox
  (Section 1.1), and `$HOME/.gemini` is auto-mounted into the container at startup (Section 1.4)
  — so the re-exec'd process reads the exact same policy files from the exact same directory,
  mounted, regardless of whether it's running on the host or inside the sandbox. Nothing extra
  needed.
- **Workspace-tier** (`.gemini/policies/*.toml` in the project): currently non-functional
  regardless of sandbox — it's a known upstream bug
  ([google-gemini/gemini-cli#18186](https://github.com/google-gemini/gemini-cli/issues/18186)),
  not a sandbox-specific limitation. Don't rely on it either way; use User or Admin tier.
- **Admin-tier at the standard system location** (`/etc/gemini-cli/policies` on Linux): **not**
  covered by the sandbox's auto-mount list (Section 1.4 enumerates exactly what gets mounted —
  workspace, `~/.gemini`, tmpdir, `~/.config/gcloud`, `GOOGLE_APPLICATION_CREDENTIALS`,
  `SANDBOX_MOUNTS`; `/etc` isn't in that list). An admin policy that works outside the sandbox
  will very likely be silently invisible once sandboxed, unless you explicitly add it:
  `SANDBOX_MOUNTS="...,/etc/gemini-cli/policies:/etc/gemini-cli/policies:ro"`. Verify this on
  your own machine before relying on it (Section 2 has the method) — this is a deduction from the
  mount list and the documented Admin policy path, not something re-confirmed with a live
  sandboxed tool-call denial in this session.
- **`--policy <path>` / `--admin-policy <path>` flags**: verified from source
  (`gemini-OYYGXMHL.js`'s `entrypoint()` function, used by `start_sandbox`) that the *entire*
  original argv is forwarded, quoted, into the re-exec'd command inside the sandbox container —
  so a custom policy path passed this way must **also** be reachable at that same absolute path
  inside the container (i.e. it needs to be under the workspace, under `~/.gemini`, or added via
  `SANDBOX_MOUNTS`), or the re-exec'd process will fail to find it just as it would fail to find
  any other host-only path.

**Recommended verification recipe** once you have API quota available: put a `deny` rule for
something cheap and obviously-triggerable (e.g. `commandPrefix = "echo SANDBOX_POLICY_TEST"`,
`decision = "deny"`) in `~/.gemini/policies/test.toml`, then run the same prompt twice — once
without `-s`/sandbox, once with `bin/gemini-sandbox` (or `-s`) — and confirm both refuse the
command with your `denyMessage`. Do the same for a policy file under `/etc/gemini-cli/policies`
(remember the root-ownership + `chmod 755` requirement from the docs) to confirm the
auto-mount gap above, and again after adding the `SANDBOX_MOUNTS` workaround.

### 1.14 Headless Chrome / browser MCP servers inside the sandbox

**Tested directly** against this repo's actual sandbox image (`gemini-sandbox-demo:latest`),
independent of any Gemini API call (no quota needed — this is a plain `docker run`, not a
`gemini` invocation):

```bash
docker run --rm --entrypoint sh --user root gemini-sandbox-demo:latest -c '
  apt-get update -qq && apt-get install -y --no-install-recommends chromium
  su node -s /bin/sh -c "chromium --headless --disable-gpu --dump-dom about:blank"
'
```

Without any extra flags, this fails exactly as it would in any unprivileged Docker container —
not a gemini-cli-specific problem:

```
ERROR:content/browser/zygote_host/zygote_host_impl_linux.cc:128] No usable sandbox! If this is a
Debian system, please install the chromium-sandbox package to solve this problem. ... If you want
to live dangerously and need an immediate workaround, you can try using --no-sandbox.
```

This is Chrome's *own* internal sandbox (its zygote process needs unprivileged user namespaces,
which gemini's plain `docker run` — no `--privileged`, no added capabilities, default seccomp
profile, verified in Section 1.6-1.8's inspection of the launch args — doesn't grant, same as any
default `docker run`). Adding `--no-sandbox` to Chrome's own launch flags fixes it completely —
confirmed with a real network fetch, not just `about:blank`:

```bash
su node -s /bin/sh -c "chromium --headless --disable-gpu --no-sandbox --dump-dom https://example.com"
# -> renders the real page correctly; the only errors are harmless dbus-not-running noise
```

**Implemented and wired up in this repo** (not just recommended — this is what
`.gemini/sandbox.Dockerfile` and `.gemini/settings.json.tmpl` actually do):

1. `.gemini/sandbox.Dockerfile` installs `chromium` via apt (same layer as the docker-ce-cli
   install) and `npm install -g chrome-devtools-mcp@1.8.0` — pinned, not `npx ...@latest` per
   session, for a reproducible version and no per-session network fetch. It installs cleanly with
   the base image's *bundled* Node (chrome-devtools-mcp declares
   `"engines": {"node": "^20.19.0 || ^22.12.0 || >=23"}`, which the sandbox's stock Node already
   satisfies — no need to route it through the separate Node 24 install from Section 1.9).
2. `.gemini/settings.json.tmpl` registers it with `--no-sandbox` and `--disable-dev-shm-usage`
   passed to Chrome itself via `chrome-devtools-mcp`'s `--chrome-arg` flag (repeatable), and
   `--executable-path /usr/bin/chromium` pointing at the apt-installed binary rather than letting
   the tool try to download/manage its own:
   ```json
   "chrome-devtools": {
     "command": "chrome-devtools-mcp",
     "args": [
       "--headless",
       "--executable-path", "/usr/bin/chromium",
       "--chrome-arg=--no-sandbox",
       "--chrome-arg=--disable-dev-shm-usage"
     ]
   }
   ```
3. Default `/dev/shm` is 64 MB (confirmed: `df -h /dev/shm` inside the sandbox container) —
   Docker's standard default and a well-known source of Chrome renderer crashes under real
   (multi-tab/sustained) workloads. Handled above via `--disable-dev-shm-usage` (Chrome falls back
   to `/tmp`); the alternative, if you'd rather keep `/dev/shm`, is growing it with
   `SANDBOX_FLAGS="--shm-size=1g"` (verified in Section 1.3 to be a raw `docker run` flag
   passthrough).

**Verified, without spending any Gemini API quota** — this only needs `docker run`, not `gemini`
itself, so it was fully testable even while rate-limited:

```bash
docker run --rm --entrypoint sh gemini-sandbox-demo:latest -c '
  command -v chrome-devtools-mcp; command -v chromium   # both present, on the node users PATH
'
```

Then a real MCP JSON-RPC exchange over stdio, piped straight in — the same mechanism `gemini`
itself uses to talk to it:

```bash
docker run --rm --entrypoint sh gemini-sandbox-demo:latest -c '
{
  echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"probe\",\"version\":\"0\"}}}"
  echo "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
  echo "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"navigate_page\",\"arguments\":{\"url\":\"https://example.com\"}}}"
  sleep 5
} | chrome-devtools-mcp --headless --isolated --executable-path /usr/bin/chromium \
    --chrome-arg=--no-sandbox --chrome-arg=--disable-dev-shm-usage
'
```

Result: a clean `initialize` handshake (`"serverInfo":{"name":"chrome_devtools", ...}`), and the
`navigate_page` call reached the server's real argument validation (`Required at pageId` — a
schema mismatch in the hand-written probe call, not a launch failure). A Chrome/zygote launch
failure would look completely different (the `content/browser/zygote_host/...` error from
earlier in this section) — getting a clean validation error instead is proof Chromium actually
launched inside the container with `--no-sandbox`. Startup banner text goes to stderr only, stdout
carries clean JSON-RPC (checked separately, `1>out.log 2>err.log`) — worth confirming for any new
MCP server, since anything an MCP server prints to stdout that isn't valid JSON-RPC breaks the
stdio transport.

**Not yet verified**: a full run *through* `gemini` itself asking it to drive
`chrome-devtools`'s tools end-to-end — blocked by the same exhausted daily free-tier API quota
from Section 1.11, which held throughout this session. Everything above establishes the server is
correctly installed, launchable, and MCP-protocol-correct inside the exact image `gemini` uses;
the remaining gap is Gemini's own tool-call routing to it, which should work by the same
established mechanism as `ai-intake` (Section 1.1) but hasn't been watched happen live. Re-run
once quota resets: `bin/gemini-sandbox -s -p "use chrome-devtools to take a screenshot of https://example.com"`.

**Alternative deployment shape**, not implemented here: instead of launching Chrome inside the
(ephemeral, rebuilt-per-image-change) sandbox container, run Chrome as its own long-lived sibling
container (via DooD, same mechanism as the target project's own containers in Section 1.10) with
`--remote-debugging-port` exposed, and point `chrome-devtools-mcp` at it with
`--browser-url http://<container-name>:9222` instead of installing Chrome in the sandbox image at
all. Worth it if you want Chrome's profile/cache to survive across sandbox sessions.

## 2. How to re-verify any of this yourself, on a different machine or version

Don't trust the version numbers and exact snippets above once they're more than a few months old,
or once you're on a different OS. Re-derive them:

### 2.1 Find your installed CLI's actual source

```bash
GEMINI_BIN=$(readlink -f "$(which gemini)")
echo "$GEMINI_BIN"                      # the entry script
GEMINI_PKG_DIR=$(dirname "$(dirname "$GEMINI_BIN")")   # .../node_modules/@google/gemini-cli
find "$GEMINI_PKG_DIR" -iname "*sandbox*"
```

The real logic lives in the `bundle/` directory, usually in files named like `gemini-<hash>.js`
or `chunk-<hash>.js` (esbuild output — readable, not minified in the versions checked). Find the
one with the sandbox launcher:

```bash
grep -rln "SANDBOX_MOUNTS\|docker.sock" "$GEMINI_PKG_DIR"/bundle/*.js
```

### 2.2 Re-check the `BUILD_SANDBOX` guard specifically (Section 1.2)

```bash
grep -n "Cannot build sandbox using installed gemini binary" "$GEMINI_PKG_DIR"/bundle/*.js
```

If this string is gone or the surrounding logic no longer checks `gcPath`, the restriction may
have been lifted — re-read the surrounding ~40 lines before relying on the workaround in 1.2.

### 2.3 Re-check what gets auto-mounted (Section 1.4)

```bash
grep -n "userSettingsDirOnHost\|gcloudConfigDir\|GOOGLE_APPLICATION_CREDENTIALS\|SANDBOX_MOUNTS" \
  "$GEMINI_PKG_DIR"/bundle/gemini-*.js
```

Read outward from the first hit — it's one contiguous function (`start_docker_sandbox` or
similarly named) that builds up a `docker run` argv with `args.push("--volume", ...)` calls in
sequence; each one is a real auto-mount.

### 2.4 Confirm what's already inside the published sandbox base image

```bash
IMG="us-docker.pkg.dev/gemini-code-dev/gemini-cli/sandbox:<your-cli-version>"
docker run --rm --entrypoint sh "$IMG" -c 'cat /etc/os-release'
docker run --rm --entrypoint sh "$IMG" -c \
  'for c in node gemini git make docker python3 curl apt-get sudo; do
     printf "%-10s " "$c"; command -v "$c" || echo "NOT FOUND"; done'
docker run --rm --entrypoint sh "$IMG" -c 'whoami; id; node --version'
```

(`--entrypoint sh` is required — the image's default entrypoint is the `gemini` binary itself,
which will otherwise try to parse your inspection command as CLI flags.)

### 2.5 Confirm the host's real docker group GID before building (Section 1.8)

```bash
getent group docker | cut -d: -f3
stat -c '%g' /var/run/docker.sock   # should match
```

## 3. Portable playbook: redo this from scratch in a new project

Generic steps, in order. Concrete filenames used in *this* repo are given as examples — Section 4
maps them 1:1 if you want a working reference to copy from instead of writing from scratch.

1. **Get the target app itself working in plain Docker first, with zero Gemini involvement.**
   Whatever the project's own containers/`make`-style commands are, prove they work with plain
   `docker`/`docker compose` before adding a sandbox layer on top — it collapses the debugging
   space enormously when something breaks later.
2. **Confirm your installed `gemini` is a normal npm/global install**, not a monorepo checkout —
   run Section 2.1's commands. If it *is* a checkout, `BUILD_SANDBOX=1` may actually work for you
   and you can skip straight to the docs' documented flow; the rest of this playbook (manual
   `docker build` + `GEMINI_SANDBOX_IMAGE`) is the workaround for the normal-install case.
3. **Get the exact published sandbox image tag** your installed CLI defaults to (Section 2.1's
   `find`, or just run `gemini -s` once with default settings and watch what it pulls/references
   in verbose/debug output) and pin your custom Dockerfile to it — never to `gemini-cli-sandbox`.
4. **Write the custom sandbox Dockerfile**: start from that pinned tag, `USER root`, install
   whatever the target project's own commands need (e.g. `make`) plus Docker's official apt repo
   for `docker-ce-cli` + `docker-compose-plugin` (Section 1.7) if DooD is needed, align the
   `docker` group GID to the host's (Section 1.8, pass it as a build ARG, never hardcode), add
   any MCP server's required Node/Python/etc. runtime at a path that doesn't collide with the
   base image's own tooling (Section 1.9), then switch back to the base image's non-root user.
5. **Build it yourself**: `docker build --build-arg DOCKER_GID=$(getent group docker | cut -d: -f3) -t <your-tag> -f path/to/sandbox.Dockerfile .` — no `gemini`/`BUILD_SANDBOX` involved.
6. **Write a wrapper script** (not a static env file, if any of its values are per-developer) that
   exports `GEMINI_SANDBOX_IMAGE=<your-tag>` and a correctly-`:rw`-suffixed `SANDBOX_MOUNTS` for
   the Docker socket plus any MCP server paths, renders `.gemini/settings.json` from a template if
   any of those paths are per-developer (Section 1.12 — keep this templating outside any
   framework-reserved config file), and then `exec gemini "$@"`.
7. **Set `.gemini/settings.json`'s `tools.sandbox` to `"docker"`** so the sandbox is automatic for
   anyone running `gemini` from the project directory, and register the MCP server under
   `mcpServers` pointing at the in-sandbox runtime path from step 4, not wherever it normally runs
   on a bare host.
8. **Verify in three narrow steps, headlessly** (Section 1.11 for the flags), so a failure tells
   you which layer broke:
   - `<wrapper> -s --skip-trust -y -p "run 'whoami && id && docker ps'"` — proves the sandbox
     launches and DooD is wired (docker.sock mount + GID alignment + docker CLI present).
   - `<wrapper> -s --skip-trust -y -p "run '<the target project's own build/test command>'"` —
     proves DooD actually drives the target project's containers.
   - `<wrapper> -s --skip-trust -y -p "call the <mcp-server>'s <a cheap, side-effect-free tool> and report exactly what it returns"` —
     proves the MCP server is reachable and its runtime/native-addon versions actually match.
9. **Only after all three pass**, layer in anything per-developer-specific (Section 1.12's
   templating) and re-run step 8's third check once more to confirm the generalization didn't
   break anything.

## 4. Where each of the above lives in this repo

| Playbook step | File(s) here |
|---|---|
| Target app in plain Docker (step 1) | `docker/php/Dockerfile`, `docker-compose.yml`, `Makefile` |
| Custom sandbox Dockerfile (steps 3-4) | `.gemini/sandbox.Dockerfile` |
| Build it yourself (step 5) | `Makefile`'s `sandbox-image` target |
| Wrapper script (step 6) | `bin/gemini-sandbox` |
| `tools.sandbox` + `mcpServers` (step 7) | `.gemini/settings.json.tmpl` (rendered to the
  gitignored `.gemini/settings.json` by `bin/gemini-sandbox`) |
| Per-developer MCP path (step 9's templating) | `.gemini/env.example` → `.gemini/env` (gitignored) |

See `.ai/system.md` for what the target app and MCP server are in this specific repo, and
`goal.md` for the original request this was all built to satisfy.

## 5. Adding another MCP server, and governing its access

Two separate concerns, easy to conflate: making a new MCP server **reachable** inside the sandbox
(plumbing), and deciding what it's **allowed to do** once it's there (governance). Neither is
specific to `ai-intake-mcp` — the same steps apply to any MCP server.

### 5.1 Reachability (plumbing) — checklist for any new server

This is Sections 1.1, 1.9, and 1.10 above, generalized into steps:

1. **Does its `command` binary/runtime exist inside the sandbox image?** Per Section 1.1, the
   entire CLI (and therefore anything it spawns over stdio) runs *inside* the container. Check
   what runtime the server needs (`node`, `python3`, a compiled binary, `npx <pkg>`) and whether
   the sandbox base image already has it (Section 1.6 lists what's pre-installed) or needs adding
   to `.gemini/sandbox.Dockerfile`.
2. **Does that runtime's *version* match what the server needs?** Don't assume the bundled Node
   (Section 1.9, ~v20) is new enough — check the server's own `package.json` `engines` field (or
   equivalent) and install a matching version at a non-colliding path if not, exactly as done for
   `ai-intake-mcp`.
3. **Where does its code/config live, and does it need to write anywhere?** If it's meant to run
   as a child process sharing the sandboxed CLI's cwd (common for anything that does path
   resolution relative to the caller), bind-mount its real location via `SANDBOX_MOUNTS` rather
   than baking a second copy into the image (Section 1.10) — read-only unless it genuinely writes
   there. If it's a self-contained package fetched via `npx`/`pip install`/etc. at run time
   instead, network access is on by default (Section 1.5) so that generally works unmodified, but
   consider baking it into the image instead for reproducibility and to avoid a network fetch on
   every sandbox session.
4. **Register it** in `.gemini/settings.json` (or the `.tmpl` if any of its paths are
   per-developer, Section 1.12/3) under `mcpServers`, with `command`/`args` pointing at the
   in-sandbox paths from steps 1-3 — not wherever it normally runs on a bare host.
5. **Verify with the narrow-scope headless recipe** from Section 3, step 8's third bullet: ask
   the model to call one cheap, side-effect-free tool from the new server and report exactly what
   it returns.

### 5.2 Governance (what it's allowed to do) — the Policy Engine's MCP syntax

Once a server is reachable, use the real Policy Engine (Section 1.13 — not `sandbox.toml`) to
control it, in a policy file under `~/.gemini/policies/` (User tier) or an Admin-tier location.
The engine has purpose-built syntax for this (from `docs/reference/policy-engine.md`, bundled
with the CLI at `bundle/docs/reference/policy-engine.md`):

```toml
# Allow one specific tool on one specific server, no confirmation prompt:
[[rule]]
mcpName = "chrome-devtools"
toolName = "take_screenshot"
decision = "allow"
priority = 200

# Deny everything from a server you don't trust yet:
[[rule]]
mcpName = "some-new-server"
decision = "deny"
priority = 500
denyMessage = "some-new-server hasn't been reviewed yet."

# Ask for confirmation on every tool call from every MCP server by default:
[[rule]]
toolName = "*"
mcpName = "*"
decision = "ask_user"
priority = 10
```

Notes specific to combining this with the sandbox:

- Per Section 1.13, put these in `~/.gemini/policies/*.toml` (auto-mounted, works inside the
  sandbox with no extra steps) rather than a project-local `.gemini/policies/` (currently
  non-functional regardless of sandbox) or the Admin system path (needs an explicit
  `SANDBOX_MOUNTS` entry to be visible inside the container at all).
- The docs warn against underscores in `mcpName` — the parser splits fully-qualified tool names
  (`mcp_<server>_<tool>`) on the *first* underscore after `mcp_`, so `my_server` breaks wildcard
  matching silently. Use hyphens (`my-server`) in the `mcpServers` key you choose, and it'll match
  cleanly by `mcpName` in policy rules.
- `deny` is preferred over the legacy `mcpServers.<name>.excludeTools`/`includeTools` settings
  fields (still supported, but the docs call policy-`deny` the recommended mechanism going
  forward) — global `deny` rules remove the tool from the model's context entirely, which is both
  more secure and cheaper on tokens than the model seeing a tool it's never allowed to call.

### 5.3 Where to install a server with local state — the recommended convention

Section 5.1 step 3 asks "where does its code/config live" as if there's an obvious answer. There
isn't one, ecosystem-wide — checked directly: the MCP spec itself only defines the client-server
*protocol* (transport, tools/resources/prompts), not deployment, and the official
[MCP Registry](https://registry.modelcontextprotocol.io/) is explicitly a metadata/discovery
layer that points at npm/PyPI/container registries rather than prescribing a filesystem location.
For a server with no local state, the ecosystem default is to sidestep the question entirely by
never installing anything persistent — invoke it ephemerally via `npx -y <package>@<pinned
version>` or `uvx <package>` as the `command`, exactly as this repo does for `chrome-devtools-mcp`
in `.gemini/sandbox.Dockerfile` (baked into the image at a pinned version, so there's no
per-session network fetch either).

For a server that **does** have local state — a private/forked server, native dependencies, a
config file, anything you clone rather than fetch from a registry — clone it wherever you want.
The actual convention worth adopting isn't a specific directory; it's this: **never hardcode that
path into a committed file.** Treat it as a per-developer setting, the same way any other
machine-specific config is handled, not as a repo-wide constant. This repo's own
`AI_INTAKE_MCP_DIR` (Section 1.12, Phase 3b of the implementation) is the concrete instance of
this pattern:

1. `.gemini/env.example` (committed) — documents the variable and what it should point at, with a
   placeholder value.
2. `.gemini/env` (gitignored) — each developer's real path, e.g.
   `AI_INTAKE_MCP_DIR=/wherever/they/cloned/it`.
3. `.gemini/settings.json.tmpl` (committed) — the `mcpServers` entry with a placeholder
   (`__AI_INTAKE_MCP_DIR__`) instead of a literal path, because a static JSON file can't read env
   vars in `args` (only `env` values support `$VAR` expansion in Gemini's `mcpServers` schema).
4. `bin/gemini-sandbox` — sources `.gemini/env`, renders the template with `sed`, and builds
   `SANDBOX_MOUNTS` from the same variable, so the one value drives both the sandbox mount and the
   MCP registration.

Applying this to a new server: pick any directory you like for it, add one line to
`.gemini/env.example` / `.gemini/env` for its path, reference the placeholder in
`.gemini/settings.json.tmpl`, and extend `bin/gemini-sandbox`'s `SANDBOX_MOUNTS` construction the
same way — don't invent a second templating mechanism per server. If the server needs its own
config/data directory too (separate from its code), the closest thing to a real convention is the
Linux XDG pattern `ai-intake-mcp` itself follows for this — `~/.config/<server-name>/` for config,
`~/.local/share/<server-name>/` for data — which at least has the virtue of being predictable
without needing a project-specific env var at all, since it's always `$HOME`-relative.
