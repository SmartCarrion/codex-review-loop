#!/usr/bin/env bash
#
# Trigger Re-Review
# Posts @codex review comment to trigger a fresh code review
#
# Usage:
#   ./scripts/trigger-rereview.sh <PR_NUMBER>
#
# Environment:
#   GITHUB_TOKEN - Required. GitHub PAT with repo scope
#   REPO         - Required. Repository in owner/repo format
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

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "Error: GITHUB_TOKEN required"
    echo "Set with: export GITHUB_TOKEN=ghp_xxxxx"
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

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    -d '{"body": "@codex review\n\n*Re-review requested after fixes*"}' \
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
