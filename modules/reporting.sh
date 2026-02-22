#!/usr/bin/env bash
# ============================================================
# modules/reporting.sh — Logging and audit report generation
# Sourced by all other modules. Do not run directly.
# ============================================================

# Author: Zeel Dobariya
# Date: 2/21/2026
# Version: V1
# Description: The shared backbone. Every other module sources this first. It handles log_action, log_simulated, confirm_action prompts, and writing structured JSON to logs/audit.json. Dry-run entries automatically get "status": "SIMULATED".
#
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${SCRIPT_DIR}/logs/audit.json"

# Ensure logs directory exists
mkdir -p "${SCRIPT_DIR}/logs"

# Initialise log file with an opening array bracket if empty
if [[ ! -s "$LOG_FILE" ]]; then
  echo "[]" > "$LOG_FILE"
fi

# ── log_action ────────────────────────────────────────────────
# Usage: log_action <module> <target> <message> <status>
# status: SUCCESS | FAILURE | SIMULATED | INFO
log_action() {
  local module="$1"
  local target="$2"
  local message="$3"
  local status="${4:-INFO}"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # If DRY_RUN is active, override status to SIMULATED (except errors)
  if [[ "${DRY_RUN:-false}" == "true" && "$status" != "FAILURE" && "$status" != "ERROR" ]]; then
    status="SIMULATED"
  fi

  local entry
  entry=$(jq -n \
    --arg ts "$timestamp" \
    --arg mod "$module" \
    --arg tgt "$target" \
    --arg msg "$message" \
    --arg st "$status" \
    --arg dr "${DRY_RUN:-false}" \
    '{timestamp: $ts, module: $mod, target: $tgt, message: $msg, status: $st, dry_run: ($dr == "true")}')

  # Append to JSON array
  local tmp
  tmp=$(mktemp)
  jq --argjson entry "$entry" '. += [$entry]' "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"

  # Also print to stdout with colour coding
  local colour=""
  case "$status" in
    SUCCESS)   colour="\033[0;32m" ;;  # green
    FAILURE|ERROR) colour="\033[0;31m" ;;  # red
    SIMULATED) colour="\033[0;33m" ;;  # yellow
    *)         colour="\033[0;36m" ;;  # cyan
  esac
  echo -e "   ${colour}[${status}]\033[0m [${module}] ${message}"
}

# ── log_simulated ─────────────────────────────────────────────
# Convenience wrapper — always logs as SIMULATED
log_simulated() {
  local module="$1"
  local target="$2"
  local message="$3"
  log_action "$module" "$target" "DRY-RUN: $message" "SIMULATED"
}

# ── confirm_action ────────────────────────────────────────────
# Prompts user to confirm a destructive action.
# In dry-run mode, skips the prompt automatically.
confirm_action() {
  local message="$1"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    return 0
  fi
  echo ""
  echo "  ⚠️  WARNING: $message"
  read -r -p "  Type 'yes' to confirm, anything else to skip: " response
  if [[ "$response" != "yes" ]]; then
    echo "  ↩️  Skipped."
    return 1
  fi
  return 0
}

# ── generate_summary ──────────────────────────────────────────
# Prints a human-readable summary from the audit log
generate_summary() {
  echo ""
  echo "═══════════════ AUDIT SUMMARY ═══════════════"
  echo ""
  local total success failure simulated
  total=$(jq 'length' "$LOG_FILE")
  success=$(jq '[.[] | select(.status == "SUCCESS")] | length' "$LOG_FILE")
  failure=$(jq '[.[] | select(.status == "FAILURE" or .status == "ERROR")] | length' "$LOG_FILE")
  simulated=$(jq '[.[] | select(.status == "SIMULATED")] | length' "$LOG_FILE")

  echo "  Total actions : $total"
  echo "  Successful    : $success"
  echo "  Simulated     : $simulated"
  echo "  Failed        : $failure"
  echo ""

  if [[ "$failure" -gt 0 ]]; then
    echo "  ❌ Failures:"
    jq -r '.[] | select(.status == "FAILURE" or .status == "ERROR") |
      "     • [\(.module)] \(.message)"' "$LOG_FILE"
    echo ""
  fi
  echo "  📄 Full log: ${LOG_FILE}"
  echo "═══════════════════════════════════════════════"
}
