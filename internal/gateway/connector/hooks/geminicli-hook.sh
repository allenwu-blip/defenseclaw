#!/bin/bash
# defenseclaw-managed-hook v7
# DefenseClaw Gemini CLI hook — forwards Gemini hook payloads to the
# DefenseClaw gateway. Intentional policy blocks are returned as JSON.
set -euo pipefail
# Windows: HOME may be unset when agents spawn hooks. Fall back to USERPROFILE.
HOME="${HOME:-${USERPROFILE:-$(cd ~ 2>/dev/null && pwd)}}"
export HOME

HOOK_SOURCE="${BASH_SOURCE[0]:-$0}"
HOOK_LINK_DEPTH=0
while [ -L "$HOOK_SOURCE" ]; do
  HOOK_LINK_DEPTH=$((HOOK_LINK_DEPTH + 1))
  [ "$HOOK_LINK_DEPTH" -le 40 ] || exit 2
  HOOK_PARENT="${HOOK_SOURCE%/*}"
  [ "$HOOK_PARENT" != "$HOOK_SOURCE" ] || HOOK_PARENT="."
  HOOK_BASE="$(cd -P -- "$HOOK_PARENT" 2>/dev/null && pwd)" || exit 2
  if [ -x /usr/bin/readlink ]; then
    HOOK_TARGET="$(/usr/bin/readlink -- "$HOOK_SOURCE")" || exit 2
  elif [ -x /bin/readlink ]; then
    HOOK_TARGET="$(/bin/readlink -- "$HOOK_SOURCE")" || exit 2
  else
    exit 2
  fi
  case "$HOOK_TARGET" in
    /*) HOOK_SOURCE="$HOOK_TARGET" ;;
    *) HOOK_SOURCE="$HOOK_BASE/$HOOK_TARGET" ;;
  esac
done
HOOK_PARENT="${HOOK_SOURCE%/*}"
[ "$HOOK_PARENT" != "$HOOK_SOURCE" ] || HOOK_PARENT="."
HOOK_DIR="$(cd -P -- "$HOOK_PARENT" 2>/dev/null && pwd)" || exit 2
unset HOOK_SOURCE HOOK_LINK_DEPTH HOOK_PARENT HOOK_BASE HOOK_TARGET
{{if .Managed}}
DEFENSECLAW_MANAGED_HOOK=1
export DEFENSECLAW_MANAGED_HOOK
DEFENSECLAW_HOME="$(cd "${HOOK_DIR}/.." && pwd -P)"
export DEFENSECLAW_HOME
{{else}}
DEFENSECLAW_HOME="${DEFENSECLAW_HOME:-${HOME}/.defenseclaw}"
if [ ! -d "${DEFENSECLAW_HOME}" ] || [ -f "${DEFENSECLAW_HOME}/.disabled" ]; then
  exit 0
fi
{{end}}

# Plan B4 / S0.4: shell-side hook hardening — sourced BEFORE the
# missing-token branch so the bypass goes through
# defenseclaw_handle_missing_token and honors
# DEFENSECLAW_STRICT_AVAILABILITY (matches claude-code-hook /
# codex-hook).
. "${HOOK_DIR}/_hardening.sh"
defenseclaw_harden_resources
defenseclaw_harden_env

FAIL_MODE="${DEFENSECLAW_FAIL_MODE:-{{.FailMode}}}"

DEFENSECLAW_HOOK_CONNECTOR="geminicli"
DEFENSECLAW_HOOK_NAME="geminicli-hook"
export DEFENSECLAW_HOOK_CONNECTOR DEFENSECLAW_HOOK_NAME

gemini_allow() {
  printf '%s\n' '{"decision":"allow"}'
  exit 0
}

gemini_deny() {
  _dc_jq -cn --arg reason "${1:-Blocked by DefenseClaw Gemini CLI policy.}" \
    '{decision:"deny",reason:$reason}'
  exit 0
}

if [ ! -f "${HOOK_DIR}/{{.TokenFile}}" ] && [ -z "${DEFENSECLAW_GATEWAY_TOKEN:-}" ]; then
  MISSING_TOKEN_REASON="missing gateway token (.token absent and DEFENSECLAW_GATEWAY_TOKEN unset)"
  defenseclaw_log_hook_failure geminicli geminicli-hook "$MISSING_TOKEN_REASON" transport "$FAIL_MODE"
  if defenseclaw_should_fail_closed_on_unreachable; then
    echo "defenseclaw: ${MISSING_TOKEN_REASON}, blocking geminicli tool (fail mode closed)" >&2
    gemini_deny "DefenseClaw hook failed closed"
  fi
  gemini_allow
fi

PAYLOAD="$(defenseclaw_read_stdin_capped)" || {
  echo "defenseclaw: geminicli hook refusing oversized payload" >&2
  if [ "$FAIL_MODE" = "closed" ]; then
    gemini_deny "DefenseClaw hook payload too large"
  fi
  gemini_allow
}
API_ADDR="{{.APIAddr}}"
if [ "{{if .ScopedToken}}1{{else}}0{{end}}" = "1" ]; then
  DEFENSECLAW_GATEWAY_TOKEN=
  if [ -f "${HOOK_DIR}/{{.TokenFile}}" ]; then
    IFS= read -r DEFENSECLAW_GATEWAY_TOKEN < "${HOOK_DIR}/{{.TokenFile}}" || true
  fi
  export DEFENSECLAW_GATEWAY_TOKEN
elif [ -f "${HOOK_DIR}/{{.TokenFile}}" ] && [ -z "${DEFENSECLAW_GATEWAY_TOKEN:-}" ]; then
  # shellcheck source=/dev/null
  . "${HOOK_DIR}/{{.TokenFile}}"
fi
API_TOKEN="${DEFENSECLAW_GATEWAY_TOKEN:-}"

fail_unreachable() {
  defenseclaw_log_hook_failure geminicli geminicli-hook "$1" transport "$FAIL_MODE"
  defenseclaw_emit_unreachable_stderr "geminicli tool" "$1"
  if defenseclaw_should_fail_closed_on_unreachable; then
    gemini_deny "DefenseClaw hook failed closed"
  fi
  gemini_allow
}

fail_response() {
  defenseclaw_log_hook_failure geminicli geminicli-hook "$1" response "$FAIL_MODE"
  echo "defenseclaw: geminicli hook error: $1" >&2
  if [ "$FAIL_MODE" = "open" ]; then
    gemini_allow
  fi
  gemini_deny "DefenseClaw hook failed closed"
}

AUTH_HEADER_ARGS=()
if [ -n "${API_TOKEN}" ]; then
  AUTH_HEADER_ARGS=(-H "Authorization: Bearer ${API_TOKEN}")
fi

# W3C trace propagation: forward validated traceparent / tracestate.
TRACE_HEADER_ARGS=()
if command -v mapfile >/dev/null 2>&1; then
  mapfile -t TRACE_HEADER_ARGS < <(defenseclaw_extract_trace_context)
fi

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "http://${API_ADDR}/api/v1/geminicli/hook" \
  -H "Content-Type: application/json" \
  -H "X-DefenseClaw-Client: geminicli-hook/1.0" \
  "${AUTH_HEADER_ARGS[@]+"${AUTH_HEADER_ARGS[@]}"}" \
  "${TRACE_HEADER_ARGS[@]+"${TRACE_HEADER_ARGS[@]}"}" \
  --connect-timeout 2 \
  --max-time 10 \
  -d "$PAYLOAD" 2>/dev/null) || {
  fail_unreachable "gateway unreachable"
}

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
RESULT=$(echo "$RESPONSE" | sed '$d')

if [ -z "$HTTP_CODE" ]; then
  fail_unreachable "gateway returned no HTTP status"
elif [ "$HTTP_CODE" -ge 500 ] 2>/dev/null && [ "$HTTP_CODE" -lt 600 ] 2>/dev/null; then
  fail_unreachable "gateway returned HTTP ${HTTP_CODE}"
elif [ "$HTTP_CODE" -lt 200 ] 2>/dev/null || [ "$HTTP_CODE" -ge 300 ] 2>/dev/null; then
  fail_response "gateway returned HTTP ${HTTP_CODE}"
fi

ACTION=$(echo "$RESULT" | _dc_jq -er \
  '.action | select(. == "allow" or . == "block" or . == "confirm")' 2>/dev/null) || {
  fail_response "invalid or missing action in gateway response"
}
OUTPUT=$(echo "$RESULT" | _dc_jq -c '.hook_output // empty' 2>/dev/null) || {
  fail_response "invalid JSON response"
}
if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "null" ]; then
  echo "$OUTPUT"
  exit 0
fi
if [ "$ACTION" = "block" ]; then
  REASON=$(echo "$RESULT" | _dc_jq -r '.reason // "Blocked by DefenseClaw Gemini CLI policy."' 2>/dev/null) || {
    fail_response "invalid block reason in gateway response"
  }
  gemini_deny "$REASON"
fi
gemini_allow
