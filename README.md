# 🔐 ExitOps — Developer Offboarding Automation

> A production-grade, modular shell-script automation toolkit for end-to-end deprovisioning of developer access across **GitHub** and **AWS** — built with dry-run safety, structured audit logging, and CI/CD-ready exit codes.

![Shell](https://img.shields.io/badge/Shell-Bash-green?logo=gnu-bash)
![AWS](https://img.shields.io/badge/Cloud-AWS-orange?logo=amazon-aws)
![GitHub](https://img.shields.io/badge/VCS-GitHub-black?logo=github)
![License](https://img.shields.io/badge/License-MIT-blue)
![Status](https://img.shields.io/badge/Status-Production--Ready-brightgreen)

---

## 📌 Table of Contents

- [Why This Exists](#-why-this-exists)
- [What It Does](#-what-it-does)
- [Project Structure](#-project-structure)
- [Prerequisites](#-prerequisites)
- [Setup & Configuration](#-setup--configuration)
- [Usage](#-usage)
- [Dry-Run Mode](#-dry-run-mode)
- [Exit Codes](#-exit-codes)
- [Audit Logging](#-audit-logging)
- [Verification & CI/CD](#-verification--cicd)
- [Security Best Practices](#-security-best-practices)
- [Extending the Toolkit](#-extending-the-toolkit)
- [Troubleshooting](#-troubleshooting)
- [Contributing](#-contributing)
- [License](#-license)

---

## 💡 Why This Exists

Manual developer offboarding is error-prone, inconsistent, and a real security risk. When a developer leaves a team, access revocation typically spans multiple platforms — GitHub repos, AWS IAM users, SSO assignments — and doing it manually means things get missed.

This toolkit automates the entire process from a single command, produces a structured audit trail for compliance, and supports dry-run mode so you can preview every action before applying it.

**Built and tested against a live GitHub repo and real AWS account.**

---

## ✅ What It Does

### GitHub
- Removes user from GitHub organization membership
- Removes user from all teams (inherited repo permissions revoked)
- Removes user as a direct collaborator from all repositories
- Revokes active SAML SSO credential authorizations and tokens

### AWS IAM
- Deactivates and deletes all IAM access keys
- Removes signing certificates
- Deletes console login profile
- Detaches all managed and inline policies
- Removes from all IAM groups
- Removes all user tags
- Optional hard-delete of IAM user with confirmation prompt

### AWS SSO / Identity Center
- Auto-resolves SSO User ID from email
- Removes all account permission set assignments
- Removes Identity Store group memberships
- Optional hard-delete of SSO identity

### Verification
- Standalone audit script that can run independently at any time
- Cross-checks GitHub org, teams, and repo access
- Cross-checks AWS IAM keys, policies, and group memberships
- Returns non-zero exit code if residual access is detected — CI/CD ready

---

## 📁 Project Structure

```
exitops/
├── exitops.sh              # Main entrypoint — orchestrates everything
├── config/
│   └── config.env                # Your credentials & targets (gitignored)
├── modules/
│   ├── github_offboard.sh        # GitHub org, team, repo, SSO token cleanup
│   ├── aws_iam_offboard.sh       # IAM keys, certs, policies, groups, tags
│   ├── aws_sso_offboard.sh       # Identity Center permission sets & groups
│   └── reporting.sh              # Shared logging, confirmation, audit helpers
├── audit/
│   └── verify_access.sh          # Standalone residual-access checker
├── logs/
│   └── audit.json                # Auto-generated structured audit log
├── .gitignore
└── README.md
```

---

## ✅ Prerequisites

### System Requirements

| Tool | Version | Purpose |
|------|---------|---------|
| `bash` | 4.0+ | Script runtime |
| `curl` | Any | GitHub REST API calls |
| `jq` | 1.6+ | JSON parsing |
| `aws` CLI | v2 | AWS IAM & SSO operations |

Install on Ubuntu/Debian:
```bash
sudo apt update && sudo apt install -y curl jq
# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
```

Install on macOS:
```bash
brew install curl jq awscli
```

---

### GitHub Requirements

You need a **Personal Access Token (PAT)** with the following scopes:

| Scope | Why |
|-------|-----|
| `admin:org` | Remove org members and revoke SSO credentials |
| `repo` | Remove collaborators from private repositories |
| `read:org` | List teams and org members |

**Create a PAT:**
1. Go to GitHub → Settings → Developer Settings → Personal Access Tokens → Tokens (classic)
2. Click **Generate new token**
3. Select the scopes listed above
4. Copy the token and store it securely

> ⚠️ You must be an **organization owner** for org-level operations. For personal repos, standard collaborator admin access is sufficient.

---

### AWS Requirements

#### Option A — Admin User with Access Keys (recommended for automation)

Create a dedicated **offboard-admin** IAM user with the following permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:ListAccessKeys",
        "iam:UpdateAccessKey",
        "iam:DeleteAccessKey",
        "iam:ListSigningCertificates",
        "iam:DeleteSigningCertificate",
        "iam:GetLoginProfile",
        "iam:DeleteLoginProfile",
        "iam:ListAttachedUserPolicies",
        "iam:DetachUserPolicy",
        "iam:ListUserPolicies",
        "iam:DeleteUserPolicy",
        "iam:ListGroupsForUser",
        "iam:RemoveUserFromGroup",
        "iam:ListUserTags",
        "iam:UntagUser",
        "iam:DeleteUser",
        "iam:GetUser",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sso-admin:*",
        "identitystore:*"
      ],
      "Resource": "*"
    }
  ]
}
```

#### Option B — IAM Role (for EC2/Lambda/CI environments)

Attach the above policy to an IAM role and use instance profile or assumed role credentials. No access keys needed.

---

## ⚙️ Setup & Configuration

### 1. Clone the repository

```bash
git clone https://github.com/dobariyz/exitops.git
cd exitops
```

### 2. Make scripts executable

```bash
chmod +x exitops.sh modules/*.sh audit/verify_access.sh
```

### 3. Configure your environment

```bash
cp config/config.env config/config.env
nano config/config.env
```

Fill in every value:

```bash
# ── GitHub ────────────────────────────────────────────────────
GITHUB_TOKEN=ghp_yourpersonalaccesstoken     # No quotes needed
GITHUB_ORG=your-org-or-github-username       # e.g. dobariyz
TARGET_GITHUB_USER=username-to-offboard      # GitHub handle

# ── AWS General ───────────────────────────────────────────────
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE       # offboard-admin access key
AWS_SECRET_ACCESS_KEY=yourSecretKeyHere      # offboard-admin secret key
AWS_REGION=us-east-1                         # Your AWS region
AWS_PROFILE=default                          # AWS CLI profile name
AWS_ACCOUNT_ID=123456789012                  # 12-digit AWS account ID

# ── AWS IAM ───────────────────────────────────────────────────
IAM_MODE=true                                # true if using IAM users
TARGET_IAM_USER=iam-username-to-offboard     # IAM username

# ── AWS SSO (comment out if not using SSO) ────────────────────
SSO_MODE=false
# SSO_IDENTITY_STORE_ID=d-1234567890
# TARGET_SSO_USER_EMAIL=user@company.com

# ── Behaviour ─────────────────────────────────────────────────
DRY_RUN=false
GRACE_PERIOD_DAYS=7
```

### 4. Add config.env to .gitignore

```bash
echo "config/config.env" >> .gitignore
echo "logs/" >> .gitignore
```

> ⚠️ **Never commit `config.env` to version control. It contains secrets.**

### 5. Verify setup

```bash
# Verify AWS credentials are working
aws sts get-caller-identity

# Verify GitHub token is valid
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token YOUR_TOKEN" \
  https://api.github.com/user
# Should return 200
```

---

## 🚀 Usage

### Always dry-run first

```bash
./exitops.sh --dry-run
```

This previews every action across GitHub and AWS without making any changes. All actions are logged to `logs/audit.json` as `SIMULATED`.

### Run the full offboarding

```bash
./exitops.sh
```

### Offboard and hard-delete IAM user + SSO identity

```bash
./exitops.sh --delete-iam-user
```

This will prompt for `yes` confirmation before permanently deleting the user. Use with caution — this cannot be undone.

### Run verification only (at any time)

```bash
./audit/verify_access.sh
```

Returns exit code `0` if clean, `99` if residual access is detected.

---

## 🧪 Dry-Run Mode

Dry-run is a first-class feature of this toolkit. When `--dry-run` is passed:

- All actions are printed as `[SIMULATED]` in the terminal
- No API calls are made to GitHub or AWS
- The audit log still records every simulated action with `"dry_run": true`
- Confirmation prompts are automatically skipped
- The verification step is skipped (nothing to verify)

**Example dry-run output:**
```
[SIMULATED] [GITHUB] DRY-RUN: Would remove johndoe from org acme-corp
[SIMULATED] [GITHUB] DRY-RUN: Would remove johndoe as collaborator from backend-api
[SIMULATED] [AWS_IAM] DRY-RUN: Deactivate access key: AKIAIOSFODNN7EXAMPLE
[SIMULATED] [AWS_IAM] DRY-RUN: Detach managed policy: arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
```

---

## 🔢 Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success — clean offboarding or verification passed |
| `1` | Config / input validation failure |
| `2` | Pre-flight check failure (missing tool, user not found) |
| `10` | GitHub offboarding module failure |
| `20` | AWS IAM offboarding module failure |
| `30` | AWS SSO offboarding module failure |
| `99` | Residual access detected (verify mode) |

---

## 📊 Audit Logging

Every action — including dry-run simulations — is logged to `logs/audit.json` in structured JSON:

```json
[
  {
    "timestamp": "2026-02-22T10:30:00Z",
    "module": "GITHUB",
    "target": "johndoe",
    "message": "Removed johndoe from org acme-corp",
    "status": "SUCCESS",
    "dry_run": false
  },
  {
    "timestamp": "2026-02-22T10:30:01Z",
    "module": "AWS_IAM",
    "target": "john.doe",
    "message": "DRY-RUN: Deactivate access key: AKIAIOSFODNN7EXAMPLE",
    "status": "SIMULATED",
    "dry_run": true
  }
]
```

**Status values:**

| Status | Meaning |
|--------|---------|
| `SUCCESS` | Action completed successfully |
| `FAILURE` | Action failed — check message for details |
| `SIMULATED` | Dry-run — action was previewed, not applied |
| `INFO` | Informational — nothing to action (e.g. no keys found) |

---

## 🔍 Verification & CI/CD

The `verify_access.sh` script is designed to be run independently at any point — not just immediately after offboarding. This is useful for periodic compliance checks.

```bash
# Run standalone at any time
./audit/verify_access.sh

# Use in a CI/CD pipeline (GitHub Actions example)
- name: Verify offboarding
  run: ./audit/verify_access.sh
  # Returns exit code 99 if residual access found — fails the pipeline
```

**What it checks:**

| Check | Platform |
|-------|----------|
| Org membership | GitHub |
| Team memberships | GitHub |
| Repo collaborator access | GitHub |
| Active IAM access keys | AWS |
| IAM group memberships | AWS |
| Attached IAM policies | AWS |
| SSO permission set assignments | AWS (if SSO_MODE=true) |

---

## 🔒 Security Best Practices

This toolkit is designed with security as a first principle:

- **Credentials via environment** — tokens and keys are read from `config.env` or exported environment variables, never hardcoded
- **No secrets in logs** — `audit.json` contains only action identifiers and timestamps, never credential values
- **Dedicated admin user** — use a purpose-built `offboard-admin` IAM user with minimum required permissions, not root or a personal admin account
- **Dry-run before live** — always run `--dry-run` first to preview changes
- **Confirmation gates** — destructive actions like IAM user deletion require explicit `--delete-iam-user` flag AND a `yes` prompt
- **Gitignore secrets** — `config.env` and `logs/` should always be gitignored
- **Rotate tokens** — rotate your GitHub PAT and AWS keys regularly; treat them as short-lived

---

## 🔧 Extending the Toolkit

The architecture is designed to plug in additional providers. To add a new platform (e.g. Jira, PagerDuty, Artifactory):

1. Create `modules/newprovider_offboard.sh`
2. At the top, source the shared helpers:
   ```bash
   source "${SCRIPT_DIR}/config/config.env"
   source "${SCRIPT_DIR}/modules/reporting.sh"
   ```
3. Use the standard logging functions:
   ```bash
   log_action "NEWPROVIDER" "$TARGET_USER" "Description of action" "SUCCESS"
   log_simulated "NEWPROVIDER" "$TARGET_USER" "Would do X"
   confirm_action "This will permanently delete user from NewProvider"
   ```
4. Return a unique non-zero exit code for failures (e.g. `40`)
5. Add a call block in `exitops.sh` following the existing pattern
6. Add a verification block in `audit/verify_access.sh`

---

## 🛠 Troubleshooting

### GitHub 404 on org membership
If your repo is under a personal account (not an org), the org membership endpoint returns 404. This is expected — the toolkit handles this gracefully and continues to repo collaborator cleanup.

### AWS AccessDenied errors
Your credentials don't have sufficient permissions. Ensure you're using the `offboard-admin` user with the policy defined in the [AWS Requirements](#aws-requirements) section, not the target user's own credentials.

### config.env values not loading
Ensure there are no spaces around the `=` sign and no trailing spaces after values:
```bash
# ✅ Correct
GITHUB_TOKEN=ghp_yourtoken

# ❌ Wrong
GITHUB_TOKEN = ghp_yourtoken
GITHUB_TOKEN=ghp_yourtoken  # trailing space
```

Run this to check for trailing spaces:
```bash
cat -A config/config.env | grep ' \$$'
```

### Script exits silently during pre-flight
Run with debug mode to see every command:
```bash
bash -x ./exitops.sh --dry-run 2>&1 | head -60
```

### AWS CLI using wrong credentials
Verify which identity is active:
```bash
aws sts get-caller-identity
```
If it shows the wrong user, export your admin credentials explicitly:
```bash
export AWS_ACCESS_KEY_ID="your_admin_key"
export AWS_SECRET_ACCESS_KEY="your_admin_secret"
```

---

## 🤝 Contributing

Contributions are welcome! To contribute:

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/add-jira-module`
3. Follow the existing module pattern in `modules/`
4. Test with `--dry-run` before submitting
5. Submit a pull request with a description of what was added/changed

Please ensure:
- No secrets or credentials in any committed files
- All new modules respect the `DRY_RUN` flag
- New modules use `log_action` / `log_simulated` from `reporting.sh`
- Exit codes are unique and documented

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---

## 👤 Author

**Zeel Dobariya**
- GitHub: [@dobariyz](https://github.com/dobariyz)
- LinkedIn: [linkedin.com/in/yourprofile](https://linkedin.com/in/zeeldobariya)

---

> Built from scratch, debugged against a live GitHub repo and real AWS account, and shipped as a production-ready toolkit. If this helped you, consider giving it a ⭐
