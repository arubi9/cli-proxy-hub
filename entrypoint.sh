#!/bin/sh
# Boot CLIProxyAPI on Fly.
#
# Two things have to survive a machine restart:
#   1. the Codex OAuth credential  -- it is REWRITTEN IN PLACE on refresh,
#      so it lives on the volume, not in the image and not in a secret.
#      The secret only SEEDS it on first boot.
#   2. nothing else. config.yaml is regenerated every boot from env, so
#      rotating the API key is just `fly secrets set` + restart.
set -eu
umask 077

DATA_DIR="${DATA_DIR:-/data}"
AUTH_DIR="$DATA_DIR/auths"
CONFIG="$DATA_DIR/config.yaml"
AUTH_FILE="$AUTH_DIR/${CODEX_AUTH_FILENAME:-codex-pro.json}"

mkdir -p "$AUTH_DIR"

# --- seed credential (first boot only) -------------------------------------
# Never overwrite: the on-disk copy may hold a newer refresh_token than the
# secret. Clobbering it would silently revert to a stale token and the
# account would start failing auth days later, far from the cause.
if [ ! -f "$AUTH_FILE" ]; then
  if [ -n "${CODEX_AUTH_JSON:-}" ]; then
    printf '%s' "$CODEX_AUTH_JSON" > "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    echo "[boot] seeded credential -> $AUTH_FILE"
  else
    echo "[boot] WARNING: no credential on volume and CODEX_AUTH_JSON unset."
    echo "[boot] Re-auth headless with:"
    echo "[boot]   fly ssh console -a \$FLY_APP_NAME -C '/CLIProxyAPI/CLIProxyAPI -config $CONFIG -codex-device-login'"
  fi
else
  echo "[boot] using existing credential on volume (refreshed in place)"
fi

# --- config ----------------------------------------------------------------
# API key is MANDATORY. This listener is public on the internet; an
# unauthenticated proxy in front of a paid Codex subscription is somebody
# else's free API within hours of being scanned.
if [ -z "${CPA_API_KEY:-}" ]; then
  echo "[boot] FATAL: CPA_API_KEY unset. Refusing to expose an open proxy."
  exit 1
fi

cat > "$CONFIG" <<EOF
host: ""
port: ${PORT:-8317}
auth-dir: "$AUTH_DIR"
debug: ${CPA_DEBUG:-false}
api-keys:
  - "$CPA_API_KEY"
remote-management:
  allow-remote: false
  secret-key: ""
tls:
  enable: false
discovery:
  enabled: false
# Request logging off: it writes every prompt (merchant statement text) under
# auth-dir/logs and filled the 1 GB volume, which stopped the proxy booting.
# Cap whatever is still written so a burst can never fill the disk again.
server:
  commercial-mode: true   # skip high-overhead request logging/middleware under concurrency
observability:
  logs:
    debug: false
    logging-to-file: false
    logs-max-total-size-mb: 100
    error-logs-max-files: 5
    request-log: false
  usage:
    usage-statistics-enabled: false
# <model>-fast: <model> on the priority service tier (Codex "fast").
# Fable 5.2 needs claude-cli >= 2.1.290; the built-in default is 2.1.280.
claude-header-defaults:
  user-agent: "claude-cli/2.1.319 (external, cli)"
# Listed by this CLIProxyAPI build but rejected upstream (checked 2026-11-10):
# retired Claude models return 404; gpt-6-chat-thinking is not offered to
# ChatGPT-account Codex.
oauth-excluded-models:
  claude:
    - "claude-3-5-haiku-20241022"
    - "claude-3-7-sonnet-20250219"
    - "claude-opus-4-20250514"
    - "claude-opus-4-1-20250805"
    - "claude-sonnet-4-20250514"
  codex:
    - "gpt-6-chat-thinking"
oauth-model-alias:
  # HACK: claude-fable-5-2 is not in this CLIProxyAPI build's model catalog
  # (v8.0.62 still lacks it). Expose fable-5-1 under the new name and rewrite
  # the upstream model field below. REMOVE once the catalog has it.
  claude:
    - name: "claude-fable-5-1"
      alias: "claude-fable-5-2"
      fork: true
  codex:
    - name: "gpt-6-luna"
      alias: "gpt-6-luna-fast"
      fork: true
    - name: "gpt-6.1-sol"
      alias: "gpt-6.1-sol-fast"
      fork: true
    - name: "gpt-5.6-terra"
      alias: "gpt-5.6-terra-fast"
      fork: true
    # HACK: gpt-6.1-terra (launched 2026-10-26) is not in the upstream model
    # catalog yet. Expose gpt-5.6-terra under the new names and rewrite the
    # upstream `model` field below. REMOVE these two aliases and the two
    # rewrite rules once gpt-6.1-terra shows up in /v1/models natively.
    - name: "gpt-5.6-terra"
      alias: "gpt-6.1-terra"
      fork: true
    - name: "gpt-5.6-terra"
      alias: "gpt-6.1-terra-fast"
      fork: true
payload:
  override:
    - models:
        - name: "claude-fable-5-2"
          protocol: "claude"
      params:
        model: claude-fable-5-2
    - models:
        - name: "gpt-6-luna-fast"
          protocol: "codex"
        - name: "gpt-6.1-sol-fast"
          protocol: "codex"
        - name: "gpt-5.6-terra-fast"
          protocol: "codex"
      params:
        service_tier: priority
    - models:
        - name: "gpt-6.1-terra"
          protocol: "codex"
      params:
        model: gpt-6.1-terra
    - models:
        - name: "gpt-6.1-terra-fast"
          protocol: "codex"
      params:
        model: gpt-6.1-terra
        service_tier: priority
EOF

# Keep optional upstream credentials separate from the public listener key.
if [ -n "${REFUSELESS_API_KEY:-}" ]; then
  cat >> "$CONFIG" <<EOF
openai-compatibility:
  - name: "refuseless"
    base-url: "https://api.refuseless.com/v1"
    api-key-entries:
      - api-key: "$REFUSELESS_API_KEY"
    models:
EOF
  for model in glm-5.3-abliterated glm-5.3-flash-abliterated deepseek-v4.1-flash-abliterated deepseek-v4.1-flash-fast minimax-m3.1-flash; do
    cat >> "$CONFIG" <<EOF
      - name: "$model"
        alias: "$model"
        max-context-length: 1048576
        thinking:
          levels: ["low", "high", "max"]
EOF
  done
fi
chmod 600 "$CONFIG"

echo "[boot] CLIProxyAPI on :${PORT:-8317}, auth-dir=$AUTH_DIR"
exec /CLIProxyAPI/CLIProxyAPI -config "$CONFIG"
