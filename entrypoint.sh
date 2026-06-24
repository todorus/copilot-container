#!/usr/bin/env bash
# =============================================================================
# Copilot Sandbox entrypoint
#
# 1. Renders the MCP server manifest into Copilot's mcp-config.json, substituting
#    ${ENV_VARS} so secrets/URLs are injected at runtime (never baked into image).
# 2. Points npx-based MCP installs at the company npm registry, if configured.
# 3. Sets up secure Artifactory auth via the JFrog CLI (token-file fallback +
#    global Maven resolution config) so `mvn` resolves through Artifactory with no
#    plaintext credentials.
# 4. Execs the requested command (interactive `copilot`, or a programmatic run).
# =============================================================================
set -euo pipefail

MANIFEST="${MCP_SERVERS_MANIFEST:-/opt/copilot-sandbox/mcp/servers.json}"
OUT="${COPILOT_HOME:-$HOME/.copilot}/mcp-config.json"

JFROG_HOME="${JFROG_CLI_HOME_DIR:-$HOME/.jfrog}"
MVN_SENTINEL="${JFROG_HOME}/.mvn-configured"
JF_SERVER_ID="artifactory-sandbox"

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

# --- Artifactory / Maven via JFrog CLI ---------------------------------------
# Note: avoid `jf config show | grep -q` — under `set -o pipefail`, grep -q exits
# on first match and SIGPIPEs `jf config show`, making the pipeline return non-zero.
jf_server_configured() {
  local out; out="$(jf config show 2>/dev/null || true)"
  [[ "$out" == *"Server ID"* ]]
}
jf_current_server_id() {
  local out; out="$(jf config show 2>/dev/null || true)"
  printf '%s\n' "$out" | sed -n 's/^Server ID:[[:space:]]*//p' | head -1
}

setup_artifactory() {
  command -v jf >/dev/null 2>&1 || return 0

  # Option B fallback: configure from a mounted access-token file. The token is
  # passed via stdin (never as an env var or command-line argument).
  local token_file="${ARTIFACTORY_TOKEN_FILE:-}"
  if [[ -n "$token_file" && -s "$token_file" ]]; then
    if [[ -z "${ARTIFACTORY_URL:-}" ]]; then
      echo "[entrypoint] ARTIFACTORY_TOKEN_FILE set but ARTIFACTORY_URL is empty; skipping token config." >&2
    else
      jf config remove "$JF_SERVER_ID" --quiet >/dev/null 2>&1 || true
      if tr -d '\r\n' < "$token_file" | jf config add "$JF_SERVER_ID" \
            --url "$ARTIFACTORY_URL" --access-token-stdin --interactive=false >/dev/null 2>&1; then
        jf config use "$JF_SERVER_ID" >/dev/null 2>&1 || true
        echo "[entrypoint] Configured Artifactory from access-token file." >&2
      else
        echo "[entrypoint] WARNING: failed to configure Artifactory from token file." >&2
      fi
    fi
  fi

  # Generate a global Maven resolution config when a server + resolve repos exist.
  # The sentinel tells the `mvn` shim to route through `jf mvn`.
  rm -f "$MVN_SENTINEL"
  if jf_server_configured; then
    local rel="${ARTIFACTORY_REPO_RESOLVE_RELEASES:-}"
    local snap="${ARTIFACTORY_REPO_RESOLVE_SNAPSHOTS:-}"
    if [[ -n "$rel" && -n "$snap" ]]; then
      local sid; sid="$(jf_current_server_id)"
      if jf mvn-config --global \
            --server-id-resolve "$sid" \
            --repo-resolve-releases "$rel" \
            --repo-resolve-snapshots "$snap" >/dev/null 2>&1; then
        touch "$MVN_SENTINEL"
        echo "[entrypoint] Maven will resolve through Artifactory via 'jf mvn' (server: $sid)." >&2
      else
        echo "[entrypoint] WARNING: 'jf mvn-config' failed; 'mvn' will use defaults." >&2
      fi
    else
      echo "[entrypoint] Artifactory configured, but ARTIFACTORY_REPO_RESOLVE_* unset; 'mvn' uses defaults." >&2
    fi
  fi
}

setup_artifactory || true

# Default to interactive Copilot if nothing was specified.
if [[ "$#" -eq 0 ]]; then
  set -- copilot
fi

exec "$@"
