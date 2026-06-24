# Copilot Sandbox

A Docker sandbox for running the **GitHub Copilot CLI** in isolation. Because the
container is disposable and isolated from your host, you can safely let the agent run
with full permissions (`--allow-all-tools`) without risking your machine.

The image comes preinstalled with:

- **GitHub Copilot CLI** — device-flow login, credentials persisted across runs
- **IBM Semeru JDK 21** + **Maven** — Maven routed through your private Artifactory
- A configurable set of **MCP servers** (npm / binary / container / remote), incl. **Azure DevOps**
- **Azure CLI** (`az`) — used by the Azure DevOps MCP for authentication

Everything is driven by one wrapper script: [`copilot-sandbox`](./copilot-sandbox).

---

## Prerequisites

- **Docker** (Docker Desktop or compatible) running on your machine.
- A **GitHub Copilot** subscription.
- Access to your company **Artifactory**, **MCP registry**, and **Azure DevOps** org.

## Setup

```bash
# 1. Configure your environment
cp .env.example .env
$EDITOR .env            # fill in Artifactory, MCP registry, Azure DevOps org

# 2. Build the image (also happens automatically on first run)
./copilot-sandbox build
```

### One-time logins (device flow — no token copy-pasting)

Credentials are stored in Docker volumes, so you only do this once per machine.

```bash
./copilot-sandbox login      # GitHub Copilot — follow the device-flow URL/code
./copilot-sandbox az-login   # Azure (for the Azure DevOps MCP) — device flow
```

## Usage

```bash
# Interactive session
./copilot-sandbox

# One-shot prompt (programmatic mode, runs with --allow-all-tools)
./copilot-sandbox -p "Summarize the open work items in my project"

# One-shot prompt with a specific model
./copilot-sandbox -p "Refactor the auth module" --model gpt-5.5

# Open a shell inside the sandbox (debugging)
./copilot-sandbox shell

# Force an image rebuild
./copilot-sandbox --build           # rebuild, then run
./copilot-sandbox build             # rebuild only
```

The agent has Java 21, Maven, and `git` available, and checks out repositories from
Azure DevOps via the Azure DevOps MCP into its persisted workspace.

---

## Configuration

All runtime configuration lives in `.env` (copied from [`.env.example`](./.env.example)).
`.env` is gitignored — **never commit real credentials**.

| Variable | Purpose |
| --- | --- |
| `COPILOT_DEFAULT_MODEL` | Default model for programmatic mode (`--model` overrides). |
| `ARTIFACTORY_URL` | Full URL of the Artifactory virtual repo used as the Maven mirror. |
| `ARTIFACTORY_USERNAME` / `ARTIFACTORY_PASSWORD` | Artifactory credentials (token preferred). |
| `MCP_NPM_REGISTRY` | npm-compatible registry for installing `npx`-based MCP servers. |
| `MCP_OCI_REGISTRY` | OCI/Docker registry for container-based MCP servers (optional). |
| `AZURE_DEVOPS_ORG` | Your Azure DevOps organization name. |

### Maven / Artifactory

[`maven/settings.xml`](./maven/settings.xml) mirrors **all** dependency/plugin resolution
through `ARTIFACTORY_URL` and authenticates with `ARTIFACTORY_USERNAME` /
`ARTIFACTORY_PASSWORD`. Values are resolved from environment variables at Maven runtime,
so no credentials are baked into the image.

To use a fully custom settings file, mount your own over
`/home/copilot/.m2/settings.xml`.

### MCP servers

The set of MCP servers is defined in [`mcp/servers.json`](./mcp/servers.json) — **this is
the one file you edit to add or remove servers.** The manifest path is set by a config
variable near the top of the [`Dockerfile`](./Dockerfile) (`MCP_SERVERS_MANIFEST`).

At container start, [`entrypoint.sh`](./entrypoint.sh) renders the **enabled** entries into
Copilot's `~/.copilot/mcp-config.json`, substituting `${ENV_VARS}` so secrets/URLs are
injected at runtime (never committed or baked into the image). `npx`-based installs go
through `MCP_NPM_REGISTRY`.

Each manifest entry supports these shapes:

```jsonc
// npm package (stdio) — installed via npx from your MCP_NPM_REGISTRY
{ "name": "context7", "enabled": true, "type": "local",
  "command": "npx", "args": ["-y", "@upstash/context7-mcp"], "env": {}, "tools": ["*"] }

// local binary (stdio)
{ "name": "my-tool", "enabled": true, "type": "local",
  "command": "/usr/local/bin/my-mcp-server", "args": ["--stdio"], "env": {}, "tools": ["*"] }

// container image (stdio) — from your MCP_OCI_REGISTRY (requires Docker access)
{ "name": "boxed", "enabled": true, "type": "local",
  "command": "docker", "args": ["run", "-i", "--rm", "${MCP_OCI_REGISTRY}/team/my-mcp:latest"],
  "env": {}, "tools": ["*"] }

// remote HTTP/SSE endpoint
{ "name": "remote", "enabled": true, "type": "http",
  "url": "https://mcp.example.com/mcp",
  "headers": { "Authorization": "Bearer ${EXAMPLE_MCP_TOKEN}" }, "tools": ["*"] }
```

Use `${ENV_VAR}` anywhere a value should come from `.env`. Add the corresponding
variable to `.env` / `.env.example`. Set `"enabled": false` to keep an entry as a
disabled template.

### Authenticated MCP servers & vendor CLIs

Some MCP servers (and vendor CLIs) need credentials. Two patterns:

1. **Token via env var** — reference `${SOME_TOKEN}` in the server's `env`/`headers` in
   `mcp/servers.json` and define it in `.env`.
2. **Interactive login persisted in a volume** — like the **Azure DevOps** server, which
   authenticates with `az login` (run `./copilot-sandbox az-login` once; `~/.azure` is a
   persisted volume).

**Adding another vendor CLI** (e.g. AWS CLI, `gh`): add its install step in the
`Azure CLI` section of the [`Dockerfile`](./Dockerfile) (the documented extension point),
rebuild, and persist its credential directory by adding a named volume in the
[`copilot-sandbox`](./copilot-sandbox) script.

---

## How it works

```
copilot-sandbox  ──docker run──►  ENTRYPOINT entrypoint.sh
   │  (.env, named volumes)            │
   │                                   ├─ render mcp/servers.json ─► ~/.copilot/mcp-config.json
   │                                   ├─ point npx at MCP_NPM_REGISTRY
   │                                   └─ exec: copilot  |  copilot -p ... --allow-all-tools
   │
   └─ persisted volumes:
        copilot-sandbox-copilot   → ~/.copilot   (Copilot login)
        copilot-sandbox-azure     → ~/.azure     (az login)
        copilot-sandbox-workspace → ~/workspace  (checked-out code)
```

## Security notes

- Programmatic mode runs Copilot with `--allow-all-tools`; this is safe **only** because
  the container is isolated. Don't add a host bind-mount of sensitive directories.
- No secrets are baked into the image — Artifactory/MCP credentials are injected at
  runtime via `.env` env vars, and logins are stored in Docker volumes.
- `.env` and local secrets are gitignored. Keep them out of version control.

## Updating

```bash
./copilot-sandbox --build          # rebuild after editing Dockerfile / servers.json
```

The Copilot CLI version is whatever `npm install -g @github/copilot` resolves at build
time; rebuild to pick up new releases.
