# Copilot Sandbox

A Docker sandbox for running the **GitHub Copilot CLI** in isolation. Because the
container is disposable and isolated from your host, you can safely let the agent run
with full permissions (`--allow-all-tools`) without risking your machine.

The image comes preinstalled with:

- **GitHub Copilot CLI** — device-flow login, credentials persisted across runs
- **IBM Semeru JDK 21** + **Maven** — Semeru is installed at image build time; Maven resolves through your private Artifactory via the JFrog CLI (no plaintext credentials)
- A configurable set of **MCP servers** (npm / binary / container / remote), incl. **Azure DevOps**
- **Azure CLI** (`az`) and **JFrog CLI** (`jf`) — for Azure DevOps and Artifactory auth

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
# fill in Artifactory, MCP registry, Azure DevOps org
```    

```bash
# 2. If the base image is pulled from a private registry, log in first
./copilot-sandbox docker-login   # you may need to use a PAT instead of your password
```

```bash
# 3. Build the image (also happens automatically on first run)
./copilot-sandbox build
```

### One-time logins (device flow — no token copy-pasting)

Credentials are stored in Docker volumes, so you only do this once per machine.

```bash
./copilot-sandbox login      # GitHub Copilot — follow the device-flow URL/code
./copilot-sandbox az-login   # Azure (for the Azure DevOps MCP) — device flow
./copilot-sandbox jf-login   # Artifactory (Maven) — JFrog browser/device flow
```

If your **base image** is hosted on a private Docker registry (i.e. you set
`BASE_IMAGE_REGISTRY` to something other than the public `docker.io`), also log the
host Docker CLI into that registry once, so `build` can pull the base image:

```bash
./copilot-sandbox docker-login   # docker login against BASE_IMAGE_REGISTRY
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
| `BASE_IMAGE_REGISTRY` | Registry the base image is pulled from at build time (default `docker.io`). |
| `BASE_IMAGE` | Base image name:tag pulled from the registry (default `ubuntu:noble`). |
| `ARTIFACTORY_URL` | JFrog Platform URL (not a secret). |
| `ARTIFACTORY_REPO_RESOLVE_RELEASES` / `ARTIFACTORY_REPO_RESOLVE_SNAPSHOTS` | Maven resolution repos in Artifactory. |
| `ARTIFACTORY_TOKEN_FILE` | Fallback only: host path to a file holding a scoped access token. |
| `MCP_NPM_REGISTRY` | npm-compatible registry for installing `npx`-based MCP servers. |
| `MCP_OCI_REGISTRY` | OCI/Docker registry for container-based MCP servers (optional). |
| `AZURE_DEVOPS_ORG` | Your Azure DevOps organization name. |

### Base image registry

By default the base image (`ubuntu:noble`) is pulled from Docker Hub. To pull it
from a company registry or mirror instead, set `BASE_IMAGE_REGISTRY` in `.env` to
the registry host:

```dotenv
BASE_IMAGE_REGISTRY=registry.mycompany.com
```

The image is resolved as `${BASE_IMAGE_REGISTRY}/${BASE_IMAGE}`. If your registry
stores the image under a different path or tag, override `BASE_IMAGE` too. The
`copilot-sandbox` wrapper passes both values to `docker build` automatically, so a
plain `./copilot-sandbox build` (or first run) picks them up.

> **JDK download at build time.** The base image no longer bundles a JDK — IBM
> Semeru (Open) JDK 21 is downloaded from the
> [`ibmruntimes/semeru21-binaries`](https://github.com/ibmruntimes/semeru21-binaries/releases)
> GitHub releases during `build` (like Node.js and Maven). Pin or override the
> version with the `SEMERU_RELEASE` and `SEMERU_PKG_VERSION` build args (defaults
> are set in the `Dockerfile`).

**Authenticating to a private registry.** If the registry requires a login, run:

```bash
./copilot-sandbox docker-login   # runs `docker login ${BASE_IMAGE_REGISTRY}`
```

This logs the **host** Docker CLI into `BASE_IMAGE_REGISTRY` and then follows the
registry's normal login flow. Do this once before the first `build` (the build
pulls the base image, so it fails with an auth error otherwise). Many registries
(e.g. JFrog Artifactory, Azure Container Registry, GitHub Container Registry) do
**not** accept your account password at the prompt — generate a **Personal Access
Token (PAT)** scoped for the registry and paste that as the password instead. The
default registry (`docker.io`) is public and needs no login.

### Maven / Artifactory

Artifactory authentication goes through the **JFrog CLI** — there are **no plaintext
credentials** in environment variables, `.env`, or the image. Two ways to authenticate:

- **Preferred — `./copilot-sandbox jf-login`:** a JFrog browser/device-style web login
  (Artifactory 7.64.0+). The credential is stored in the persisted `~/.jfrog` volume
  (do it once per machine), consistent with the Copilot/Azure logins.
- **Fallback — access-token file:** generate a scoped, revocable Artifactory access
  token and write it to `secrets/artifactory-token` (or set `ARTIFACTORY_TOKEN_FILE`).
  The wrapper mounts it read-only and configures it via **stdin**, so the token never
  appears in env vars or `docker inspect`.

At container start, the entrypoint generates a global `jf mvn-config` from
`ARTIFACTORY_REPO_RESOLVE_*`. A transparent `mvn` shim then routes `mvn` through
`jf mvn`, so dependency resolution authenticates against Artifactory automatically.
If JFrog isn't configured, `mvn` falls back to plain Maven.

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
   │                                   ├─ configure Artifactory (jf) + global mvn-config
   │                                   └─ exec: copilot  |  copilot -p ... --allow-all-tools
   │
   └─ persisted volumes:
        copilot-sandbox-copilot   → ~/.copilot   (Copilot login)
        copilot-sandbox-azure     → ~/.azure     (az login)
        copilot-sandbox-jfrog     → ~/.jfrog     (jf login / Artifactory token)
        copilot-sandbox-workspace → ~/workspace  (checked-out code)
```

## Security notes

- Programmatic mode runs Copilot with `--allow-all-tools`; this is safe **only** because
  the container is isolated. Don't add a host bind-mount of sensitive directories.
- **No secrets are baked into the image or passed as env vars.** Artifactory auth uses the
  JFrog CLI credential store (web login) or a token fed via stdin from a read-only mounted
  file — never via `-e`/`docker inspect`. Copilot and Azure logins are stored in Docker volumes.
- `.env`, the `secrets/` directory, and other local secrets are gitignored. Keep them out
  of version control.

## Updating

```bash
./copilot-sandbox --build          # rebuild after editing Dockerfile / servers.json
```

The Copilot CLI version is whatever `npm install -g @github/copilot` resolves at build
time; rebuild to pick up new releases.
