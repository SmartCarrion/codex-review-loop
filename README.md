# Codex Review Loop

A low-effort AI code review loop: Claude Code writes and fixes code, Codex reviews it, repeat until pass.

## What Is This?

This tool connects two AI systems in a review loop:
- **Claude Code** writes code and fixes issues
- **Codex** reviews PRs and provides feedback

You kick it off, grab a coffee, and come back to a reviewed PR. It's the Ralph Wiggum of CI/CD—simple, automated, gets the job done.

## Setup

### 1. Enable Codex on your repo

Go to [chatgpt.com/codex](https://chatgpt.com/codex) and connect your GitHub repository. Codex will automatically review PRs when they're opened or when you comment `@codex review`.

### 2. Copy to your repo

```bash
# Copy scripts
cp -r codex-review-loop/scripts your-project/

# Copy the skill (enables /codex-review-loop command)
cp -r codex-review-loop/.claude your-project/

# Optional: GitHub Action for PR notifications
cp codex-review-loop/.github/workflows/review-notifier.yml your-project/.github/workflows/
```

### 3. Set your GitHub token

```bash
export GITHUB_TOKEN=ghp_xxxxx
```

The repo is auto-detected from your git remote.

## Usage

In Claude Code:

```
/codex-review-loop 42
```

Or just say:

> "Run the codex review loop for PR #42"

Claude will:
1. Fetch review issues from Codex
2. Fix them
3. Push and trigger re-review
4. Repeat until Codex passes the PR

## Warnings

**Loop limit:** The skill stops after 10 iterations and asks for input to avoid infinite loops. Some PRs may need human judgment to break out of fix-review cycles.

**Codex quota:** Each review cycle uses your Codex review allowance. A PR that takes 5 iterations = 5 reviews. Monitor your usage at [chatgpt.com/codex](https://chatgpt.com/codex).

**Not magic:** This catches straightforward issues. Complex architectural feedback may need human review. Use it to handle the routine stuff so you can focus on the interesting problems.

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
- [Codex](https://chatgpt.com/codex) enabled on your repository
- GitHub token with `repo` scope
- `bash`, `curl`, `jq`

## License

MIT
