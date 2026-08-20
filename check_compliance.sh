#!/usr/bin/env bash
#
# check_compliance.sh
#
# Runs on a CLIENT's CI runner as part of the JuriCode GitHub Action
# (juricode-gate-action). This script contains NO compliance-checking
# logic of its own — it only calls the hosted JuriCode backend with the
# repo URL and PR number, interprets the response, and sets the exit
# code. All actual EU AI Act analysis happens server-side: the backend
# fetches the repo/PR diff itself (see orchestrator.py's start_node),
# so this script doesn't need GitHub API access at all.
#
# Expected environment (defined in action.yml):
#   JURICODE_API_KEY   - bearer token for the JuriCode backend
#   JURICODE_API_URL   - base URL of the JuriCode backend (no trailing /compliance-gate)
#   FAIL_ON_WARN        - "true" or "false"
#   PR_NUMBER            - pull request number to check
#   REPO_FULL_NAME       - "owner/repo"

set -uo pipefail

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# die: print a clearly-marked error and exit 1. Never pass secret values
# to this function — only static messages / non-secret identifiers.
die() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Step 1: Validate required env vars are set. Fail fast with a clear message
# instead of letting a missing var surface later as a cryptic curl/jq error.
# ---------------------------------------------------------------------------
require_env() {
  local name="$1" value="$2"
  if [ -z "$value" ]; then
    die "Missing required environment variable: ${name}. Check the juricode-gate-action inputs/secrets configuration for this workflow."
  fi
}

require_env "JURICODE_API_KEY" "${JURICODE_API_KEY:-}"
require_env "JURICODE_API_URL" "${JURICODE_API_URL:-}"
require_env "PR_NUMBER" "${PR_NUMBER:-}"
require_env "REPO_FULL_NAME" "${REPO_FULL_NAME:-}"

case "$PR_NUMBER" in
  '' | *[!0-9]*)
    die "PR_NUMBER must be a positive integer, got: '${PR_NUMBER}'"
    ;;
esac

case "$REPO_FULL_NAME" in
  */*) : ;;
  *)
    die "REPO_FULL_NAME must be in 'owner/repo' form, got: '${REPO_FULL_NAME}'"
    ;;
esac

FAIL_ON_WARN="${FAIL_ON_WARN:-false}"

echo "JuriCode compliance check starting for ${REPO_FULL_NAME}#${PR_NUMBER}"

# ---------------------------------------------------------------------------
# Step 2: Build the JSON payload. The backend's /compliance-gate endpoint
# (api/audit.py) only reads url + pr_number — passing them through is what
# makes orchestrator.py's start_node scope the run to the PR diff instead of
# the full repo.
# ---------------------------------------------------------------------------
PAYLOAD_FILE="${WORKDIR}/payload.json"
jq -n \
  --argjson pr_number "$PR_NUMBER" \
  --arg repo_url "https://github.com/${REPO_FULL_NAME}" \
  '{
     url: $repo_url,
     pr_number: $pr_number
   }' > "$PAYLOAD_FILE"

# ---------------------------------------------------------------------------
# Step 3: POST the payload to the JuriCode backend. --fail-with-body makes
# curl exit non-zero on a non-2xx response while still saving the body, so
# an infrastructure failure never gets silently treated as a clean pass.
#
# /compliance-gate runs a multi-agent pipeline synchronously (GitHub fetch +
# ~7 sequential LLM calls across risk/data/robustness/explanatory agents), so
# it can easily take well over 30s even on a good connection — --connect-timeout
# keeps a stuck TCP handshake failing fast, while -m gives the actual request
# a generous budget to let the pipeline finish.
# ---------------------------------------------------------------------------
RESPONSE_FILE="${WORKDIR}/response.json"
http_status=$(curl -sS --connect-timeout 10 -m 300 --fail-with-body \
  -H "JuriCode-API-Key: ${JURICODE_API_KEY}" \
  -H "Content-Type: application/json" \
  --data @"${PAYLOAD_FILE}" \
  -o "$RESPONSE_FILE" -w '%{http_code}' \
  "${JURICODE_API_URL%/}/compliance-gate")
curl_rc=$?
if [ "$curl_rc" -ne 0 ]; then
  die "JuriCode API request failed (HTTP ${http_status:-unknown}). This is an infrastructure/API error, not a compliance finding — verify JURICODE_API_URL and JURICODE_API_KEY, then retry."
fi

# ---------------------------------------------------------------------------
# Step 4: Parse the JSON response. Treat a malformed/incomplete response as
# an infrastructure failure, distinct from a real compliance result.
# ---------------------------------------------------------------------------
if ! jq empty "$RESPONSE_FILE" 2>/dev/null; then
  die "JuriCode API returned a response that is not valid JSON. This indicates a backend problem, not a compliance finding."
fi

SEVERITY=$(jq -r '.severity // empty' "$RESPONSE_FILE")

case "$SEVERITY" in
  block | warn | info) : ;;
  *)
    die "JuriCode API response is missing a valid 'severity' field (got: '${SEVERITY:-<empty>}'). This indicates a backend problem, not a compliance finding."
    ;;
esac

# ---------------------------------------------------------------------------
# Step 5: Print a clear, scannable summary to the workflow log. Findings are
# grouped by their own per-finding severity (block first) — the top-level
# SEVERITY is just the worst of these, so a developer needs to see every
# finding, not only the one that happened to set it, to know what to fix.
#
# There's no top-level confidence: the API deliberately doesn't roll many
# findings' confidences into one number, since that would hide how certain
# any individual finding actually is. Each finding line below carries its
# own confidence instead.
# ---------------------------------------------------------------------------
SEVERITY_UPPER=$(printf '%s' "$SEVERITY" | tr '[:lower:]' '[:upper:]')
ARTICLE_REFS=$(jq -r 'if (.article_refs // []) | length > 0 then (.article_refs | join(", ")) else "none" end' "$RESPONSE_FILE")
FINDINGS_COUNT=$(jq '(.findings // []) | length' "$RESPONSE_FILE")

echo ""
echo "================ JuriCode Compliance Report ================"
echo "Repository:   ${REPO_FULL_NAME}"
echo "Pull Request: #${PR_NUMBER}"
echo "Severity:     ${SEVERITY_UPPER}"
echo "Article refs: ${ARTICLE_REFS}"
echo ""
echo "Findings (${FINDINGS_COUNT} total):"

# print_findings_section: print every finding at a given severity, numbered,
# with its own confidence and article refs appended as the "how sure" and
# "why" behind that finding — or "(none)" if nothing was reported at that
# severity.
print_findings_section() {
  local sev="$1" label="$2" count
  count=$(jq --arg sev "$sev" '[(.findings // [])[] | select(.severity == $sev)] | length' "$RESPONSE_FILE")
  echo "  ${label} (${count}):"
  if [ "$count" -eq 0 ]; then
    echo "    (none)"
    return
  fi
  jq -r --arg sev "$sev" '
    [(.findings // [])[] | select(.severity == $sev)][]
    | if type == "object" then
        (.summary // .message // .description // tostring)
        + " (confidence: " + (if .confidence == null then "n/a" else (.confidence | tostring) end) + ")"
        + (if (.article_refs // []) | length > 0
           then " [" + (.article_refs | join(", ")) + "]"
           else "" end)
      else tostring end
  ' "$RESPONSE_FILE" \
    | nl -ba -w2 -s'. ' \
    | sed 's/^/    /'
}

print_findings_section "block" "BLOCK"
print_findings_section "warn"  "WARN"
print_findings_section "info"  "INFO"
echo "==============================================================="
echo ""

# ---------------------------------------------------------------------------
# Step 6: Exit code logic.
#   block                          -> exit 1
#   warn AND FAIL_ON_WARN == true  -> exit 1
#   otherwise                      -> exit 0
# ---------------------------------------------------------------------------
case "$SEVERITY" in
  block)
    echo "::error::JuriCode blocked this PR (severity=block)."
    exit 1
    ;;
  warn)
    if [ "$FAIL_ON_WARN" = "true" ]; then
      echo "::error::JuriCode reported warnings (severity=warn) and FAIL_ON_WARN=true; failing the check."
      exit 1
    fi
    echo "::warning::JuriCode reported warnings (severity=warn); not failing because FAIL_ON_WARN=false."
    exit 0
    ;;
  info)
    echo "JuriCode reported informational findings only (severity=info); check passed."
    exit 0
    ;;
esac
