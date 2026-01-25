---
name: codex-review-loop
description: Run automated Codex code review loop - fetch issues, fix them, re-review until pass
disable-model-invocation: true
argument-hint: "[pr-number]"
allowed-tools: Read, Bash, Edit, Write
---

# Codex Review Loop

Run the code review loop for PR $ARGUMENTS.

**Important:** Stop after 10 iterations and ask the user for input to avoid infinite loops or burning through Codex quota.

## Loop (max 10 iterations)

1. **Check review status**: Run `./scripts/fetch-review-issues.sh $ARGUMENTS`

2. **If "CODEX PASSED THE PR!"**: Stop - the PR is ready to merge

3. **If issues found**:
   - Fix each issue
   - Commit changes
   - Push to origin
   - Run `./scripts/trigger-rereview.sh $ARGUMENTS`
   - Wait ~2 minutes for Codex to review
   - Go back to step 1

4. **If 10 iterations reached**: Stop and ask user whether to continue, merge anyway, or abandon

## Requirements

- `GITHUB_TOKEN` environment variable must be set
- Codex must be enabled on the repository
