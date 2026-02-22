#!/usr/bin/env bash
# ============================================================
# modules/aws_sso_offboard.sh
# Deprovisions an AWS IAM Identity Center (SSO) user:
#   - Auto-resolves SSO User ID from email if not set
#   - Removes all permission set assignments
#   - Removes all application assignments
#   - Optionally disables / deletes the SSO identity
# Exit code 30 on any failure.
# ============================================================

# Author: Zeel Dobariya
# Date: 2/21/2026
# Version: V1
# Description: Auto-resolves SSO User ID from email if not supplied, removes permission set assignments across all accounts, removes Identity Store group memberships.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config/config.env"
source "${SCRIPT_DIR}/modules/reporting.sh"

AWS="aws --profile ${AWS_PROFILE}"
STORE_ID="$SSO_IDENTITY_STORE_ID"

# ── Helper: run or simulate ───────────────────────────────────
run_or_simulate() {
  local description="$1"
  local target="$2"
  shift 2
  if [[ "$DRY_RUN" == "true" ]]; then
    log_simulated "AWS_SSO" "$target" "$description"
  else
    if "$@" 2>/dev/null; then
      log_action "AWS_SSO" "$target" "$description" "SUCCESS"
    else
      log_action "AWS_SSO" "$target" "$description" "FAILURE"
      return 1
    fi
  fi
}

echo ""

# ── Resolve SSO User ID ───────────────────────────────────────
echo "  [AWS SSO] Resolving SSO User ID..."
if [[ -z "${TARGET_SSO_USER_ID:-}" ]]; then
  if [[ -z "${TARGET_SSO_USER_EMAIL:-}" ]]; then
    echo "  ❌ Neither TARGET_SSO_USER_ID nor TARGET_SSO_USER_EMAIL set"
    log_action "AWS_SSO" "UNKNOWN" "Cannot resolve SSO user — set TARGET_SSO_USER_ID or TARGET_SSO_USER_EMAIL" "FAILURE"
    exit 30
  fi

  # Auto-resolve from email
  TARGET_SSO_USER_ID=$($AWS identitystore list-users \
    --identity-store-id "$STORE_ID" \
    --filters AttributePath=UserName,AttributeValue="${TARGET_SSO_USER_EMAIL}" \
    --query 'Users[0].UserId' --output text 2>/dev/null || true)

  if [[ -z "$TARGET_SSO_USER_ID" || "$TARGET_SSO_USER_ID" == "None" ]]; then
    log_action "AWS_SSO" "$TARGET_SSO_USER_EMAIL" \
      "SSO user not found by email" "FAILURE"
    exit 30
  fi
  log_action "AWS_SSO" "$TARGET_SSO_USER_EMAIL" \
    "Resolved SSO User ID: $TARGET_SSO_USER_ID" "INFO"
fi

SSO_USER="$TARGET_SSO_USER_ID"

# ── Get SSO Instance ARN ──────────────────────────────────────
SSO_INSTANCE_ARN=$($AWS sso-admin list-instances \
  --query 'Instances[0].InstanceArn' --output text 2>/dev/null)

if [[ -z "$SSO_INSTANCE_ARN" || "$SSO_INSTANCE_ARN" == "None" ]]; then
  log_action "AWS_SSO" "$SSO_USER" "Could not retrieve SSO Instance ARN" "FAILURE"
  exit 30
fi

# ── 1. Remove all account permission set assignments ──────────
echo "  [AWS SSO] Removing permission set assignments..."

# List all AWS accounts accessible via SSO
ACCOUNTS=$($AWS sso-admin list-accounts-for-provisioned-permission-set \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --query 'AccountIds[]' --output text 2>/dev/null || true)

for account_id in $ACCOUNTS; do
  PERMISSION_SETS=$($AWS sso-admin list-permission-sets-provisioned-to-account \
    --instance-arn "$SSO_INSTANCE_ARN" \
    --account-id "$account_id" \
    --query 'PermissionSets[]' --output text 2>/dev/null || true)

  for ps_arn in $PERMISSION_SETS; do
    # Check if this user has this permission set in this account
    ASSIGNMENT=$($AWS sso-admin list-account-assignments \
      --instance-arn "$SSO_INSTANCE_ARN" \
      --account-id "$account_id" \
      --permission-set-arn "$ps_arn" \
      --query "AccountAssignments[?PrincipalId=='${SSO_USER}' && PrincipalType=='USER']" \
      --output text 2>/dev/null || true)

    if [[ -n "$ASSIGNMENT" ]]; then
      run_or_simulate \
        "Remove permission set $ps_arn from account $account_id" "$SSO_USER" \
        $AWS sso-admin delete-account-assignment \
          --instance-arn "$SSO_INSTANCE_ARN" \
          --target-id "$account_id" \
          --target-type AWS_ACCOUNT \
          --permission-set-arn "$ps_arn" \
          --principal-type USER \
          --principal-id "$SSO_USER"
    fi
  done
done

# ── 2. Remove group memberships ───────────────────────────────
echo "  [AWS SSO] Removing group memberships..."
GROUP_MEMBERSHIPS=$($AWS identitystore list-group-memberships-for-member \
  --identity-store-id "$STORE_ID" \
  --member-id "UserId=${SSO_USER}" \
  --query 'GroupMemberships[].MembershipId' --output text 2>/dev/null || true)

if [[ -n "$GROUP_MEMBERSHIPS" ]]; then
  for membership_id in $GROUP_MEMBERSHIPS; do
    run_or_simulate \
      "Remove group membership: $membership_id" "$SSO_USER" \
      $AWS identitystore delete-group-membership \
        --identity-store-id "$STORE_ID" \
        --membership-id "$membership_id"
  done
else
  log_action "AWS_SSO" "$SSO_USER" "No group memberships found" "INFO"
fi

# ── 3. Disable SSO user (optional hard-delete with confirmation) ──
echo "  [AWS SSO] Handling SSO identity..."
if [[ "${DELETE_IAM_USER:-false}" == "true" ]]; then
  echo "  ⚠️  --delete-iam-user flag also triggers SSO user deletion."
  if confirm_action "Permanently delete SSO identity '${SSO_USER}'. This cannot be undone."; then
    run_or_simulate \
      "Hard-delete SSO user: $SSO_USER" "$SSO_USER" \
      $AWS identitystore delete-user \
        --identity-store-id "$STORE_ID" \
        --user-id "$SSO_USER"
  fi
else
  log_action "AWS_SSO" "$SSO_USER" \
    "SSO identity NOT deleted (re-run with --delete-iam-user to hard-delete)" "INFO"
fi

echo "  [AWS SSO] ✅ Module complete"
exit 0
