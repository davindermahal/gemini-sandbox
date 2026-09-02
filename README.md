# gemini-sandbox

A working example of running [Gemini CLI](https://github.com/google-gemini/gemini-cli) inside its
own Docker sandbox, with the sandbox able to drive Docker itself
(Docker-outside-of-Docker) and reach an MCP server ([`ai-intake-mcp`](https://github.com/davindermahal/ai-intake-mcp)).
See [`goal.md`](goal.md) for the original request, [`.ai/system.md`](.ai/system.md) for the
design record, and
[`.ai/guides/gemini-docker-sandbox-mcp.md`](.ai/guides/gemini-docker-sandbox-mcp.md) for the full
in-depth findings — every non-obvious thing that had to be true for the sandbox + MCP combination
to work, source-cited, plus a portable step-by-step playbook for redoing this in another project.
That guide is written to be followed by an AI agent with no other context, which is the point:
it's the reference for reimplementing this pattern elsewhere.

The PHP/Symfony app in this repo is a minimal vehicle to prove the sandbox — it's not the point.

## Setup

1. `make up` — builds and starts the project's PHP container.
2. `make sandbox-image` — builds the custom Gemini CLI sandbox image (Docker CLI + Compose +
   Node 24 + DooD group setup). Rebuild this whenever `.gemini/sandbox.Dockerfile` changes.
3. `cp .gemini/env.example .gemini/env` and set `AI_INTAKE_MCP_DIR` to your local
   [`ai-intake-mcp`](https://github.com/davindermahal/ai-intake-mcp) checkout.

## Everyday use

- `make composer ARGS="require some/package"` — Composer inside the container.
- `make unit-test` (alias `make test-unit`) — run PHPUnit inside the container.
- `make shell` — shell into the PHP container.
- `bin/gemini-sandbox` — run `gemini` sandboxed and wired to `ai-intake-mcp`. Takes the same
  flags as `gemini` itself, e.g. `bin/gemini-sandbox -s -p "run make unit-test"`.

## Repo layout

- `docker/php/`, `docker-compose.yml`, `Makefile` — the demo Symfony app's own container and
  commands.
- `src/Command/HelloWorldCommand.php`, `tests/Command/HelloWorldCommandTest.php` — the demo app.
- `.gemini/sandbox.Dockerfile` — the custom sandbox image `gemini` runs inside.
- `.gemini/settings.json.tmpl` — template `gemini` settings (sandbox mode + `ai-intake` MCP
  registration); `bin/gemini-sandbox` renders it to the gitignored `.gemini/settings.json` using
  `.gemini/env`.
- `bin/gemini-sandbox` — wrapper that sets the env vars Gemini's sandbox needs
  (`GEMINI_SANDBOX_IMAGE`, `SANDBOX_MOUNTS`) and execs `gemini`.
