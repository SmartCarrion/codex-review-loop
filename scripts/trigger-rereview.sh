#!/usr/bin/env bash
#
# Trigger Re-Review
# Posts @codex review comment to trigger a fresh code review
#
# Usage:
#   ./scripts/trigger-rereview.sh <PR_NUMBER>
#
# Environment:
#   GITHUB_TOKEN - GitHub PAT with repo scope (or use gh CLI auth)
#   REPO         - Repository in owner/repo format (auto-detected from git remote)
#

set -euo pipefail

PR_NUMBER="${1:-}"

REPO_DETECTED=false
if [[ -z "${REPO:-}" ]]; then
    # Try to detect from git remote early so it's available for helpful messages
    REPO=$(git remote get-url origin 2>/dev/null | sed -n 's#.*github.com[:/]\([^/]*/[^/ ]*\).*#\1#p' | sed 's/\.git$//' || echo "")
    [[ -n "$REPO" ]] && REPO_DETECTED=true
fi

if [[ -z "$PR_NUMBER" ]]; then
    echo "Usage: $0 <PR_NUMBER>"
    if [[ -n "${REPO:-}" ]]; then
        echo "Find your PR number at: https://github.com/$REPO/pulls"
    fi
    exit 1
fi

# Determine auth method: GITHUB_TOKEN (PAT) or gh CLI
AUTH_METHOD=""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    AUTH_METHOD="token"
elif command -v gh &>/dev/null && gh auth status &>/dev/null; then
    AUTH_METHOD="gh"
else
    echo "Error: No GitHub authentication found"
    echo ""
    echo "Option 1 — GitHub CLI (supports SSH, browser login, etc.):"
    echo "  Install: https://cli.github.com"
    echo "  Then run: gh auth login"
    echo ""
    echo "Option 2 — Personal Access Token:"
    echo "  Create a classic token at: https://github.com/settings/tokens/new"
    echo "  Required scopes: repo, workflow"
    echo "  Then: export GITHUB_TOKEN=your_token"
    echo "  Or add it in Claude app → Settings → Claude Code → Environment Variables"
    exit 1
fi

if [[ -z "${REPO:-}" ]]; then
    echo "Error: REPO required"
    echo "Set with: export REPO=owner/repo-name"
    exit 1
fi
if [[ "$REPO_DETECTED" == true ]]; then
    echo "Detected repo: $REPO"
fi

echo "Triggering re-review for PR #$PR_NUMBER..."

COMMENT_BODY='{"body": "@codex review\n\n*Re-review requested after fixes*"}'

if [[ "$AUTH_METHOD" == "gh" ]]; then
    RESPONSE=$(gh api "/repos/$REPO/issues/$PR_NUMBER/comments" \
        --method POST \
        --input - <<< "$COMMENT_BODY" 2>&1) && HTTP_OK=true || HTTP_OK=false

    if [[ "$HTTP_OK" == "true" ]]; then
        echo "Re-review triggered successfully!"
        echo ""
        echo "Codex will review the PR shortly (typically 1-5 minutes)."
        echo "Check status with: ./scripts/fetch-review-issues.sh $PR_NUMBER"
        echo ""
        echo "PR: https://github.com/$REPO/pull/$PR_NUMBER"
    else
        echo "Failed to trigger re-review"
        echo "$RESPONSE"
        exit 1
    fi
else
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -d "$COMMENT_BODY" \
        "https://api.github.com/repos/$REPO/issues/$PR_NUMBER/comments")

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [[ "$HTTP_CODE" == "201" ]]; then
        echo "Re-review triggered successfully!"
        echo ""
        echo "Codex will review the PR shortly (typically 1-5 minutes)."
        echo "Check status with: ./scripts/fetch-review-issues.sh $PR_NUMBER"
        echo ""
        echo "PR: https://github.com/$REPO/pull/$PR_NUMBER"
    else
        echo "Failed to trigger re-review (HTTP $HTTP_CODE)"
        echo "$BODY" | jq -r '.message // .'
        exit 1
    fi
fi
