#!/usr/bin/env bash
# ============================================================
# offboard_user.sh — Main entrypoint
# Usage: ./offboard_user.sh [--dry-run] [--delete-iam-user]
# ============================================================

# Author: Zeel Dobariya
# Date: 2/21/2026
# Version: V1
# Description: The brain. Parses --dry-run and --delete-iam-user flags, exports DRY_RUN to all child modules, runs pre-flight checks, orchestrates the three m# odules in sequence, collects exit codes, and runs the final verification.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/config.env"
LOG_FILE="${SCRIPT_DIR}/logs/audit.json"

# ── Default flags ────────────────────────────────────────────
DRY_RUN=false
export DRY_RUN

DELETE_IAM_USER=false

# ── Parse arguments ──────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run)        export DRY_RUN=true ;;
    --delete-iam-user) DELETE_IAM_USER=true ;;
    --help)
      echo "Usage: $0 [--dry-run] [--delete-iam-user]"
      echo "  --dry-run          Preview all actions without applying them"
      echo "  --delete-iam-user  Hard-delete IAM user (requires confirmation)"
      exit 0
      ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

export DELETE_IAM_USER

# ── Load helpers ─────────────────────────────────────────────
source "${SCRIPT_DIR}/modules/reporting.sh"

# ── Banner ───────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        Developer Offboard Toolkit        ║"
if [[ "$DRY_RUN" == "true" ]]; then
echo "║          ⚠️  DRY-RUN MODE ACTIVE  ⚠️         ║"
fi
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Load config ──────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  log_action "ERROR" "CONFIG" "config.env not found at $CONFIG_FILE" "FAILURE"
  echo "❌ config/config.env not found. Copy and fill in config/config.env first."
  exit 1
fi
source "$CONFIG_FILE"

# ── Input validation ─────────────────────────────────────────
ERRORS=()
[[ -z "${GITHUB_TOKEN:-}"        ]] && ERRORS+=("GITHUB_TOKEN is not set")
[[ -z "${GITHUB_ORG:-}"          ]] && ERRORS+=("GITHUB_ORG is not set")
[[ -z "${TARGET_GITHUB_USER:-}"  ]] && ERRORS+=("TARGET_GITHUB_USER is not set")
[[ -z "${AWS_PROFILE:-}"         ]] && ERRORS+=("AWS_PROFILE is not set")

if [[ "${IAM_MODE:-false}" == "true" && -z "${TARGET_IAM_USER:-}" ]]; then
  ERRORS+=("IAM_MODE=true but TARGET_IAM_USER is not set")
fi
if [[ "${SSO_MODE:-false}" == "true" && -z "${SSO_IDENTITY_STORE_ID:-}" ]]; then
  ERRORS+=("SSO_MODE=true but SSO_IDENTITY_STORE_ID is not set")
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "❌ Configuration errors:"
  for err in "${ERRORS[@]}"; do echo "   • $err"; done
  log_action "ERROR" "CONFIG" "Validation failed: ${ERRORS[*]}" "FAILURE"
  exit 1
fi

# ── Pre-flight checks ────────────────────────────────────────
echo "🔍 Running pre-flight checks..."

# Check required tools
for tool in curl jq aws; do
  if ! command -v "$tool" &>/dev/null; then
    echo "❌ Required tool not found: $tool"
    log_action "ERROR" "PREFLIGHT" "Missing tool: $tool" "FAILURE"
    exit 2
  fi
done

# Check GitHub user exists in org
GH_ORG_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${GITHUB_ORG}/members/${TARGET_GITHUB_USER}")

if [[ "$GH_ORG_CHECK" != "204" && "$GH_ORG_CHECK" != "302" ]]; then
  echo "⚠️  GitHub user '${TARGET_GITHUB_USER}' not found in org ${GITHUB_ORG} (HTTP $GH_ORG_CHECK)"
  echo "   Continuing anyway (repo collaborator check will handle cleanup)..."
else
  echo "   ✅ GitHub user found in org"
fi

# Check AWS IAM user exists (if IAM mode)
if [[ "${IAM_MODE:-false}" == "true" && "${SKIP_IAM:-false}" != "true" ]]; then
if ! aws iam get-user --user-name "$TARGET_IAM_USER" &>/dev/null; then
    echo "ℹ️  AWS IAM user '${TARGET_IAM_USER}' not found — already removed"
    log_action "INFO" "PREFLIGHT" "IAM user already removed" "SUCCESS"
    export SKIP_IAM=true
else
    echo "   ✅ AWS IAM user found"
    export SKIP_IAM=false
fi
fi
echo "   ✅ All pre-flight checks passed"
echo ""

# ── Track overall status ─────────────────────────────────────
EXIT_CODE=0

# ── Step 1: GitHub offboarding ───────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 1/3 — GitHub Offboarding"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if bash "${SCRIPT_DIR}/modules/github_offboard.sh"; then
  echo "✅ GitHub offboarding complete"
else
  echo "❌ GitHub offboarding failed (exit code 10)"
  EXIT_CODE=10
fi
echo ""

# ── Step 2: AWS IAM offboarding ──────────────────────────────
if [[ "${IAM_MODE:-false}" == "true" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  STEP 2/3 — AWS IAM Offboarding"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if bash "${SCRIPT_DIR}/modules/aws_iam_offboard.sh"; then
    echo "✅ AWS IAM offboarding complete"
  else
    echo "❌ AWS IAM offboarding failed (exit code 20)"
    [[ $EXIT_CODE -eq 0 ]] && EXIT_CODE=20
  fi
  echo ""
fi

# ── Step 3: AWS SSO offboarding ──────────────────────────────
if [[ "${SSO_MODE:-false}" == "true" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  STEP 3/3 — AWS SSO Offboarding"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if bash "${SCRIPT_DIR}/modules/aws_sso_offboard.sh"; then
    echo "✅ AWS SSO offboarding complete"
  else
    echo "❌ AWS SSO offboarding failed (exit code 30)"
    [[ $EXIT_CODE -eq 0 ]] && EXIT_CODE=30
  fi
  echo ""
fi

# ── Final verification ────────────────────────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Running post-offboarding verification..."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if bash "${SCRIPT_DIR}/audit/verify_access.sh"; then
    echo "✅ Verification passed — no residual access detected"
  else
    echo "⚠️  Residual access detected! Check logs/audit.json"
    [[ $EXIT_CODE -eq 0 ]] && EXIT_CODE=99
  fi
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
if [[ $EXIT_CODE -eq 0 ]]; then
echo "║  ✅ Offboarding completed successfully   ║"
else
echo "║  ⚠️  Offboarding completed with errors    ║"
fi
if [[ "$DRY_RUN" == "true" ]]; then
echo "║     (DRY-RUN — no changes were made)    ║"
fi
echo "╚══════════════════════════════════════════╝"
echo "📄 Audit log: ${LOG_FILE}"
echo ""

exit $EXIT_CODE
