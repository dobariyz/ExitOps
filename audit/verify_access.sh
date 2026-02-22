#!/usr/bin/env bash
# ============================================================
# audit/verify_access.sh
# Standalone verification — can be run independently at any time.
# Returns exit code 0 if user has no residual access.
# Returns exit code 99 if residual access is detected.
# Useful as a CI/CD gate after offboarding.
# ============================================================

# Author: Zeel Dobairya
# Date: 2/21/2026
# Version: V1
# Description: Completely standalone. Checks GitHub org/team/repo access and AWS IAM keys/groups/policies. Returns exit code 99 if anything residual is found — pipe this into a CI job for automated compliance checks
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config/config.env"
source "${SCRIPT_DIR}/modules/reporting.sh"

GH_API="https://api.github.com"
AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"
ACCEPT_HEADER="Accept: application/vnd.github+json"
AWS_CMD="aws --profile ${AWS_PROFILE}"

RESIDUAL_FOUND=false

echo ""
echo "  ════════════════════════════════════════"
echo "  🔍 Verifying offboarding for: ${TARGET_GITHUB_USER:-N/A} / ${TARGET_IAM_USER:-N/A}"
echo "  ════════════════════════════════════════"

# ── GitHub: Org membership ────────────────────────────────────
echo ""
echo "  [Verify] GitHub org membership..."
GH_MEMBER=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
  "${GH_API}/orgs/${GITHUB_ORG}/members/${TARGET_GITHUB_USER}")

if [[ "$GH_MEMBER" == "204" ]]; then
  echo "  ❌ RESIDUAL: Still a member of GitHub org ${GITHUB_ORG}"
  log_action "VERIFY" "$TARGET_GITHUB_USER" "RESIDUAL: GitHub org membership still active" "FAILURE"
  RESIDUAL_FOUND=true
else
  echo "  ✅ Not a member of GitHub org"
  log_action "VERIFY" "$TARGET_GITHUB_USER" "GitHub org membership: clean" "SUCCESS"
fi

# ── GitHub: Team memberships ──────────────────────────────────
echo "  [Verify] GitHub team memberships..."
TEAMS=$(curl -s -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
  "${GH_API}/orgs/${GITHUB_ORG}/teams" | jq -r '.[].slug' 2>/dev/null || true)

for team in $TEAMS; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
    "${GH_API}/orgs/${GITHUB_ORG}/teams/${team}/members/${TARGET_GITHUB_USER}")
  if [[ "$STATUS" == "204" ]]; then
    echo "  ❌ RESIDUAL: Still a member of team: $team"
    log_action "VERIFY" "$team" "RESIDUAL: GitHub team membership still active" "FAILURE"
    RESIDUAL_FOUND=true
  fi
done

if [[ "$RESIDUAL_FOUND" == "false" ]]; then
  log_action "VERIFY" "$TARGET_GITHUB_USER" "GitHub team memberships: clean" "SUCCESS"
fi

# ── GitHub: Repo collaborator access ─────────────────────────
echo "  [Verify] GitHub repo collaborator access..."
PAGE=1
REPO_RESIDUAL=false
while true; do
  REPOS=$(curl -s -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
    "${GH_API}/orgs/${GITHUB_ORG}/repos?per_page=100&page=${PAGE}" \
    | jq -r '.[].name' 2>/dev/null || true)
  [[ -z "$REPOS" ]] && break

  for repo in $REPOS; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
      "${GH_API}/repos/${GITHUB_ORG}/${repo}/collaborators/${TARGET_GITHUB_USER}")
    if [[ "$STATUS" == "204" ]]; then
      echo "  ❌ RESIDUAL: Still a collaborator on repo: $repo"
      log_action "VERIFY" "$repo" "RESIDUAL: GitHub repo collaborator access remains" "FAILURE"
      RESIDUAL_FOUND=true
      REPO_RESIDUAL=true
    fi
  done

  REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
  [[ "$REPO_COUNT" -lt 100 ]] && break
  ((PAGE++))
done

if [[ "$REPO_RESIDUAL" == "false" ]]; then
  log_action "VERIFY" "$TARGET_GITHUB_USER" "GitHub repo collaborator access: clean" "SUCCESS"
fi

# ── AWS IAM: Access keys ──────────────────────────────────────
if [[ "${IAM_MODE:-false}" == "true" ]]; then
  echo "  [Verify] AWS IAM access keys..."
  ACTIVE_KEYS=$($AWS_CMD iam list-access-keys --user-name "$TARGET_IAM_USER" \
    --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' \
    --output text 2>/dev/null || true)

  if [[ -n "$ACTIVE_KEYS" ]]; then
    echo "  ❌ RESIDUAL: Active IAM access keys found: $ACTIVE_KEYS"
    log_action "VERIFY" "$TARGET_IAM_USER" "RESIDUAL: Active IAM access keys remain" "FAILURE"
    RESIDUAL_FOUND=true
  else
    echo "  ✅ No active IAM access keys"
    log_action "VERIFY" "$TARGET_IAM_USER" "IAM access keys: clean" "SUCCESS"
  fi

  # AWS IAM: Group memberships
  echo "  [Verify] AWS IAM group memberships..."
 GROUPS_JSON="$(aws iam list-groups-for-user --user-name "$TARGET_IAM_USER" --query 'Groups' --output json 2>/dev/null || echo '[]')"

if echo "$GROUPS_JSON" | jq -e '. | length > 0' >/dev/null 2>&1; then
  echo "  ❌ User still in IAM groups"
  exit 1
else
  echo "  ✅ No IAM group memberships"
fi

# Line ~127-128 - REPLACE WITH:
GROUP_COUNT=0  # Initialize first
if echo "$GROUPS_JSON" | jq -e '. | length > 0' >/dev/null 2>&1; then
  GROUP_COUNT=$(echo "$GROUPS_JSON" | jq 'length')
  echo "  ❌ User still in ${GROUP_COUNT} IAM groups"
  exit 1
else
  echo "  ✅ No IAM group memberships"
fi


  # AWS IAM: Attached policies
  echo "  [Verify] AWS IAM attached policies..."
  POLICIES=$($AWS_CMD iam list-attached-user-policies --user-name "$TARGET_IAM_USER" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)

  if [[ -n "$POLICIES" ]]; then
    echo "  ❌ RESIDUAL: Attached policies remain: $POLICIES"
    log_action "VERIFY" "$TARGET_IAM_USER" "RESIDUAL: IAM policies still attached" "FAILURE"
    RESIDUAL_FOUND=true
  else
    echo "  ✅ No attached IAM policies"
    log_action "VERIFY" "$TARGET_IAM_USER" "IAM attached policies: clean" "SUCCESS"
  fi
fi

# ── AWS SSO: Permission set assignments ───────────────────────
if [[ "${SSO_MODE:-false}" == "true" && -n "${TARGET_SSO_USER_ID:-}" ]]; then
  echo "  [Verify] AWS SSO permission set assignments..."
  SSO_INSTANCE_ARN=$($AWS_CMD sso-admin list-instances \
    --query 'Instances[0].InstanceArn' --output text 2>/dev/null || true)

  # (Simplified check — full account enumeration is in the offboard module)
  if [[ -n "$SSO_INSTANCE_ARN" ]]; then
    log_action "VERIFY" "$TARGET_SSO_USER_ID" \
      "SSO assignment check complete (review audit.json for details)" "INFO"
  fi
fi

# ── Final result ──────────────────────────────────────────────
echo ""
echo "  ════════════════════════════════════════"
if [[ "$RESIDUAL_FOUND" == "true" ]]; then
  echo "  ⚠️  RESULT: Residual access detected — review above"
  echo "  ════════════════════════════════════════"
  exit 99
else
  echo "  ✅ RESULT: No residual access detected — offboarding complete"
  echo "  ════════════════════════════════════════"
  exit 0
fi
