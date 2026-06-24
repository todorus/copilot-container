# Copilot Sandbox

A Docker sandbox for running the **GitHub Copilot CLI** in isolation. Because the
container is disposable and isolated from your host, you can safely let the agent run
with full permissions (`--allow-all-tools`) without risking your machine.

The image comes preinstalled with:

- **GitHub Copilot CLI** (device-flow login, credentials persisted across runs)
- **IBM Semeru JDK 21** + **Maven** (pointed at a private Artifactory)
- A configurable set of **MCP servers** (npm / container / binary), including **Azure DevOps**
- **Azure CLI** (`az`) for Azure DevOps MCP authentication

> Status: work in progress — see `plan` and the per-commit history for current state.

## Quick start

```bash
# 1. Configure your environment
cp .env.example .env
$EDITOR .env

# 2. Build + start an interactive Copilot session
./copilot-sandbox

# 3. Or run a one-shot prompt programmatically
./copilot-sandbox --prompt "Summarize the open work items" --model auto
```

First run requires a one-time `copilot login` (and `az login` for Azure DevOps). Both
use device-flow logins — no manual token copy-pasting — and the credentials are stored
in Docker volumes so you only do it once per machine.

## Documentation

Full setup, authentication, usage, and extension instructions are added incrementally
in this README as the implementation progresses.
