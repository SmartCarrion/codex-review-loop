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

# Unified API caller — works with either GITHUB_TOKEN or gh CLI.
# Fails fast on gh errors; curl -s always exits 0 on HTTP errors so the
# downstream jq parsing handles error JSON (e.g. STATE becomes "null").
#
# The leading "/" is stripped before passing to `gh api` because MSYS/
# Git Bash on Windows rewrites paths starting with "/" into Windows
# filesystem paths (e.g. "/repos/..." → "C:/Program Files/Git/repos/...")
# before `gh` sees them. `gh api` accepts the endpoint with or without
# the leading slash, so normalizing here makes the scripts portable.
gh_api() {
    local endpoint="${1#/}"
    if [[ "$AUTH_METHOD" == "gh" ]]; then
        local output
        if ! output=$(gh api -H "Accept: application/vnd.github.v3+json" "$endpoint" 2>&1); then
            echo "Error: GitHub API request failed for /$endpoint" >&2
            echo "$output" >&2
            exit 1
        fi
        echo "$output"
    else
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github.v3+json" \
             "https://api.github.com/$endpoint"
    fi
}

# Follow GitHub's Link: rel="next" header to page through results when
# using token auth. gh handles this natively via --paginate, but curl
# needs it done manually — otherwise busy PRs (100+ reviews/comments)
# can have the latest data beyond page 1 and we'd miss it.
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

        # Parse `Link: <...>; rel="next", <...>; rel="last"` and extract
        # the URL whose rel is "next". Empty when there is no next page.
        url=$(grep -i '^link:' "$headers_file" 2>/dev/null \
              | tr ',' '\n' \
              | grep 'rel="next"' \
              | sed -E 's/.*<([^>]+)>.*/\1/' \
              | head -1 || true)
    done

    rm -f "$headers_file"
    echo "$all"
}

# Paginated variant for list endpoints (reviews, comments).
gh_api_list() {
    local endpoint="${1#/}"
    if [[ "$AUTH_METHOD" == "gh" ]]; then
        local output
        if ! output=$(gh api --paginate -H "Accept: application/vnd.github.v3+json" "$endpoint" 2>&1); then
            echo "Error: GitHub API request failed for /$endpoint" >&2
            echo "$output" >&2
            exit 1
        fi
        echo "$output" | jq -s 'add // []'
    else
        curl_paginate "https://api.github.com/${endpoint}"
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
#
# Counting rule (do not change without understanding why):
#   - Inline review comments are always counted: each one is a concrete,
#     file-scoped piece of feedback.
#   - The review *body* is normally a summary of what's in the inline
#     comments ("Reviewed X files, found N issues…"). Counting it as +1
#     double-counts and produces the off-by-one users have seen.
#   - The one case where the body IS the feedback: state=CHANGES_REQUESTED
#     with zero inline comments. Then the body is the only signal, so it
#     counts as exactly 1 issue.
INLINE_ISSUES=0
BODY_IS_ISSUE=0

if [[ -n "${CODEX_REVIEW_ID:-}" ]]; then
    INLINE_ISSUES=$(echo "$COMMENTS" | jq --arg rid "$CODEX_REVIEW_ID" '
        [.[] | select(.pull_request_review_id == ($rid | tonumber))] | length
    ')
    if [[ "$INLINE_ISSUES" -eq 0 ]] && [[ "$CODEX_STATE" == "CHANGES_REQUESTED" ]] \
       && [[ -n "$CODEX_BODY" ]]; then
        BODY_IS_ISSUE=1
    fi
fi

TOTAL=$((INLINE_ISSUES + BODY_IS_ISSUE))

if [[ "$TOTAL" -eq 0 ]]; then
    if [[ "${PASS_BY_STATE:-false}" == "true" || "${PASS_BY_BODY:-false}" == "true" ]]; then
        echo "==========================================="
        echo "CODEX HAS NO ISSUES"
        echo "==========================================="
        echo ""
        echo "Codex approved or found no problems, but other reviewers"
        echo "have pending feedback on this PR."
        echo ""
        echo "Check the PR for non-Codex review comments:"
        echo "https://github.com/$REPO/pull/$PR_NUMBER"
    else
        echo "No review issues found on PR #$PR_NUMBER"
        echo ""
        echo "The PR may be:"
        echo "  - Already approved"
        echo "  - Awaiting initial review"
        echo "  - Having all issues resolved"
    fi
    exit 0
fi

# Format output for Claude Code — scoped to the latest Codex review.
# The review body renders as a summary header (context only, not counted
# as an issue) unless it's the only signal (CHANGES_REQUESTED + no inline
# comments), in which case it's rendered as Issue 1 below.
cat <<EOF
## Code Review Issues for PR #$PR_NUMBER

**Branch:** \`$BRANCH\`
**Title:** $TITLE
**Codex review ID:** $CODEX_REVIEW_ID

EOF

if [[ -n "$CODEX_BODY" ]] && [[ "$BODY_IS_ISSUE" -eq 0 ]]; then
    # Summary header — context for the inline issues, not an issue itself.
    echo "**Codex summary (context, not an issue to fix directly):**"
    echo ""
    echo "$CODEX_BODY" | sed 's/^/> /'
    echo ""
fi

echo "Please fix the following $TOTAL issue(s):"
echo ""

if [[ "$BODY_IS_ISSUE" -eq 1 ]]; then
    echo "$LATEST_CODEX" | jq -r '
        "### Issue 1 — Review from \(.user.login)\n**Status:** \(.state)\n**Feedback:**\n> \(.body | split("\n") | join("\n> "))\n"
    '
fi

echo "$COMMENTS" | jq -r --arg rid "${CODEX_REVIEW_ID:-}" --argjson offset "$BODY_IS_ISSUE" '
    [.[] | select(.pull_request_review_id == ($rid | tonumber))] |
    to_entries[] |
    "### Issue \(.key + 1 + $offset) in `\(.value.path)`" +
    (if .value.line then " (line \(.value.line))" else "" end) +
    "\n**From:** \(.value.user.login)\n**Feedback:**\n> \(.value.body | split("\n") | join("\n> "))\n"
'

cat <<EOF
---

After fixing all issues:
1. Commit your changes
2. Push to origin
3. Run: ./scripts/trigger-rereview.sh $PR_NUMBER
4. Run: ./scripts/wait-for-review.sh $PR_NUMBER $CODEX_REVIEW_ID
   (blocks until a new Codex review arrives, then re-run this script)
EOF
