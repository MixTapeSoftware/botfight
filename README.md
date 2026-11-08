# Skills

Agent skills from MixTape Software, packaged as the `mixtape` Claude Code plugin. Each directory under `skills/` is one self-contained skill: a `SKILL.md` with frontmatter (`name`, `description`) plus any reference files it links to.

| Skill | What it does |
| --- | --- |
| [botfight](skills/botfight/SKILL.md) | Runs an unattended PR loop: a **fixer** that triages review-bot findings and a **reviewer** that posts inline findings for the fixer, ## Installation

Install the plugin in Claude Code:

```
/plugin install mixtape --marketplace MixTapeSoftware/skills
```

On Claude Code older than 2.1.275, add the marketplace first:

```
/plugin marketplace add MixTapeSoftware/skills
/plugin install mixtape@mixtape
```

Pull new versions with `/plugin marketplace update mixtape`, or turn on auto-update for the marketplace in `/plugin`. Consumers receive a release when `version` in `.claude-plugin/plugin.json` is bumped, so bump it (semver) with every change you want to ship.

Plugin skills are namespaced, so botfight is also available as `/mixtape:botfight`.

Other agents: copy `skills/botfight` into the agent's skills folder.

ory
cp -r botfight <your-repo>/.claude/skills/
```

---

# botfight

Botfight keeps a pull request moving while you are away. It polls the PR on an interval, handles automated review feedback on its own, and leaves everything a human said for you to deal with.

It has three modes:

- **fixer** (default): addresses findings from review bots and CI on the current branch's PR. It fixes the important ones, declines the rest, and resolves the threads.
- **reviewer**: watches a PR and posts one inline code review per new head commit, which a fixer loop can then triage.
- **formatter**: keeps a plain-English PR note current and posts clearer restatements of hard-to-follow bot comments, without adding information.

The modes can run side by side in separate sessions: the reviewer finds issues, the fixer addresses them, and the formatter keeps both readable.

## Requirements

- The [`gh` CLI](https://cli.github.com/), authenticated as you. Botfight posts every comment, reply, and review **from your GitHub account**.
- An agent harness with a recurring-wakeup capability (for example Claude Code's `/loop`) to run in the background. Without one, the loop stays in the foreground.
- For fixer: a branch you're free to push to. The repository's `AGENTS.md` should document the verification checks to run before pushing.

## Usage

```
/botfight [fixer] [<interval> <duration>]
/botfight reviewer [<PR-number-or-URL>] [<interval> <duration>] [<instructions>]
/botfight reviewer [<PR-number-or-URL>] [<interval> <duration>] --skills <area>, <area>, ...
/botfight formatter [<PR-number-or-URL>] [<interval> <duration>]
```

All modes check every **5 minutes** for **1.5 hours** unless told otherwise.

| Example | Meaning |
| --- | --- |
| `/botfight` | Fixer on the current branch's PR, 5m interval, 1.5h duration. |
| `/botfight fixer 10m 2h` | Fixer, checking every 10 minutes for 2 hours. |
| `/botfight reviewer` | General review of the current branch's PR. |
| `/botfight reviewer 42 5m 1h focus on security and tenant isolation` | Review PR #42 with a custom brief. |
| `/botfight reviewer 42 -- 10m is the cache TTL, check it` | Everything after `--` is treated as instructions. |
| `/botfight reviewer 42 5m 1h --skills security, ui polish` | One separate review per area, each guided by the closest matching repository skill. |
| `/botfight formatter 42` | Keep PR #42's note current and clarify its bot comments. |

You can also trigger it in plain language, e.g. "run botfight", "fight the bots on this PR", or "botfight reviewer".

## Fixer mode

On start, fixer finds the PR for the current branch (or pushes and opens one) and prefixes its title with `🤖⚔️ [botfight] `. The prefix means "an unattended loop is active on this PR". The original title is restored on every exit path.

Each iteration gathers unresolved review threads (outdated ones included), CI status, and top-level comments, then works through three rules.

### 1. Classify every author as bot or human

- **Bot**: GitHub `Bot` accounts, logins ending in `[bot]`, known review/CI bots (`github-actions`, `vercel`, `render`), and comments from your account that carry a botfight attribution footer.
- **Human**: everyone else, including any account botfight is unsure about.

Whole threads are classified, not just their first comment. One human reply in a bot thread makes the entire thread human.

### 2. Bot findings: the 6/10 rule

Each bot finding is first checked against the current code. Findings the code disproves are declined with evidence. The rest are scored 1–10 for importance: correctness, security, data isolation, and data loss score high; style and naming score low.

| Score | Action |
| --- | --- |
| **≥ 6** | Fix the code, verify, push, reply with the commit reference, resolve the thread. |
| **< 6** | Leave the code alone. Reply that the finding was declined as below the unattended-fix bar (with its score), and resolve the thread. |

The threshold limits unattended churn. "It's a 30-second fix" doesn't override it.

### 3. Human comments: report, never act

Botfight **never** edits code because of a human comment, never replies to a human, and never resolves a human's thread. Human comments may carry scope or design decisions, and a reply would go out in your name without you reviewing it. Instead, each human item is quoted in the exit report with a **draft reply** you can post or discard.

If a human contradicts a fix botfight already made, that code area is **frozen**: no revert, no re-apply, no further bot fixes there. The conflict goes at the top of the report.

### When fixer stops

The loop ends when any of these is true:

- The PR is merged or closed.
- **Clean**: CI is green, there are no unresolved bot threads or new bot comments, and nothing was pushed since the previous iteration. After a push, botfight always waits at least one more interval so review bots can look at the new commit.
- The deadline passes.
- It's blocked on something only you can decide.

The exit report covers why it stopped, findings fixed and declined (with scores and links), human items with draft replies, any frozen areas, CI status, and whether the title prefix was removed.

## Reviewer mode

Reviewer watches an existing PR (it never creates one) and reviews **each new head commit once** per review scope.

- **Brief**: free-text instructions shape the review. "Focus on security" sets a priority; "only review authentication" sets a hard limit. With no instructions, it reviews correctness, regressions, security, and test coverage.
- **Skills**: reviewer loads any repository skill that covers the brief. With `--skills`, each comma-separated area is reviewed by its own sub-agent using the closest matching skill and gets its own review. Areas with no matching skill are reported back to you rather than reviewed from general knowledge.
- **State machines**: when the PR adds or changes UI elements or stateful logic (flags, status fields, branching, async lifecycles), reviewer models that code as finite state machines and checks for dead ends, impossible states, unhandled events, and missing recovery or cleanup. Each finding includes the event sequence that reaches the defect, and the review summary includes the transition tables.
- **Output**: one GitHub `COMMENT` review per head and scope, never `APPROVE` or `REQUEST_CHANGES`. Findings are inline comments anchored to the diff, each with a title, an importance score on the fixer's 1–10 scale, the trigger and impact, and a suggested fix. When there are no findings, the review is a summary that says so.
- **Read-only**: reviewer never edits code, commits, pushes, changes the PR title, or replies to or resolves threads. It reads source at the reviewed SHA and doesn't touch your working tree.
- **Deduplication**: each review summary contains a hidden marker, `<!-- botfight:reviewer head=<sha> scope=<scope-id> -->`, where `scope-id` is the SHA-256 of the instruction text (or `general`). This lets a resumed loop see what it already reviewed and avoid posting duplicates.

Reviewer keeps watching until the deadline, cancellation, or PR close/merge. A clean review or green CI is a reason to keep waiting, not to stop.

## Formatter mode

Formatter watches an existing PR and does two things on each pass:

- **PR note**: one formatter-owned top-level comment, edited in place, that states in plain technical English what the PR changes, which bot-raised issues are open, and which were addressed.
- **Clarifications**: where a bot comment or review finding is hard to follow, a reply in its thread that restates the same issue more clearly, using a Mermaid diagram or ASCII sketch when that conveys it better than prose.

**Fidelity is a hard requirement.** Formatter never adds facts, findings, fixes, or opinions, and keeps the source's hedges, scope, and severity. Each output comes with a claim map tying every sentence and diagram element to the source it restates; output with an unmapped claim is not posted.

Formatter never edits other comments, the PR title, the description, or code, and never posts in human threads. The rewriting always runs in a dedicated sub-agent, so formatting work doesn't compete with the reasoning work of the fixer or reviewer. Fixer and reviewer treat formatter comments as restatements, not new findings.

## Attribution

Every comment botfight posts ends with a footer, which is also how each mode recognizes the other's comments:

```
---
🤖 botfight · <agent harness> (<model id>)
```

```
---
🤖 botfight reviewer · <agent harness> (<model id>)
```

```
---
🤖 botfight formatter · <agent harness> (<model id>)
```

Comments from your account without a footer are treated as yours (human).

## Files

- [`skills/botfight/SKILL.md`](skills/botfight/SKILL.md): invocation, shared loop state, fixer mode, attribution.
- [`skills/botfight/references/reviewer.md`](skills/botfight/references/reviewer.md): reviewer mode.
- [`skills/botfight/references/formatter.md`](skills/botfight/references/formatter.md): formatter mode.

## License

[MIT](LICENSE)
