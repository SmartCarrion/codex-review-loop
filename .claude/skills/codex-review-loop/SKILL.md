---
name: codex-review-loop
description: Run the automated Codex code review loop — fetch issues, fix them, push, trigger re-review, wait, repeat until Codex passes. Use whenever the user asks to run the review loop, address Codex feedback on a PR, or wants automated PR review cycles.
disable-model-invocation: true
argument-hint: "[pr-number]"
allowed-tools: Read, Bash, Edit, Write
---

# Codex Review Loop

Run the code review loop for PR $ARGUMENTS.

## The one rule that matters

**`./scripts/fetch-review-issues.sh <PR>` is the only source of truth for review state.** Do not run `gh pr view`, `gh api`, or `curl` against the PR to inspect reviews or comments. Those return stale or unscoped data — they include inline comments from previous Codex review rounds that the script correctly filters out. Relying on them produces double-counts (e.g. "3 issues" when there's really 1 new + 2 already-fixed). The script scopes issues to the latest Codex review by ID; trust it.

If the script reports zero issues, there are zero issues — even if an old sticky comment on the PR still shows issues from a previous round.

## Loop

Max 10 iterations. Stop and ask the user if you hit the cap.

1. **Fetch current state**
   ```
   ./scripts/fetch-review-issues.sh $ARGUMENTS
   ```
   The output includes a `Codex review ID:` line — remember it. You'll pass it to the wait step so you know when a *new* review has arrived.

2. **If "CODEX PASSED THE PR!"** — done. The PR is ready to merge. Stop.

3. **If "CODEX HAS NO ISSUES"** — Codex is happy, but other reviewers have pending feedback. Stop and tell the user; don't try to address non-Codex feedback in this loop.

4. **If issues are listed** — fix each one. Then:
   ```
   git add <specific files>
   git commit -m "<concise message>"
   git push
   ./scripts/trigger-rereview.sh $ARGUMENTS
   ./scripts/wait-for-review.sh $ARGUMENTS <CODEX_REVIEW_ID>
   ```
   Each command on its own line — not chained with `&&`. Chained commands defeat the scoped permission rules and cause unnecessary approval prompts. Pass the review ID from step 1 so `wait-for-review.sh` blocks until a *different* review arrives.

5. **Loop back to step 1.**

## Oscillation guard

If the same issue reappears in two consecutive rounds after you pushed a fix for it, stop. Don't just try again — Codex and you are disagreeing about what "fixed" means, and the user needs to arbitrate. Summarize: what Codex is asking, what you changed, why you think it's resolved.

## Context vs. issues

The script output may include a "Codex summary (context, not an issue to fix directly)" block above the issue list. That's framing from Codex — don't treat each bullet in the summary as a separate task. The numbered `### Issue N` entries below it are the actionable items. Count only those.

## Requirements

- GitHub auth: `gh auth login` OR `GITHUB_TOKEN` env var
- Codex enabled on the repository at [chatgpt.com/codex](https://chatgpt.com/codex)
- `bash`, `jq`, and (for token auth) `curl`
