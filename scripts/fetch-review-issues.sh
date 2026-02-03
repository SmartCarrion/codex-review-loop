#!/usr/bin/env bash
#
# Fetch Review Issues
# Fetches Codex review feedback and formats it for Claude Code
#
# Usage:
#   ./scripts/fetch-review-issues.sh <PR_NUMBER>
#
# Environment:
#   GITHUB_TOKEN - Required. GitHub PAT with repo scope
#   REPO         - Required. Repository in owner/repo format
#

set -euo pipefail

PR_NUMBER="${1:-}"

if [[ -z "${REPO:-}" ]]; then
    # Try to detect from git remote early so it's available for helpful messages
    REPO=$(git remote get-url origin 2>/dev/null | sed -n 's#.*github.com[:/]\([^/]*/[^/ ]*\).*#\1#p' | sed 's/\.git$//' || echo "")
fi

if [[ -z "$PR_NUMBER" ]]; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -n "$CURRENT_BRANCH" && "$CURRENT_BRANCH" != "main" && "$CURRENT_BRANCH" != "master" ]]; then
        echo "Usage: $0 <PR_NUMBER>"
        echo ""
        echo "Tip: You're on branch '$CURRENT_BRANCH'"
        if [[ -n "${REPO:-}" ]]; then
            echo "Find your PR number at: https://github.com/$REPO/pulls"
        fi
    else
        echo "Usage: $0 <PR_NUMBER>"
    fi
    exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "Error: GITHUB_TOKEN environment variable required"
    echo ""
    echo "Set it with: export GITHUB_TOKEN=ghp_xxxxx"
    echo "Create one at: https://github.com/settings/tokens"
    exit 1
fi

if [[ -z "${REPO:-}" ]]; then
    echo "Error: REPO environment variable required"
    echo ""
    echo "Set it with: export REPO=owner/repo-name"
    exit 1
fi
echo "Detected repo: $REPO"

API_BASE="https://api.github.com"

gh_api() {
    curl -s -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         "$API_BASE$1"
}

echo "Fetching review status for PR #$PR_NUMBER..."
echo ""

# Get PR details
PR_DATA=$(gh_api "/repos/$REPO/pulls/$PR_NUMBER")
BRANCH=$(echo "$PR_DATA" | jq -r '.head.ref')
TITLE=$(echo "$PR_DATA" | jq -r '.title')
STATE=$(echo "$PR_DATA" | jq -r '.state')

if [[ "$STATE" != "open" ]]; then
    echo "PR #$PR_NUMBER is $STATE (not open)"
    exit 0
fi

# Get reviews and comments
REVIEWS=$(gh_api "/repos/$REPO/pulls/$PR_NUMBER/reviews")
COMMENTS=$(gh_api "/repos/$REPO/pulls/$PR_NUMBER/comments")

# Get the latest Codex review
LATEST_CODEX=$(echo "$REVIEWS" | jq -r '
    [.[] | select(.user.login | test("codex-connector|chatgpt-codex"; "i"))] |
    sort_by(.submitted_at) |
    .[-1] // empty
')

# Check if latest Codex review is a "pass"
if [[ -n "$LATEST_CODEX" ]]; then
    CODEX_BODY=$(echo "$LATEST_CODEX" | jq -r '.body // ""')
    CODEX_STATE=$(echo "$LATEST_CODEX" | jq -r '.state // ""')

    PASS_BY_STATE=false
    PASS_BY_BODY=false

    if [[ "$CODEX_STATE" == "APPROVED" ]]; then
        PASS_BY_STATE=true
    fi

    # Conservative pass detection
    POSITIVE_PATTERN="(didn.t find.*(issue|problem)|no.*(major|significant).*(issue|problem)|lgtm|looks good to me|looks good!)"
    NEGATIVE_PATTERN="(but[^a-z]|however|though|please|needs? |should |would |can you|could you|(one|an) (issue|problem)|(^|[.!] *)(update|fix|change|add|remove|modify|check|review))"

    if [[ "$CODEX_STATE" == "COMMENTED" || "$CODEX_STATE" == "APPROVED" ]] && \
       echo "$CODEX_BODY" | grep -qiE "$POSITIVE_PATTERN" && \
       ! echo "$CODEX_BODY" | grep -qiE "$NEGATIVE_PATTERN"; then
        PASS_BY_BODY=true
    fi

    if [[ "$PASS_BY_STATE" == "true" || "$PASS_BY_BODY" == "true" ]]; then
        CODEX_REVIEW_ID=$(echo "$LATEST_CODEX" | jq -r '.id')

        LATEST_COMMENTS=$(echo "$COMMENTS" | jq --arg rid "$CODEX_REVIEW_ID" '
            [.[] | select(.pull_request_review_id == ($rid | tonumber))] | length
        ')

        OTHER_COMMENTS=$(echo "$COMMENTS" | jq '
            [.[] | select(.user.login | test("codex-connector|chatgpt-codex"; "i") | not)] | length
        ')

        PENDING_REVIEWS=$(echo "$REVIEWS" | jq '
            sort_by(.user.login) | group_by(.user.login) | map(sort_by(.submitted_at) | .[-1]) |
            [.[] | select(.user.login | test("codex-connector|chatgpt-codex"; "i") | not) |
             select(.state != "DISMISSED") |
             select(.state == "CHANGES_REQUESTED" or (.state != "APPROVED" and .body != "" and .body != null))] | length
        ')

        if [[ "$LATEST_COMMENTS" -eq 0 ]] && [[ "$PENDING_REVIEWS" -eq 0 ]] && [[ "$OTHER_COMMENTS" -eq 0 ]]; then
            echo "==========================================="
            echo "CODEX PASSED THE PR!"
            echo "==========================================="
            echo ""
            echo "Latest review: $CODEX_BODY"
            echo ""
            echo "The PR is ready to merge!"
            echo "https://github.com/$REPO/pull/$PR_NUMBER"
            exit 0
        fi
    fi
fi

# Count actionable issues
REVIEW_ISSUES=$(echo "$REVIEWS" | jq '[.[] | select(.body != "" and .body != null and .state != "APPROVED")] | length')
INLINE_ISSUES=$(echo "$COMMENTS" | jq 'length')
TOTAL=$((REVIEW_ISSUES + INLINE_ISSUES))

if [[ "$TOTAL" -eq 0 ]]; then
    echo "No review issues found on PR #$PR_NUMBER"
    echo ""
    echo "The PR may be:"
    echo "  - Already approved"
    echo "  - Awaiting initial review"
    echo "  - Having all issues resolved"
    exit 0
fi

# Format output for Claude Code
cat <<EOF
## Code Review Issues for PR #$PR_NUMBER

**Branch:** \`$BRANCH\`
**Title:** $TITLE

Please fix the following $TOTAL issue(s):

EOF

echo "$REVIEWS" | jq -r '
    .[] | select(.body != "" and .body != null and .state != "APPROVED") |
    "### Review from \(.user.login)\n**Status:** \(.state)\n**Feedback:**\n> \(.body | split("\n") | join("\n> "))\n"
'

echo "$COMMENTS" | jq -r '
    .[] |
    "### Issue in `\(.path)`" +
    (if .line then " (line \(.line))" else "" end) +
    "\n**From:** \(.user.login)\n**Feedback:**\n> \(.body | split("\n") | join("\n> "))\n"
'

cat <<EOF
---

After fixing all issues:
1. Commit your changes
2. Push to origin
3. Run: ./scripts/trigger-rereview.sh $PR_NUMBER
EOF
