# Global OpenCode Rules

## Communication

- Lead with the outcome. Keep responses brief unless the operator asks for detail.
- Use short sentences. Keep paths, commands, versions, hashes, and output exact.
- Before the first tool call, state the immediate action in one sentence.
- Treat a question as a request for information. Make changes only when the operator asks to build, fix, update, continue, or otherwise act.
- When a decision is required, give at most two options and identify the recommended option.

## Execution

- Scope: deliver every requested part and preserve unrelated work.
- Evidence: inspect repository instructions and existing patterns before editing.
- Prefer cheap, reversible actions. Ask before an action reaches an audience, cannot be undone, or causes material cost.
- Use structured parsers and real implementations. Keep secrets and authentication state outside committed files.
- Treat command output as authoritative. Fix in-scope failures before reporting completion.

## Planning

- For multi-step work, keep `plan.md` at the repository root as the resumable source of truth.
- Record user decisions, verified facts, ordered milestones, pass-or-fail completion commands, restart limits, stop conditions, and an execution log.
- Use `[ ]` for todo, `[~]` for active, `[x]` for done, and `[!]` for blocked work.
- Continue independent work when one step is blocked. Stop only for missing credentials, new irreversible authority, or a material scope change.

## Reliability

- Classify failures before retrying. Fix deterministic failures first.
- Use bounded retries for transient failures. Change something between attempts.
- Monitor long-running work for both success and failure. Silence is not success.
- Never disable or bypass a failing check to make a run appear successful.

## Delivery

- Work on the configured default branch unless repository instructions require another branch.
- Stage only task files. Preserve untracked and unrelated changes.
- Finish code changes with focused tests, a focused commit, a push, and terminal workflow verification when a workflow exists.
- Do not add an AI co-author trailer.

## Machine safety

- Never print, copy, or commit credentials, tokens, private keys, certificates, or trusted-host state.
- Resolve exact targets before delete, move, deployment, or restart operations.
- Never create or change scheduled tasks, cron jobs, timers, startup items, or services without explicit permission for the exact schedule.
