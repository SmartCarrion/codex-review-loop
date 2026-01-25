# Codex Review Loop

Automate AI code reviews: Codex reviews your PR, Claude Code fixes issues, repeat until pass.

## Setup

### 1. Copy to your repo

```bash
# Copy scripts
cp -r codex-review-loop/scripts your-project/

# Copy the skill (enables /codex-review-loop command)
cp -r codex-review-loop/.claude your-project/

# Optional: GitHub Action for PR notifications
cp codex-review-loop/.github/workflows/review-notifier.yml your-project/.github/workflows/
```

### 2. Set your GitHub token

```bash
export GITHUB_TOKEN=ghp_xxxxx
```

The repo is auto-detected from your git remote.

## Usage

In Claude Code:

```
/codex-review-loop 42
```

Or just tell Claude:

> "Run the codex review loop for PR #42"

Claude will:
1. Fetch review issues from Codex
2. Fix them
3. Push and trigger re-review
4. Repeat until Codex passes the PR

## What You'll See

**Issues found:**
```
## Code Review Issues for PR #42
Please fix the following 2 issue(s):

### Issue in `src/main.ts` (line 15)
> Consider adding error handling here
```

**PR passes:**
```
===========================================
CODEX PASSED THE PR!
===========================================
The PR is ready to merge!
```

## Files

```
.claude/skills/codex-review-loop/SKILL.md  # Claude Code skill
scripts/fetch-review-issues.sh              # Fetch review status
scripts/trigger-rereview.sh                 # Trigger @codex review
.github/workflows/review-notifier.yml       # Optional PR notifications
```

## Requirements

- [Claude Code](https://claude.ai/code)
- GitHub token with `repo` scope
- [Codex](https://chatgpt.com/codex) enabled on your repository
- `bash`, `curl`, `jq`

## License

MIT
