#!/usr/bin/env bash
#
# Fetch Review Issues
# Fetches Codex review feedback and formats it for Claude Code
#
# Usage:
#   ./scripts/fetch-review-issues.sh <PR_NUMBER>
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
    echo "Error: REPO environment variable required"
    echo ""
    echo "Set it with: export REPO=owner/repo-name"
    exit 1
fi
if [[ "$REPO_DETECTED" == true ]]; then
    echo "Detected repo: $REPO"
fi

# Unified API caller — works with either GITHUB_TOKEN or gh CLI
# Fails fast on gh errors; curl -s always exits 0 on HTTP errors so the
# downstream jq parsing handles error JSON (e.g. STATE becomes "null").
gh_api() {
    if [[ "$AUTH_METHOD" == "gh" ]]; then
        local output
        if ! output=$(gh api -H "Accept: application/vnd.github.v3+json" "$1" 2>&1); then
            echo "Error: GitHub API request failed for $1" >&2
            echo "$output" >&2
            exit 1
        fi
        echo "$output"
    else
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github.v3+json" \
             "https://api.github.com$1"
    fi
}

# Paginated variant for list endpoints (reviews, comments).
# gh --paginate may emit one JSON array per page; jq -s 'add' merges them.
# curl path uses per_page=100 (single request, covers most PRs).
gh_api_list() {
    if [[ "$AUTH_METHOD" == "gh" ]]; then
        local output
        if ! output=$(gh api --paginate -H "Accept: application/vnd.github.v3+json" "$1" 2>&1); then
            echo "Error: GitHub API request failed for $1" >&2
            echo "$output" >&2
            exit 1
        fi
        echo "$output" | jq -s 'add // []'
    else
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github.v3+json" \
             "https://api.github.com${1}?per_page=100"
    fi
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

# Get reviews and comments (paginated to capture full history)
REVIEWS=$(gh_api_list "/repos/$REPO/pulls/$PR_NUMBER/reviews")
COMMENTS=$(gh_api_list "/repos/$REPO/pulls/$PR_NUMBER/comments")

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
    CODEX_REVIEW_ID=$(echo "$LATEST_CODEX" | jq -r '.id')

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

# Count actionable issues from the latest Codex review only.
# Previous review rounds and other reviewers are handled by the pass check above;
# the output below should only surface what the current Codex iteration flagged.
REVIEW_ISSUES=0
INLINE_ISSUES=0

if [[ -n "${CODEX_REVIEW_ID:-}" ]]; then
    REVIEW_ISSUES=$(echo "$LATEST_CODEX" | jq '
        if (.body // "") != "" and .state != "APPROVED" then 1 else 0 end
    ')
    INLINE_ISSUES=$(echo "$COMMENTS" | jq --arg rid "$CODEX_REVIEW_ID" '
        [.[] | select(.pull_request_review_id == ($rid | tonumber))] | length
    ')
fi

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

# Format output for Claude Code — scoped to the latest Codex review
cat <<EOF
## Code Review Issues for PR #$PR_NUMBER

**Branch:** \`$BRANCH\`
**Title:** $TITLE

Please fix the following $TOTAL issue(s):

EOF

if [[ "$REVIEW_ISSUES" -gt 0 ]]; then
    echo "$LATEST_CODEX" | jq -r '
        "### Review from \(.user.login)\n**Status:** \(.state)\n**Feedback:**\n> \(.body | split("\n") | join("\n> "))\n"
    '
fi

echo "$COMMENTS" | jq -r --arg rid "${CODEX_REVIEW_ID:-}" '
    .[] | select(.pull_request_review_id == ($rid | tonumber)) |
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
