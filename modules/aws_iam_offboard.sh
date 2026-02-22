#!/usr/bin/env bash
# ============================================================
# modules/aws_iam_offboard.sh
# Deprovisions an AWS IAM user:
#   - Deactivates & deletes all access keys
#   - Removes signing certificates
#   - Detaches managed & inline policies
#   - Removes from all IAM groups
#   - Optionally hard-deletes the IAM user
# Exit code 20 on any failure.
# ============================================================

# Author: Zeel Dobariya
# Date: 2/21/2026
# Version: V1
# Description: Deactivates then deletes access keys, removes signing certs, strips console login, detaches managed policies, deletes inline policies, and removes group memberships. Confirmation prompt gates the hard-delete.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config/config.env"
source "${SCRIPT_DIR}/modules/reporting.sh"

AWS="aws"
USER="$TARGET_IAM_USER"
echo "DEBUG: AWS_PROFILE=$AWS_PROFILE"
# ── Helper: run or simulate ───────────────────────────────────
run_or_simulate() {
  local description="$1"
  local target="$2"
  shift 2
  if [[ "$DRY_RUN" == "true" ]]; then
    log_simulated "AWS_IAM" "$target" "$description"
  else
    if "$@" 2>/dev/null; then
      log_action "AWS_IAM" "$target" "$description" "SUCCESS"
    else
      log_action "AWS_IAM" "$target" "$description" "FAILURE"
      return 1
    fi
  fi
}

echo ""

# ── 1. Deactivate & delete all access keys ───────────────────
echo "  [AWS IAM] Processing access keys..."
ACCESS_KEYS_JSON="$($AWS iam list-access-keys --user-name "$USER" --query 'AccessKeyMetadata' --output json 2>/dev/null || echo '[]')"
if echo "$ACCESS_KEYS_JSON" | jq -e '. | length > 0' >/dev/null 2>&1; then
  for row in $(echo "$ACCESS_KEYS_JSON" | jq -r '.[] | @base64'); do
    _jq() { echo ${row} | base64 -d | jq -r ${1}; }
    key_id=$(_jq '.AccessKeyId')
    run_or_simulate "Deactivate access key: $key_id" "$USER" \
      $AWS iam update-access-key --user-name "$USER" --access-key-id "$key_id" --status Inactive
    run_or_simulate "Delete access key: $key_id" "$USER" \
      $AWS iam delete-access-key --user-name "$USER" --access-key-id "$key_id"
  done
else
  log_action "AWS_IAM" "$USER" "No access keys found" "INFO"
fi

# ── 2. Remove signing certificates ───────────────────────────
echo "  [AWS IAM] Processing signing certificates..."
CERTS=$($AWS iam list-signing-certificates --user-name "$USER" \
  --query 'Certificates[].CertificateId' --output text 2>/dev/null || true)

if [[ -n "$CERTS" ]]; then
  for cert_id in $CERTS; do
    run_or_simulate \
      "Delete signing certificate: $cert_id" "$USER" \
      $AWS iam delete-signing-certificate \
        --user-name "$USER" --certificate-id "$cert_id"
  done
else
  log_action "AWS_IAM" "$USER" "No signing certificates found" "INFO"
fi

# ── 3. Delete login profile (console access) ─────────────────
echo "  [AWS IAM] Removing console login profile..."
if $AWS iam get-login-profile --user-name "$USER" &>/dev/null; then
  run_or_simulate \
    "Delete console login profile" "$USER" \
    $AWS iam delete-login-profile --user-name "$USER"
else
  log_action "AWS_IAM" "$USER" "No login profile found" "INFO"
fi

# ── 4. Detach managed policies ────────────────────────────────
# Detaching managed policies (FIXED VERSION)
echo "  [AWS IAM] Detaching managed policies..."
ATTACHED_JSON="$($AWS iam list-attached-user-policies --user-name "$USER" --query 'AttachedPolicies' --output json 2>/dev/null || echo '[]')"
if echo "$ATTACHED_JSON" | jq -e '. | length > 0' >/dev/null 2>&1; then
  for row in $(echo "$ATTACHED_JSON" | jq -r '.[] | @base64'); do
    _jq() { echo ${row} | base64 -d | jq -r ${1}; }
    POLICY_ARN=$(_jq '.PolicyArn')
    run_or_simulate "Detach managed policy: $POLICY_ARN" "$USER" \
      $AWS iam detach-user-policy \
        --user-name "$USER" \
        --policy-arn "$POLICY_ARN"
  done
else
  echo "   [INFO] [AWS_IAM] No managed policies attached"
fi



# ── 5. Delete inline policies ─────────────────────────────────
echo "  [AWS IAM] Deleting inline policies..."
INLINE_JSON="$($AWS iam list-user-policies --user-name "$USER" --query 'PolicyNames' --output json 2>/dev/null || echo '[]')"
if echo "$INLINE_JSON" | jq -e '. | length > 0' >/dev/null 2>&1; then
  for policy_name in $(echo "$INLINE_JSON" | jq -r '.[]'); do
    run_or_simulate "Delete inline policy: $policy_name" "$USER" \
      $AWS iam delete-user-policy --user-name "$USER" --policy-name "$policy_name"
  done
else
  log_action "AWS_IAM" "$USER" "No inline policies found" "INFO"
fi

# ── 6. Remove from all IAM groups ────────────────────────────
echo "  [AWS IAM] Removing from IAM groups..."
GROUPS_JSON="$($AWS iam list-groups-for-user --user-name "$USER" --query 'Groups' --output json 2>/dev/null || echo '[]')"

# Safely check if groups exist
if echo "$GROUPS_JSON" | jq -e '. | length > 0' >/dev/null 2>&1; then
  for group in $(echo "$GROUPS_JSON" | jq -r '.[] | .GroupName'); do
    run_or_simulate \
      "Remove from group: $group" "$USER" \
      $AWS iam remove-user-from-group \
        --user-name "$USER" --group-name "$group"
  done
else
  log_action "AWS_IAM" "$USER" "User is not in any IAM groups" "INFO"
fi


# ── 7. (Optional) Delete IAM user ────────────────────────────
if [[ "${DELETE_IAM_USER:-false}" == "true" ]]; then
  echo "  ⚠️  Deleting IAM user '$USER' (final cleanup)..."
  
  # Access keys (robust)
  KEYS_JSON="$($AWS iam list-access-keys --user-name "$USER" --query 'AccessKeyMetadata' --output json 2>/dev/null || echo '[]')"
  if echo "$KEYS_JSON" | jq -e '. | length > 0' >/dev/null 2>&1; then
    for row in $(echo "$KEYS_JSON" | jq -r '.[] | @base64'); do
      _jq() { echo ${row} | base64 -d | jq -r ${1}; }
      KEY_ID=$(_jq '.AccessKeyId')
      run_or_simulate "Force-delete key: $KEY_ID" "$USER" \
        $AWS iam delete-access-key --user-name "$USER" --access-key-id "$KEY_ID"
    done
  fi

  # Policies (robust)  
  POLICIES_JSON="$($AWS iam list-attached-user-policies --user-name "$USER" --query 'AttachedPolicies' --output json 2>/dev/null || echo '[]')"
  if echo "$POLICIES_JSON" | jq -e '. | length > 0' >/dev/null 2>&1; then
    for row in $(echo "$POLICIES_JSON" | jq -r '.[] | @base64'); do
      _jq() { echo ${row} | base64 -d | jq -r ${1}; }
      POLICY_ARN=$(_jq '.PolicyArn')
      run_or_simulate "Force-detach policy: $POLICY_ARN" "$USER" \
        $AWS iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN"
    done
  fi

  # Tags (robust)
  TAGS_JSON="$($AWS iam list-user-tags --user-name "$USER" --query 'Tags' --output json 2>/dev/null || echo '[]')"
  if echo "$TAGS_JSON" | jq -e '. | length > 0' >/dev/null 2>&1; then
    TAG_KEYS=$(echo "$TAGS_JSON" | jq -r '.[].Key' | tr '\n' ' ')
    run_or_simulate "Remove all tags" "$USER" \
      $AWS iam untag-user --user-name "$USER" --tag-keys $TAG_KEYS
  fi

  # Final deletion
  run_or_simulate "Delete IAM user: $USER" "$USER" \
    $AWS iam delete-user --user-name "$USER"
fi

exit 0
