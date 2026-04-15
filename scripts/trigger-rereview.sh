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

# Before triggering, neutralize the old "Review Issues Detected" sticky
# so watchers don't read stale issues in the gap before the new Codex
# review completes. We rewrite it in place rather than deleting so the
# comment history stays intact.
NOTIFICATION_MARKER="<!-- claude-review-notification -->"

# Look up the current latest Codex review ID so the stale body can embed
# it in the `wait-for-review.sh` suggestion. Without this, users would
# get `./scripts/wait-for-review.sh <PR>` with no LAST_REVIEW_ID, which
# exits immediately against any existing review (empty LAST_REVIEW_ID
# never equals a real review id) and causes fetching stale issues.
get_latest_codex_review_id() {
    local reviews_json
    if [[ "$AUTH_METHOD" == "gh" ]]; then
        reviews_json=$(gh api --paginate -H "Accept: application/vnd.github.v3+json" \
            "repos/$REPO/pulls/$PR_NUMBER/reviews" 2>/dev/null | jq -s 'add // []') || echo "[]"
    else
        reviews_json=$(curl_paginate "https://api.github.com/repos/$REPO/pulls/$PR_NUMBER/reviews" 2>/dev/null) || echo "[]"
    fi
    echo "${reviews_json:-[]}" | jq -r '
        [.[] | select(.user.login | test("codex-connector|chatgpt-codex"; "i"))] |
        sort_by(.submitted_at) | .[-1].id // empty
    '
}

# Note on endpoint paths: we pass `repos/...` (no leading slash) to
# `gh api` because MSYS/Git Bash on Windows rewrites paths starting
# with "/" into Windows filesystem paths before the child process
# sees them. `gh api` accepts both forms, so this is portable.

# Follow GitHub's Link: rel="next" header to page through results when
# using token auth. Without this, busy PRs (100+ comments) can have the
# notification sticky beyond page 1, so it never gets neutralized.
curl_paginate() {
    local url="$1"
    local sep="?"
    [[ "$url" == *"?"* ]] && sep="&"
    url="${url}${sep}per_page=100"

    local all="[]"
    local headers_file
    headers_file=$(mktemp)

    while [[ -n "$url" ]]; do
        local body
        body=$(curl -s -D "$headers_file" \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            "$url") || { rm -f "$headers_file"; return 1; }

        all=$(jq -n --argjson a "$all" --argjson b "$body" '$a + ($b // [])')

        url=$(grep -i '^link:' "$headers_file" 2>/dev/null \
              | tr ',' '\n' \
              | grep 'rel="next"' \
              | sed -E 's/.*<([^>]+)>.*/\1/' \
              | head -1 || true)
    done

    rm -f "$headers_file"
    echo "$all"
}

neutralize_sticky() {
    local comment_id
    local existing_json

    if [[ "$AUTH_METHOD" == "gh" ]]; then
        existing_json=$(gh api --paginate \
            -H "Accept: application/vnd.github.v3+json" \
            "repos/$REPO/issues/$PR_NUMBER/comments" 2>/dev/null | jq -s 'add // []') || return 0
    else
        existing_json=$(curl_paginate \
            "https://api.github.com/repos/$REPO/issues/$PR_NUMBER/comments") || return 0
    fi

    comment_id=$(echo "$existing_json" | jq -r --arg m "$NOTIFICATION_MARKER" '
        [.[] | select(.body | contains($m))] | .[-1].id // empty
    ')

    [[ -z "$comment_id" ]] && return 0

    # Build the stale body with the current Codex review ID embedded in
    # the wait-for-review.sh suggestion. wait-for-review.sh treats an
    # empty LAST_REVIEW_ID as "exit on any review", so without this the
    # suggested command would return immediately instead of waiting.
    local prior_review_id
    prior_review_id=$(get_latest_codex_review_id)

    local wait_cmd="./scripts/wait-for-review.sh $PR_NUMBER"
    if [[ -n "$prior_review_id" ]]; then
        wait_cmd="./scripts/wait-for-review.sh $PR_NUMBER $prior_review_id"
    fi

    local stale_body
    stale_body=$(cat <<EOF
$NOTIFICATION_MARKER
<!-- codex-review-id: pending -->
## Fixes pushed — awaiting Codex re-review

The previous review's issues have been addressed and pushed. Any
issue list above this point is **stale** and should be ignored until
a new Codex review completes.

Run \`$wait_cmd\` to block until the next review arrives, then
\`./scripts/fetch-review-issues.sh $PR_NUMBER\` for the fresh issue list.
EOF
)

    local patch_json
    patch_json=$(jq -n --arg body "$stale_body" '{body: $body}')

    if [[ "$AUTH_METHOD" == "gh" ]]; then
        gh api "repos/$REPO/issues/comments/$comment_id" \
            --method PATCH --input - <<< "$patch_json" >/dev/null 2>&1 \
            && echo "Neutralized stale notification comment $comment_id"
    else
        curl -s -X PATCH \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            -d "$patch_json" \
            "https://api.github.com/repos/$REPO/issues/comments/$comment_id" >/dev/null \
            && echo "Neutralized stale notification comment $comment_id"
    fi
}

neutralize_sticky || true

COMMENT_BODY='{"body": "@codex review\n\n*Re-review requested after fixes*"}'

if [[ "$AUTH_METHOD" == "gh" ]]; then
    RESPONSE=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" \
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
