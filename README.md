# Codex Review Loop

Automate your AI code review workflow with OpenAI Codex and Claude Code.

```
Push code → Codex reviews → Fix issues → Repeat until pass → Merge
```

## What It Does

- **Fetches review issues** from Codex in a Claude Code-friendly format
- **Detects pass/fail** so you know when your PR is ready to merge
- **Triggers re-review** after you push fixes
- **GitHub Action** notifies you when reviews are ready

## Quick Start

### 1. Copy to Your Repo

```bash
# Clone this repo
git clone https://github.com/YOUR_USERNAME/codex-review-tool.git

# Copy to your project
cp -r codex-review-tool/scripts your-project/
cp codex-review-tool/.github/workflows/review-notifier.yml your-project/.github/workflows/
```

### 2. Set Up GitHub Token

Create a [Personal Access Token](https://github.com/settings/tokens) with `repo` scope:

```bash
export GITHUB_TOKEN=ghp_xxxxx
export REPO="owner/repo-name"
```

### 3. Use It

```bash
# Check review status
./scripts/fetch-review-issues.sh <PR_NUMBER>

# After fixing issues, trigger re-review
./scripts/trigger-rereview.sh <PR_NUMBER>
```

## The Review Loop

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  1. Create PR        →  Codex auto-reviews              │
│                                                         │
│  2. Check status     →  ./scripts/fetch-review-issues.sh│
│                                                         │
│  3. Fix issues       →  Claude Code fixes them          │
│                                                         │
│  4. Push & re-review →  ./scripts/trigger-rereview.sh   │
│                                                         │
│  5. Repeat until     →  "CODEX PASSED THE PR!"          │
│                                                         │
│  6. Merge                                               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## Output Examples

### When Issues Are Found

```
## Code Review Issues for PR #42

**Branch:** `feature/new-thing`
**Title:** Add new feature

Please fix the following 2 issue(s):

### Issue in `src/main.ts` (line 15)
**From:** chatgpt-codex-connector[bot]
**Feedback:**
> Consider adding error handling here
```

### When PR Passes

```
===========================================
CODEX PASSED THE PR!
===========================================

Latest review: Didn't find any major issues. Looks good!

The PR is ready to merge!
https://github.com/owner/repo/pull/42
```

## Files

| File | Purpose |
|------|---------|
| `scripts/fetch-review-issues.sh` | Fetch and format review issues |
| `scripts/trigger-rereview.sh` | Trigger Codex to re-review |
| `.github/workflows/review-notifier.yml` | GitHub Action for notifications |

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GITHUB_TOKEN` | Yes | - | GitHub PAT with `repo` scope |
| `REPO` | No | - | Repository in `owner/repo` format |

### GitHub Action (Optional)

The included workflow posts a comment on your PR when Codex finds issues, making it easy to see what needs fixing.

To use webhooks for external notifications, set `REVIEW_WEBHOOK_URL` in your repository variables.

## How Pass Detection Works

The script uses conservative heuristics:

**Pass indicators:**
- "didn't find any issues"
- "no major issues"
- "looks good to me" / "lgtm"
- APPROVED review state

**Fail indicators:**
- "please update/fix/change..."
- "needs to be..."
- "should be..."
- Contrast words: "but", "however"

**When uncertain:** Shows issues for manual review rather than false-passing.

## Requirements

- `bash`, `curl`, `jq`
- GitHub Personal Access Token
- [Codex](https://chatgpt.com/codex) set up on your repository

## License

MIT
