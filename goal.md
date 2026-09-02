# Goal

Create a generic setup for running Google's Gemini CLI inside a Docker sandbox.

Gemini CLI must run inside its own Docker sandbox — that's a hard requirement of this setup, not
a preference — but the sandbox needs to be able to drive Docker itself. That's
Docker-outside-of-Docker: mounting the host's `docker.sock` into the sandbox container per
Gemini's own sandboxing documentation, so commands run inside the sandbox can still operate on
the project's own containers.

The project is driven by `make` commands — `make up`, `make unit-test`, `make composer {ARGS}`,
and so on.

Build a minimal PHP/Symfony demo app in Docker, with a simple "hello world" console command and
PHPUnit tests runnable from outside the container via `make unit-test`. The demo app itself isn't
the point — it just needs to exist so there's something real for the sandbox to operate on.

Running `gemini` should launch the Docker sandbox automatically and give it access to an MCP
server. Starting point: [ai-intake-mcp](https://github.com/davindermahal/ai-intake-mcp) — not
exactly the end goal, but the general shape: an MCP server the sandboxed CLI can actually reach.
From inside the sandbox, with the MCP available, `gemini` should be able to run `make up`,
`make unit-test`, `make composer {ARGS}`, etc. against the project.

**Focus is the sandboxing** — getting Docker-outside-of-Docker and MCP access working together
inside Gemini's own sandbox is the actual goal.
