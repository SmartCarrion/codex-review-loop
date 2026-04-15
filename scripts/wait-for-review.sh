#!/usr/bin/env bash
#
# Wait for a NEW Codex review to appear on a PR.
#
# Usage:
#   ./scripts/wait-for-review.sh <PR_NUMBER> [LAST_REVIEW_ID] [MAX_WAIT_SECONDS]
#
# Exits 0 when a new Codex review is found (review id different from
# LAST_REVIEW_ID, or any Codex review if LAST_REVIEW_ID is omitted).
# Exits 2 on timeout.
#
# Why this exists:
#   Replaces `sleep 120 && ./scripts/fetch-review-issues.sh` combinators
#   that trip permission prompts every iteration. One script, one allowed
#   command, deterministic wait — no guessing about Codex review latency.
#
# Environment:
#   GITHUB_TOKEN       - GitHub PAT with repo scope (or use gh CLI auth)
#   REPO               - Repository in owner/repo format (auto-detected)
#   POLL_INTERVAL      - Seconds between polls (default 20)
#

set -euo pipefail

PR_NUMBER="${1:-}"
LAST_REVIEW_ID="${2:-}"
MAX_WAIT="${3:-600}"   # 10 minutes default
POLL_INTERVAL="${POLL_INTERVAL:-20}"

if [[ -z "$PR_NUMBER" ]]; then
    echo "Usage: $0 <PR_NUMBER> [LAST_REVIEW_ID] [MAX_WAIT_SECONDS]"
    exit 1
fi

REPO_DETECTED=false
if [[ -z "${REPO:-}" ]]; then
    REPO=$(git remote get-url origin 2>/dev/null | sed -n 's#.*github.com[:/]\([^/]*/[^/ ]*\).*#\1#p' | sed 's/\.git$//' || echo "")
    [[ -n "$REPO" ]] && REPO_DETECTED=true
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
    exit 1
fi

if [[ -z "${REPO:-}" ]]; then
    echo "Error: REPO required (auto-detect failed)"
    echo "Set with: export REPO=owner/repo-name"
    exit 1
fi
if [[ "$REPO_DETECTED" == true ]]; then
    echo "Detected repo: $REPO"
fi

fetch_reviews() {
    if [[ "$AUTH_METHOD" == "gh" ]]; then
        gh api --paginate -H "Accept: application/vnd.github.v3+json" \
            "/repos/$REPO/pulls/$PR_NUMBER/reviews" 2>/dev/null | jq -s 'add // []'
    else
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github.v3+json" \
             "https://api.github.com/repos/$REPO/pulls/$PR_NUMBER/reviews?per_page=100"
    fi
}

echo "Waiting for new Codex review on PR #$PR_NUMBER (max ${MAX_WAIT}s, polling every ${POLL_INTERVAL}s)..."
[[ -n "$LAST_REVIEW_ID" ]] && echo "Last known review id: $LAST_REVIEW_ID"

START=$(date +%s)
while true; do
    REVIEWS=$(fetch_reviews || echo "[]")

    LATEST_ID=$(echo "$REVIEWS" | jq -r '
        [.[] | select(.user.login | test("codex-connector|chatgpt-codex"; "i"))] |
        sort_by(.submitted_at) | .[-1].id // empty
    ')

    if [[ -n "$LATEST_ID" ]] && [[ "$LATEST_ID" != "$LAST_REVIEW_ID" ]]; then
        echo ""
        echo "New Codex review detected: $LATEST_ID"
        echo "Run: ./scripts/fetch-review-issues.sh $PR_NUMBER"
        exit 0
    fi

    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    if [[ "$ELAPSED" -ge "$MAX_WAIT" ]]; then
        echo ""
        echo "Timed out after ${ELAPSED}s waiting for new Codex review."
        echo "Check the PR manually: https://github.com/$REPO/pull/$PR_NUMBER"
        exit 2
    fi

    printf "."
    sleep "$POLL_INTERVAL"
done
