# Codex Review Loop

Automate AI code reviews: Codex reviews your PR, Claude Code fixes issues, repeat until pass.

## Setup

### 1. Copy files to your repo

```bash
# Copy scripts
cp -r codex-review-loop/scripts your-project/

# Copy GitHub Action (optional - posts notifications on PRs)
cp codex-review-loop/.github/workflows/review-notifier.yml your-project/.github/workflows/
```

### 2. Add to your CLAUDE.md

Add this skill to your project's `CLAUDE.md` so Claude Code knows how to run the review loop:

```markdown
## Code Review Loop

When asked to "run review loop" or "check code review", use this workflow:

1. Run `./scripts/fetch-review-issues.sh <PR_NUMBER>` to check review status
2. If issues are found, fix them and commit
3. Push changes and run `./scripts/trigger-rereview.sh <PR_NUMBER>`
4. Wait ~2 minutes for Codex to review, then repeat from step 1
5. Stop when you see "CODEX PASSED THE PR!"

Requirements:
- GITHUB_TOKEN environment variable must be set
- Codex must be enabled on the repository
```

### 3. Set your GitHub token

```bash
export GITHUB_TOKEN=ghp_xxxxx
```

The repo is auto-detected from your git remote. No other config needed.

## Usage

In Claude Code, just say:

> "Run the review loop for PR #42"

Or manually:

```bash
./scripts/fetch-review-issues.sh 42   # Check status
./scripts/trigger-rereview.sh 42      # Trigger re-review after pushing fixes
```

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

## Requirements

- `bash`, `curl`, `jq`
- GitHub token with `repo` scope
- [Codex](https://chatgpt.com/codex) enabled on your repository

## License

MIT
