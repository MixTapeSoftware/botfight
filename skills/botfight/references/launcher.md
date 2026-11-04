# Launch-all mode

`/botfight` with no arguments, or `/botfight all [<interval> <duration>] [--model <role>=<model>[@<effort>], ...]`, runs the whole botfight crew on the current branch's PR:

| Role                | Mode run by the agent                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------- |
| `fixer`             | Fixer, as in `SKILL.md`.                                                                    |
| `reviewer`          | Reviewer with no instructions: the general review in [reviewer.md](reviewer.md).            |
| `security`          | Reviewer with the security brief below.                                                     |
| `formatter`         | Formatter, as in [formatter.md](formatter.md).                                              |

The session that receives the command is the **launcher**. It never fixes, reviews, or formats inline. It runs the crew in one of two ways:

- **Parallel** (Claude Code): four long-lived background agents, each running its mode's own loop. See [Parallel launch](#parallel-launch).
- **Rotation** (Codex, Grok Build, and any other harness that can start sub-agents): the launcher itself loops, and each round starts short-lived, single-pass agents one after another. No agent starts another agent, and at most two are open at once. See [Rotation](#rotation).

If the harness cannot start sub-agents at all, do not run the roles inline. Report that as a blocker and give the user the four commands under [Parallel launch](#parallel-launch) to start in separate sessions.

The security reviewer's brief is this exact text, so its `scope_id` stays stable across runs:

```
Only review security: authentication, authorization, injection, secrets handling, data isolation, and unsafe input handling.
```

## Models

Each role runs on its own model. Defaults:

| Role        | Claude Code | Codex                 |
| ----------- | ----------- | --------------------- |
| `fixer`     | `opus`      | `gpt-6.1-sol` @ high  |
| `reviewer`  | `opus`      | `gpt-6.1-sol` @ high  |
| `security`  | `opus`      | `gpt-6.1-sol` @ high  |
| `formatter` | `sonnet`    | `gpt-6.1-terra`       |

Where the table gives no effort (every Claude Code role, and the Codex formatter), leave reasoning effort unset unless an override supplies one; the agent then uses the model's default effort.

`--model` takes the rest of the arguments as a comma-separated list of `<role>=<model>` entries, each with an optional `@<effort>` suffix, for example `--model fixer=sonnet, security=opus@max` or `--model reviewer=gpt-6-luna@medium`. `reviewer` sets both reviewers; a `security` entry then overrides the security reviewer alone. Pass model names and efforts through verbatim; the harness decides what is valid. Put timing before `--model`.

Each agent in either strategy starts on its role's model. If the harness rejects a model or effort, start that agent with the harness's default (the inherited model) and say so in the launch report. If the harness cannot set a model per agent at all, start the agents anyway and report that every role runs on the inherited model.

## Shared setup

1. **Parse arguments.** Use the shared timing defaults from `SKILL.md`. Get the current UTC time (`date -u +%Y-%m-%dT%H:%M:%SZ`) and compute one `deadline = now + duration`. Never recompute it.
2. **Resolve the PR.** Use `gh pr view` for the current branch. If none exists, push the branch and create one with `gh pr create` against the default branch, the same way fixer step 1 does. Pin the canonical PR URL; reviewers and formatter never create a PR.
3. **Resolve each role's model** for this harness from the defaults and overrides.
4. **Check permissions.** The crew runs `git`, `gh api`, `gh pr`, and the repository's verification checks, and the fixer pushes. Tell the user before starting if the session's permissions would stop any of these, because an unattended agent waiting on a prompt stalls the crew.

## Parallel launch

Start all four agents in one turn, so they run concurrently. Each agent's prompt names the botfight skill, the exact continuation arguments below, and says it was started by the launcher and must end with its mode's exit report as its final message:

- fixer: `fixer until <deadline> every <interval>`
- reviewer: `reviewer <PR-URL> until <deadline> every <interval>`
- security: `reviewer <PR-URL> until <deadline> every <interval> -- <security brief>`
- formatter: `formatter <PR-URL> until <deadline> every <interval>`

Each agent follows its mode's loop, including the fallback to bounded foreground waits when it cannot schedule recurring wakeups. The fixer agent owns the PR title.

Report the launch: the PR URL, the deadline and interval, and each role with its agent ID and the model and effort it actually got. Do not poll the agents. As each one finishes, relay its exit report to the user, putting human items and blockers first.

**Claude Code specifics.** Start each agent with the Agent tool: `subagent_type: "general-purpose"`, `model` set to the role's model, and `effort` only when an override supplies one. Agents run in the background. Background agents have no recurring-wakeup tool, so each mode's loop waits in the foreground with bounded `sleep` calls between checks; that is the expected path, not a failure. They can start their own sub-agents up to three levels below the main session, so the formatter's per-pass sub-agent (two levels down) works unless `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` is set to `1`; if it cannot, the formatter reports a blocker and stops, and the other roles keep running. The Agent tool's `model` accepts only the aliases `opus`, `sonnet`, `haiku`, and `fable`; treat a full model ID in an override as rejected and fall back as above. Background agents surface every permission prompt in the main session and wait there. Do not use worktree isolation: the fixer must work in the branch's checkout, and reviewers already read code at the pinned SHA without touching the working tree.

## Rotation

The launcher is the **rotation coordinator**. It owns the deadline, the PR title, the exit decision, and all loop state; each pass agent does one bounded job, returns a short structured result, and exits. Pass agents follow the referenced mode's rules (bot/human classification, the 6/10 rule, frozen areas, attribution footers, completion markers, fidelity) exactly as in a standalone loop.

### State

Keep the state in `$(git rev-parse --git-common-dir)/botfight/<PR-number>/rotation.json` and rewrite it after every pass, so a compacted or restarted coordinator can recover it. Formatter hand-off files go in the same directory. Never commit them. State:

- PR URL, deadline, interval, models per role, round count.
- Fixer: original title, previous head SHA, last push time, frozen areas, human items with draft replies, findings fixed and declined.
- Per review scope (`general` and the security brief's `scope_id`): completed `(head SHA, review link)` pairs and any failure.
- Formatter: note comment ID and source digest, clarified or skipped source revisions, claim-map rejections.

### Round

1. **Check the deadline.** If it has passed, go to exit.
2. **Fetch PR status and head SHA.** Closed or merged means exit. On the first round, mark the title as in fixer step 2, recording the original title in state.
3. **Fixer pass.** Start one agent on the fixer model (Codex: the built-in `worker` agent). It runs one [Fixer iteration](../SKILL.md#fixer-iteration) against the pinned PR, given the frozen areas and human items already recorded, and returns: commits pushed, findings fixed and declined (score, link), new human items with draft replies, new frozen areas, CI status, and anything blocking. It never changes the title.
4. **Review passes.** Re-fetch the head SHA. For each scope that has no completed review of this head, start a reviewer agent on that scope's model (Codex: `default`); run the two scopes concurrently, since neither touches the working tree. Each runs reviewer loop steps 3 to 6 from [reviewer.md](reviewer.md) once, pinned to that head and scope, and returns the review link, finding count, or failure. Skip a scope whose review of this head is already complete.
5. **Formatter passes**, each on the formatter model, one after another:
   1. **Collect**: runs [formatter.md](formatter.md) loop steps 2 and 3. If the note digest matches and every source revision is clarified or skipped, it returns "unchanged" and the formatter steps end for this round. Otherwise it writes the source bundle (source bodies with author, link, and anchor, plus the current note) to `sources.json` and returns its path.
   2. **Format**: the formatting sub-agent from formatter.md, started by the coordinator. It reads `sources.json` and `formatter.md` only, and writes the revised note, clarifications, and claim maps to `formatted.json`.
   3. **Publish**: checks every claim map, rejecting outputs as formatter.md requires, then runs formatter loop step 5 and returns the note link, clarifications posted, and rejections.
6. **Decide.** Exit when the deadline has passed, the PR is closed or merged, or a pass reports a blocker only the user can resolve. Also exit when a round is quiet: the fixer's clean condition from `SKILL.md` step 4 holds, every scope has a completed review of the current head, and the formatter returned "unchanged". Otherwise wait until `interval` after this round started (or immediately if the round took longer), capped at the deadline, using a recurring wakeup if the harness has one and bounded foreground `sleep` calls if not. Carry `all <PR-URL> until <deadline> every <interval>` and the state file path in any wakeup.

### Exit

On every exit, including errors: restore the original title as in fixer step 6, then give one combined report: why the crew stopped and rounds run; the fixer exit report from `SKILL.md`; each scope's reviews and findings; the formatter's note link, clarifications, and rejections; and every human item with its draft reply, first.

**Codex specifics.** State `model` and `model_reasoning_effort` explicitly in each spawn request; explicit spawn values take precedence over `[agents]` defaults in `config.toml`. `gpt-6.1-terra` is OpenAI's model for clear writing and needs Codex CLI 0.159.0 or later; on an older CLI, run the formatter passes on the inherited model and say so. OpenAI documents no default or supported effort for it, so leave its effort unset. Subagents inherit the parent session's sandbox and approval policy, so the session must already allow network access and workspace writes, or the fixer cannot push. Rotation needs at most two open agent threads, which fits within `agents.max_concurrent_threads_per_session`.

**Grok Build specifics.** Start each pass agent as a `general-purpose` subagent and never request worktree isolation: Grok's worktrees are detached at their base commit, so a fixer there cannot commit to the PR branch. Grok sets subagent models only in config, through `[subagents.models]` in `~/.grok/config.toml`, which maps a subagent type to a model ID; a spawn cannot name its own model. So by default every role runs on the session's model; say so in the launch report, and tell the user that per-role models need a separate subagent type per role mapped in `[subagents.models]`. Between rounds, use Grok's `/loop` (minimum interval 60 seconds) when available, otherwise bounded `sleep` calls.
