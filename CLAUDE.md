# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **distributable tooling**, not an application. The artifacts here (`scripts/`, `.claude/skills/codex-review-loop/`, `.github/workflows/review-notifier.yml`, `gitattributes.template`) are meant to be copied into *other* repos, where they wire Claude Code ↔ Codex into an automated review loop.

Implication: when making changes, think about how the change behaves in a consumer repo, not just this one. Paths are relative (`./scripts/...`), auth is pluggable (`gh` CLI or `GITHUB_TOKEN`), and the repo is auto-detected from `git remote`.

## The loop, end to end

1. User invokes the skill: `/codex-review-loop <PR#>` (skill at `.claude/skills/codex-review-loop/SKILL.md`).
2. `scripts/fetch-review-issues.sh <PR#>` pulls reviews + review comments via GitHub API, filters to the *latest* Codex review, and either:
   - Prints `CODEX PASSED THE PR!` and exits 0, or
   - Prints `CODEX HAS NO ISSUES` (Codex is happy but other reviewers have pending feedback), or
   - Prints a markdown issue list for Claude to fix, including a `Codex review ID:` line.
3. Claude fixes, commits (discrete commands — not chained with `&&`), pushes.
4. `scripts/trigger-rereview.sh <PR#>` posts `@codex review` *and* neutralizes the old sticky (see lifecycle below).
5. `scripts/wait-for-review.sh <PR#> <LAST_REVIEW_ID>` blocks until a review with a different ID arrives, then exits 0.
6. Repeat from step 2, capped at 10 iterations by the skill.

The workflow `review-notifier.yml` is an *optional* parallel path: it posts/updates a sticky PR comment with the formatted issue list when Codex submits a review, so users outside an active Claude session can still pick up the work.

## Non-obvious details that matter

- **Codex identity detection** — Codex reviews are matched by login regex `codex-connector|chatgpt-codex` (case-insensitive). If GitHub renames the bot, `fetch-review-issues.sh`, `wait-for-review.sh`, and `review-notifier.yml` all need updating.
- **Pass detection is two-signal**: either `state == APPROVED` *or* the body matches a `POSITIVE_PATTERN` and *doesn't* match `NEGATIVE_PATTERN` (which catches hedges like "but", "however", "please", "should", imperative verbs at sentence start). Be very conservative when editing these regexes — a false pass silently ships un-reviewed code.
- **Pass also requires cleanliness elsewhere**: no inline comments on the latest Codex review, no pending non-Codex reviews with `CHANGES_REQUESTED` or non-empty body, no non-Codex issue comments. When Codex says OK but others haven't, the script prints `CODEX HAS NO ISSUES` and points the user at the PR rather than claiming pass.
- **Issue counting rule (critical, don't regress)**: only inline comments count as issues. The Codex review *body* is a summary, rendered as a context header above the issue list — not +1. Exception: if state is `CHANGES_REQUESTED` *and* there are zero inline comments, the body is the feedback and counts as 1. Both `fetch-review-issues.sh` and `review-notifier.yml` implement this; keep them in sync. The pre-fix "off-by-one" bug came from counting body + inline comments.
- **Issue counts are scoped to the latest Codex review only** (`pull_request_review_id == CODEX_REVIEW_ID`). Don't accidentally broaden this — prior-round comments must not re-surface.
- **Sticky lifecycle** — the `<!-- claude-review-notification -->` PR comment has a companion anchor `<!-- codex-review-id: <id> -->` identifying which Codex review it describes. When `trigger-rereview.sh` runs, it rewrites the sticky to a "fixes pushed, awaiting re-review" state with anchor `codex-review-id: pending`. The workflow rewrites it again when the next review arrives, with the new anchor. Any stale issue list visible in the PR between those events is, by design, self-labeling as stale.
- **Source of truth contract**: the skill forbids reading review state via `gh pr view` / `gh api` / `curl` and mandates `fetch-review-issues.sh`. This exists because the PR timeline contains inline comments from ALL past Codex reviews; only the script scopes to the latest review ID. Breaking this contract brings back the "sees 3 issues when there's 1" bug.
- **`gh_api` vs `gh_api_list`**: single-resource vs paginated. The paginated variant uses `gh --paginate | jq -s 'add // []'` to merge page arrays, and `per_page=100` on the curl path. Both fail fast on `gh` errors; the curl path intentionally doesn't (downstream `jq` handles error JSON).
- **Auth precedence**: `GITHUB_TOKEN` beats `gh` CLI if both are set (see `AUTH_METHOD` selection in all three scripts).
- **Discrete commands, not chained**: `.claude/settings.json` scopes permissions to individual commands (`./scripts/fetch-review-issues.sh:*`, `git commit:*`, etc.). Chained shell commands (`sleep 120 && ./scripts/…`) defeat the pattern match and trigger approval prompts. `wait-for-review.sh` exists so the loop's "wait" step is a single allowed command, not a combinator.
- **`gitattributes.template` is deliberately NOT named `.gitattributes`** in this repo. Consumers rename/append it so their PR diffs hide the tool files as `linguist-generated`. Keeping it as a template here means *this* repo's PRs still show tool-file diffs — critical for dogfooding. Don't "fix" this by renaming.

## Commands

No build/lint/test harness exists. Smoke-test changes by running the scripts against a live PR:

```bash
# From a consumer repo (or this one, against its own PRs)
./scripts/fetch-review-issues.sh <PR_NUMBER>
./scripts/trigger-rereview.sh <PR_NUMBER>
./scripts/wait-for-review.sh <PR_NUMBER> [LAST_REVIEW_ID] [MAX_WAIT_SECONDS]
```

All three scripts use `set -euo pipefail`. Dependencies: `bash`, `jq` (required for both auth paths), `curl` (only for token auth), and `gh` (only for CLI auth). When editing shell, consider running `shellcheck scripts/*.sh` locally — it's not wired into CI.

## Dogfooding

This repo uses its own loop on its own PRs. That means:
- Changes to `fetch-review-issues.sh` / `trigger-rereview.sh` / `SKILL.md` affect the next review cycle *on this repo* — test carefully.
- The `.gitattributes` trick is intentionally *not* applied here (see above), so reviewers see full diffs of tool changes.
