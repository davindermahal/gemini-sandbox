# system.md

## What this project is

A generic setup for running Google's Gemini CLI against a project inside a Docker sandbox, where:

- The real project lives in its own Docker container(s) and is driven by `make` targets (e.g. `make up`, `make test-unit`, `make composer {ARGS}`).
- Gemini itself must run inside a sandbox (a hard requirement of this setup, not a preference), but that sandbox needs to be able to invoke Docker — i.e. Docker-outside-of-Docker, by mounting `docker.sock` into the sandbox container per Gemini's own sandboxing documentation.
- Running `gemini` should launch the sandbox and give Gemini access to an MCP server, which in turn can execute the project's `make` commands (`make up`, `make unit-test`, `make composer {ARGS}`, etc.) against the dockerized project.

**The focus of this project is the sandboxing mechanism itself** — getting Gemini's sandbox + Docker-outside-of-Docker + MCP access all working together — not the demo application. Getting the sandbox running in isolation is the easy part; getting an MCP server reachable *inside* it is the part that isn't obvious from the public docs (see the findings guide below for why).

## The demo application (a vehicle, not the point)

Built and verified working (`make up`, `make composer install`, `make unit-test`):

- `docker/php/Dockerfile` + `docker-compose.yml` — a single `php` service (`php:8.3-cli` +
  Composer), kept alive via `tail -f /dev/null` so `make` targets can `docker compose exec` into
  it. Runs as the host's UID/GID (see `docker-compose.yml`'s `user:` key) so files it writes
  aren't root-owned on the host.
- A standard `symfony/skeleton:7.*` app at the repo root, plus `symfony/test-pack` (PHPUnit 12)
  for dev.
- `src/Command/HelloWorldCommand.php` (`app:hello`) and
  `tests/Command/HelloWorldCommandTest.php` — the "hello world" vehicle from `goal.md`.
- `Makefile` targets: `up`, `down`, `composer` (`ARGS=...`), `unit-test` / `test-unit` (alias —
  `goal.md` used both names), `shell`.

## MCP

Base: [ai-intake-mcp](https://github.com/davindermahal/ai-intake-mcp), already installed on this
machine at the path recorded in `.gemini/env` (gitignored, per-developer — see `.gemini/env.example`
for the template). Confirmed still the intended base; wired all the way through and verified live
(see `.gemini/sandbox.Dockerfile`, `.gemini/settings.json.tmpl`, `bin/gemini-sandbox`).

Two non-obvious things had to be true simultaneously for this to work, both found by reading
Gemini CLI's own bundled source rather than its docs (see `bin/gemini-sandbox`'s comments and
`.ai/guides/gemini-docker-sandbox-mcp.md` for the full source-code citations):

1. When the sandbox is active, Gemini CLI re-execs its entire self inside the container, so any
   stdio `mcpServers` entry is spawned *from inside* the sandbox — the MCP server's runtime must
   be reachable there, not just on the host.
2. `ai-intake-mcp` requires Node ≥24 (native addons compiled against it), but Gemini's published
   sandbox image ships Node ~20. Node 24 is installed into the custom sandbox image at
   `/usr/bin/node` (NodeSource), left alongside the bundled Node, and referenced by that absolute
   path in `mcpServers`.

`ai-intake-mcp` itself is bind-mounted read-only into the sandbox at its real host path (via
`SANDBOX_MOUNTS`, built from `.gemini/env`'s `AI_INTAKE_MCP_DIR`) rather than baked into the
image — its own Dockerfile documents why: it must run as a plain `node` child process sharing the
caller's cwd for `git rev-parse --show-toplevel` resolution to work.

Not attempted: `worktree_create` (needs the parent dev directory mounted read-write — a bigger
blast-radius decision than this demo needed, and expected to become moot once `ai-intake-mcp`
defaults to branch checkouts instead of worktrees) and exercising the full Jira ticket pipeline —
only `health_check` was used to prove reachability.

A second MCP server, [`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp)
(official Chrome DevTools Protocol server), is also wired in — `chromium` + a pinned global
`chrome-devtools-mcp` install in `.gemini/sandbox.Dockerfile`, registered in
`.gemini/settings.json.tmpl` with `--chrome-arg=--no-sandbox` (Chrome's own internal sandbox needs
unprivileged user namespaces this container doesn't grant — verified directly, not
gemini-specific) and `--chrome-arg=--disable-dev-shm-usage` (the container's default 64MB
`/dev/shm`). Verified without spending API quota: the binary launches inside the built image and
speaks correct MCP JSON-RPC over stdio, including a real tool call reaching Chromium's own
argument validation. Not yet verified: driving it through an actual `gemini` prompt — blocked by
the Gemini API's daily free-tier quota (see `.ai/guides/gemini-docker-sandbox-mcp.md` Section
1.11). See that guide's Section 1.14 for the full detail, including the exact probe commands used.

`bin/gemini-sandbox` also conditionally mounts `/etc/gemini-cli/policies` (Linux admin-tier Policy
Engine location) read-only into the sandbox if it exists on the host — that path isn't one of
gemini's own auto-mounts, so admin policies would otherwise silently stop applying once sandboxed.
See the same guide, Section 1.13.

## Glossary

- **Sandbox** — the isolated environment Gemini is required to run in for this project (a hard requirement, not a technical preference).
- **Docker-outside-of-Docker (DooD)** — running Docker commands from inside a container by mounting the host's `docker.sock` into that container, rather than running a nested Docker daemon (Docker-in-Docker).
- **MCP** — Model Context Protocol; the mechanism by which Gemini (running in the sandbox) is meant to invoke the project's `make` targets.

## Why this repo exists

Gemini CLI's own docs describe its Docker sandbox and its MCP server support as two independent
features, each documented on its own page. Neither page mentions the other. In practice, getting
an MCP server to actually work *inside* the sandbox (rather than just getting the sandbox itself
to launch) requires several things that aren't written down anywhere obvious — found only by
reading Gemini CLI's own bundled source. This project exists to work that combination out once,
verify it end to end against a real MCP server, and write down exactly what was found and why, so
it doesn't have to be re-discovered from scratch. See
`.ai/guides/gemini-docker-sandbox-mcp.md` for the findings themselves.
