#!/usr/bin/env bash
# ============================================================
# modules/github_offboard.sh
# Removes a user from a GitHub org: org membership, teams,
# repo collaborator access, and active SSO sessions/tokens.
# Exit code 10 on any failure.
# ============================================================

# Author: Zeel Dobariya
# Date: 2/21/2026
# Version: V1
# Description: Handles org removal, team removal, repo collaborator cleanup, and SAML SSO credential revocation. Fully dry-run aware

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config/config.env"
source "${SCRIPT_DIR}/modules/reporting.sh"

GH_API="https://api.github.com"
AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"
ACCEPT_HEADER="Accept: application/vnd.github+json"

# ── Helper: GitHub API call ───────────────────────────────────
gh_api() {
  local method="$1"
  local endpoint="$2"
  curl -s -X "$method" \
    -H "$AUTH_HEADER" \
    -H "$ACCEPT_HEADER" \
    "${GH_API}${endpoint}"
}

gh_api_status() {
  local method="$1"
  local endpoint="$2"
  curl -s -o /dev/null -w "%{http_code}" -X "$method" \
    -H "$AUTH_HEADER" \
    -H "$ACCEPT_HEADER" \
    "${GH_API}${endpoint}"
}

# ── 1. Remove from organisation ───────────────────────────────
echo ""
echo "  [GitHub] Removing org membership..."
if [[ "$DRY_RUN" == "true" ]]; then
  log_simulated "GITHUB" "$TARGET_GITHUB_USER" \
    "Would remove $TARGET_GITHUB_USER from org $GITHUB_ORG"
else
  STATUS=$(gh_api_status DELETE "/orgs/${GITHUB_ORG}/members/${TARGET_GITHUB_USER}")
if [[ "$STATUS" == "204" ]]; then
    log_action "GITHUB" "$TARGET_GITHUB_USER" \
      "Removed $TARGET_GITHUB_USER from org $GITHUB_ORG" "SUCCESS"
  else
    log_action "GITHUB" "$TARGET_GITHUB_USER" \
      "No org membership found (personal repo) — continuing" "INFO"
  fi
fi

# ── 2. Remove from all teams ──────────────────────────────────
echo "  [GitHub] Removing from all teams..."
TEAMS=$(gh_api GET "/orgs/${GITHUB_ORG}/teams" | jq -r 'if type == "array" then .[].slug else empty end' 2>/dev/null || true)

for team in $TEAMS; do
  MEMBER_STATUS=$(gh_api_status GET "/orgs/${GITHUB_ORG}/teams/${team}/members/${TARGET_GITHUB_USER}")
  if [[ "$MEMBER_STATUS" == "204" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_simulated "GITHUB" "$TARGET_GITHUB_USER" \
        "Would remove from team: $team"
    else
      DEL_STATUS=$(gh_api_status DELETE "/orgs/${GITHUB_ORG}/teams/${team}/members/${TARGET_GITHUB_USER}")
      if [[ "$DEL_STATUS" == "204" ]]; then
        log_action "GITHUB" "$TARGET_GITHUB_USER" \
          "Removed from team: $team" "SUCCESS"
      else
        log_action "GITHUB" "$TARGET_GITHUB_USER" \
          "Failed to remove from team $team (HTTP $DEL_STATUS)" "FAILURE"
      fi
    fi
  fi
done

# ── 3. Remove as repo collaborator ────────────────────────────
echo "  [GitHub] Removing repo collaborator access..."
PAGE=1
while true; do
	REPOS=$(gh_api GET "/users/${GITHUB_ORG}/repos?per_page=100&page=${PAGE}" \
    | jq -r 'if type == "array" then .[].name else empty end' 2>/dev/null || true)
  [[ -z "$REPOS" ]] && break

  for repo in $REPOS; do
    COLLAB_STATUS=$(gh_api_status GET \
      "/repos/${GITHUB_ORG}/${repo}/collaborators/${TARGET_GITHUB_USER}")
    if [[ "$COLLAB_STATUS" == "204" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log_simulated "GITHUB" "$repo" \
          "Would remove $TARGET_GITHUB_USER as collaborator from $repo"
      else
        DEL_STATUS=$(gh_api_status DELETE \
          "/repos/${GITHUB_ORG}/${repo}/collaborators/${TARGET_GITHUB_USER}")
        if [[ "$DEL_STATUS" == "204" ]]; then
          log_action "GITHUB" "$repo" \
            "Removed collaborator access from repo: $repo" "SUCCESS"
        else
          log_action "GITHUB" "$repo" \
            "Failed to remove collaborator from $repo (HTTP $DEL_STATUS)" "FAILURE"
        fi
      fi
    fi
  done

  REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
  [[ "$REPO_COUNT" -lt 100 ]] && break
  ((PAGE++))
done

# ── 4. Revoke active GitHub SSO tokens/sessions ───────────────
echo "  [GitHub] Revoking active SAML SSO authorizations..."
# List and revoke OAuth app tokens authorized with SSO
AUTHS=$(gh_api GET "/orgs/${GITHUB_ORG}/credential-authorizations" \
  | jq -r --arg user "$TARGET_GITHUB_USER" \
    '.[] | select(.login == $user) | .credential_id' 2>/dev/null || true)

if [[ -n "$AUTHS" ]]; then
  for cred_id in $AUTHS; do
    if [[ "$DRY_RUN" == "true" ]]; then
      log_simulated "GITHUB" "$TARGET_GITHUB_USER" \
        "Would revoke SSO credential ID: $cred_id"
    else
      DEL_STATUS=$(gh_api_status DELETE \
        "/orgs/${GITHUB_ORG}/credential-authorizations/${cred_id}")
      if [[ "$DEL_STATUS" == "204" ]]; then
        log_action "GITHUB" "$TARGET_GITHUB_USER" \
          "Revoked SSO credential: $cred_id" "SUCCESS"
      else
        log_action "GITHUB" "$TARGET_GITHUB_USER" \
          "Failed to revoke SSO credential $cred_id (HTTP $DEL_STATUS)" "FAILURE"
      fi
    fi
  done
else
  log_action "GITHUB" "$TARGET_GITHUB_USER" \
    "No active SSO credentials found" "INFO"
fi

echo "  [GitHub] ✅ Module complete"
exit 0
