#!/usr/bin/env bash
# =============================================================================
# Copilot Sandbox entrypoint
#
# 1. Renders the MCP server manifest into Copilot's mcp-config.json, substituting
#    ${ENV_VARS} so secrets/URLs are injected at runtime (never baked into image).
# 2. Points npx-based MCP installs at the company npm registry, if configured.
# 3. Execs the requested command (interactive `copilot`, or a programmatic run).
# =============================================================================
set -euo pipefail

MANIFEST="${MCP_SERVERS_MANIFEST:-/opt/copilot-sandbox/mcp/servers.json}"
OUT="${COPILOT_HOME:-$HOME/.copilot}/mcp-config.json"

# Route npx-based MCP server installs through the company npm registry.
if [[ -n "${MCP_NPM_REGISTRY:-}" ]]; then
  export NPM_CONFIG_REGISTRY="${MCP_NPM_REGISTRY}"
fi

render_mcp_config() {
  local manifest="$1" out="$2"

  if [[ ! -f "$manifest" ]]; then
    echo "[entrypoint] No MCP manifest at $manifest; skipping MCP config." >&2
    return 0
  fi

  mkdir -p "$(dirname "$out")"

  # Substitute ${ENV_VARS} in the manifest, then transform the array of server
  # definitions into Copilot's { "mcpServers": { "<name>": {...} } } shape,
  # keeping only entries with "enabled": true and dropping helper keys.
  local rendered
  if ! rendered="$(envsubst < "$manifest" | jq '
        {
          mcpServers: (
            [ .[]
              | select(._manifest_meta != true)
              | select(.enabled == true)
              | { (.name): (del(.name, .enabled, ._manifest_meta)) }
            ] | add // {}
          )
        }
      ')"; then
    echo "[entrypoint] ERROR: failed to render MCP config from $manifest" >&2
    return 1
  fi

  printf '%s\n' "$rendered" > "$out"

  local count
  count="$(printf '%s' "$rendered" | jq '.mcpServers | length')"
  echo "[entrypoint] Rendered $count MCP server(s) into $out" >&2
}

render_mcp_config "$MANIFEST" "$OUT"

# Default to interactive Copilot if nothing was specified.
if [[ "$#" -eq 0 ]]; then
  set -- copilot
fi

exec "$@"
