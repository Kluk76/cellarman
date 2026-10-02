# cellarman

A project-manager subagent for Claude Code, with a memory that lives in your
repository. You consult it before a build and report back after one; it
answers from a written record and from a pre-flight script that measures the
repository at that moment. The kit is a system-prompt kernel, a set of bash
scripts that check what the prompt cannot, and templates to wire them in.

Extracted from a production ERP project where it has tracked about 150 build
arcs for two developers. The upkeep is real: that project's memory is around
20 MB of topic files, and about a fifth of its commits are memory syncs.

## Why not CLAUDE.md plus a TODO file

That works until the project outgrows one file, and then it fails quietly.

- CLAUDE.md is loaded into every session, so everything in it is paid for
  every time, and it has no notion of "only when you touch billing". Here the
  always-read part is one index with a size budget, and the rest is topic
  files loaded when their subject comes up.
- A TODO file says what someone meant to do. It does not say what the
  repository looks like now. The pre-flight does: whether your clone is
  behind, what is queued and unapplied, who has claimed the files you are
  about to touch, which recorded constraints are attached to them.
- Neither file can tell two parallel sessions that they are building the same
  thing. A claims file with a session field, and a script that is the only
  writer of it, can.
- Notes written by one session are read by the next as fact. The kernel
  treats them as claims: checked, or labelled as not re-checked.

If you work alone, in one session at a time, on a project that fits in a
CLAUDE.md, you do not need this.

## Quickstart

From an empty repository to a first consult. The commands keep the example
name `acme` so that every path lines up with the shipped templates; rename
afterwards. `K` is a checkout of this kit.

```bash
K=/path/to/cellarman          # git clone https://github.com/Kluk76/cellarman
cd /path/to/your-repo         # an existing repo, or: git init

# 1. the kit, its two config files, and the launcher
mkdir -p claude-brain/agents/acme-pm-memory bin docs .claude/hooks
cp -R "$K/pm-kit" claude-brain/pm-kit
mkdir -p claude-brain/pm-kit/profiles
cp "$K/profiles/example.conf"   claude-brain/pm-kit/profiles/acme.conf
cp "$K/pm-kit.conf.example"     claude-brain/pm-kit.conf
cp "$K/skeleton/bin-pm-preflight.example.sh" bin/pm-preflight.sh
chmod +x bin/pm-preflight.sh

# 2. the memory: index, shipped register, claims, ownership, arbitration
cp "$K/skeleton/index-seed.md"  claude-brain/agents/acme-pm-memory.md
printf '# Shipped arcs register\n' \
  > claude-brain/agents/acme-pm-memory/shipped-arcs-register.md
cp "$K/skeleton/dev-handoff-register.example.md" \
   claude-brain/agents/acme-pm-memory/dev-handoff-register.md
cp "$K/skeleton/CLAIMS.tsv.example"    claude-brain/CLAIMS.tsv
cp "$K/skeleton/OWNERSHIP.map.example" claude-brain/OWNERSHIP.map
cat "$K/skeleton/gitattributes.example" >> .gitattributes
cat "$K/skeleton/gitignore.example"     >> .gitignore

# 3. a plan document (the PM checks tasks against it)
printf '# Plan\n\n### P-1 First thing\nGoal: ...\nAcceptance: ...\n' > docs/PLAN.md

# 4. the agent file: template + kernel pasted between its two markers
awk '/^<!-- cellarman kernel: begin/{k=1} k; /^<!-- cellarman kernel: end/{k=0}' \
  claude-brain/pm-kit/PROTOCOL.md > "${TMPDIR:-/tmp}/kernel.md"
awk -v kf="${TMPDIR:-/tmp}/kernel.md" '
  /^<!-- cellarman kernel: begin/ { while ((getline l < kf) > 0) print l; skip=1; next }
  /^<!-- cellarman kernel: end/   { skip=0; next }
  !skip' "$K/skeleton/agent-example.md" > claude-brain/agents/acme-pm.md
mkdir -p ~/.claude/agents
cp claude-brain/agents/acme-pm.md ~/.claude/agents/acme-pm.md

# 5. the consultation rule, where every session will read it
cat "$K/skeleton/CLAUDE.md.snippet" >> CLAUDE.md

# 6. hooks (skip the settings copy if you already have a .claude/settings.json
#    and merge the "hooks" block by hand instead)
cp "$K/skeleton/pm-sync.example.sh" claude-brain/pm-sync.sh
cp "$K"/skeleton/hooks/*.sh .claude/hooks/
chmod +x claude-brain/pm-sync.sh .claude/hooks/*.sh
cp "$K/skeleton/settings.example.json" .claude/settings.json

# 7. check
export ACME_DEV=a             # the developer initial the example profile expects
bin/pm-preflight.sh > "${TMPDIR:-/tmp}/pf.log" 2>&1; echo "pre-flight exit: $?"
bash claude-brain/pm-kit/doctor.sh --strict > "${TMPDIR:-/tmp}/doctor.log" 2>&1; echo "doctor exit: $?"
```

Expected: the pre-flight exits 0 or 1 (in a repository with no remote it
warns that there is no shared reference), and the doctor exits 0. Read the
two log files; exit 2 from the pre-flight means a STOP and the log says which.
Then commit what you added, start `claude`, and ask:

    Use the acme-pm subagent. consult: question. What do you have on record for this project?

The agent file lives in the repository (`claude-brain/agents/acme-pm.md`) and
is copied to `~/.claude/agents/`, because that pair is what the doctor
compares. Copy it again after you edit it. You can install it under
`.claude/agents/` in the project instead; then point `PM_AGENT_INSTALLED` in
`pm-kit.conf` at that path.

After the first run, make it yours: rename `acme` in the profile, in
`pm-kit.conf`, in the agent file and in `settings.json`; fill the bindings
table and the annex in the agent file; replace the seed index's placeholders;
set the developers and lanes in the profile, or empty them if you work alone.

The layout is fixed in one respect: the scripts expect the kit at
`claude-brain/pm-kit/` under the repository root.

### A second developer joining

1. Clone, copy the agent file to `~/.claude/agents/`, set the developer
   variable (`ACME_DEV` in the example), and run
   `git config core.hooksPath .githooks` if the project uses the claims gate
   (`skeleton/githooks-pre-commit.example`). Git reads hooks only from that
   directory, and a clone without the setting commits with no gate and no
   message. The pre-flight checks for it.
2. Pull before consulting the PM. The memory is shared through git.
3. Load telemetry is per machine, so dormancy findings are per developer.

## Requirements

- bash 3.2 or later, git, awk, sed, grep, find.
- `jq`: optional for the two hooks under `skeleton/hooks/` (they fall back to
  `sed`). Required by `load-telemetry.sh`, `session-ledger.sh` and `pm-sync`:
  without it they exit 0 and do nothing, which means no telemetry and no
  automatic memory commits, with no error.
- Claude Code with subagents and hooks. The hook wiring uses the `if` field
  and exec-form `args`; see the hooks reference for the versions that support
  them.
- macOS: the kernel scripts are written for bash 3.2 and BSD tools, and CI
  runs on `macos-latest`. `doctor.sh`, `catalog.sh` and `load-telemetry.sh`
  have used GNU-only calls (`find -printf`, `md5sum`, `grep -P`,
  `realpath -q`). Where one of those is missing the affected check prints a
  passing line instead of an error. Check the CHANGELOG for the release that
  removes them before trusting those checks on a Mac.
- Windows: untested outside WSL.

## What a first consult looks like

Illustrative: the shape is what the kernel asks for, the content is invented.

The orchestrator (your main session) sends:

    consult: plan
    Plan item: P-7 (CSV export of invoices).
    Task: add an export endpoint and a button on the invoice list.
    Surfaces: src/billing/export.php (new), src/billing/list.php, table invoices.
    Constraints: no schema change.
    Changed since last consult: nothing.

The PM runs `bin/pm-preflight.sh --paths src/billing/export.php
src/billing/list.php`, reads its index, greps the rails index for `invoices`,
and answers:

    1. Pre-flight: exit 1. No STOP. One warning on a named surface:
       "WARN ownership src/billing/list.php is in a shared lane". 3 other
       warnings (2 arbitration, 1 memory). Unmeasured: queue target (no probe).
    2. Goal: P-7, "accountants can export a month of invoices without asking
       a developer". The task serves it. Acceptance criteria on record: a
       month of 5,000 invoices exports in one file; totals match the ledger.
    3. Architecture: reads `invoices` and `invoice_lines`; writes nothing.
       The ledger view owns totals; do not recompute them in the export.
    4. Rails: one WARN on `invoices`: "amounts are stored in minor units;
       format at the edge" (recorded 2026-03-02, not re-checked).
    5. Sequencing: nothing has to land first. Safe to build in one session.
    6. Divergence: a second total computed in the export would diverge from
       the ledger view.
    7. Ownership: list.php is shared with the UI lane; its owner should look
       at the button before it ships. No open claim on these files.
    8. Recommendation: build it; take totals from the ledger view; one
       session, so no claim is needed.
    9. Open decisions: none in billing. 2 others open, none overdue.

After the build, the orchestrator sends a `consult: report-back` with the
commits and how far the change got. The PM writes the record first and ends
its reply with the paths it wrote.

A question of fact gets a short answer: the pre-flight verdict, the answer,
and where the answer comes from.

## What a consult costs

Every consult loads, before any reasoning: the agent file (kernel, bindings,
annex), your CLAUDE.md, the index, and the pre-flight output. Topic files are
extra, when read.

These are estimates from byte counts, not tokenizer measurements:

| part | size | rough tokens |
|---|---|---|
| kernel (this release) | about 20 KB of plain prose | about 5,000 |
| bindings and annex | 3 to 6 KB | about 1,000 |
| index, fresh install | 2 to 3 KB | under 1,000 |
| index, mature project | up to your budget | the origin's 44 KB index, dense with markers, measured about 0.54 tokens per byte: about 24,000 |
| pre-flight output and rail hits | 2 to 10 KB | 1,000 to 3,000 |

So a fresh install costs on the order of 8,000 tokens per consult before the
PM thinks, and a mature project several times that. The protocol asks for two
consults per build. On the model the example agent file names (`opus`) that
is not free; `model: inherit` or `sonnet` in the frontmatter is the lever.

To measure your own:

- Bytes: `wc -c ~/.claude/agents/acme-pm.md claude-brain/agents/acme-pm-memory.md CLAUDE.md`,
  plus the size of a pre-flight log. Plain English runs near 4 bytes per
  token; text dense with symbols, tables or emoji runs near 2.
- Tokens: a `PostToolUse` hook matched on the `Agent` tool receives
  `tool_response.totalTokens` and `tool_response.usage` for a foreground
  subagent. Per the hooks reference these describe the subagent's final
  request, which for a consult is its whole context at the end. Log that
  field for a few consults.

## Architecture

**The agent file** is the PM's system prompt: the kernel from
[`pm-kit/PROTOCOL.md`](pm-kit/PROTOCOL.md), a bindings table that maps the
kernel's `${TOKENS}` to your paths, and your own annex of house rules. The
kernel is a procedure: run the pre-flight, read the index, look up what is
recorded about the surfaces in question, separate what was measured from what
was recorded, answer in a fixed shape, write the record on a report-back.

**The memory** has two tiers. The index is read on every consult and holds
rules, standing facts and pointers. Topic files, one per arc or subject, are
read when a trigger word comes up. A catalog script regenerates a table of
every topic file on demand, so routing does not require the index to list
them all.

**The pre-flight** (`pm-kit/kernel/pm-preflight.sh`) measures the repository
and exits 0, 1 or 2: clone against the shared reference, a shared queue of
changes (migrations, typically) on disk, on the shared reference and on the
target, name collisions for new objects, ownership of the paths you pass, the
arbitration queue with ages computed from item ids, the doctor's verdict on
the memory, and rails attached to the paths you pass.

**Rails** are constraints recorded in the index against a named surface.
`rails-index.sh` mines them into a table keyed by surface, so that a build
touching the surface finds the rail by lookup.

**Ownership and claims.** `OWNERSHIP.map` says who decides what, by concern.
`CLAIMS.tsv` says who is building where right now; `claim.sh` is its only
writer and records the session, and a pre-commit lint refuses a live row
without one.

**Sync.** `pm-sync` commits the memory files the current session wrote
(per a ledger kept by `session-ledger.sh`) when you use git, and pushes only
when nothing but memory commits would go out.

**The doctor** (`pm-kit/doctor.sh`) checks the memory itself: index size,
oversized lines, dangling links, orphan and dormant topic files, drift
between the agent file in the repository and the installed copy.

| file | role |
|---|---|
| `pm-kit/PROTOCOL.md` | The kernel and the canonical bindings table. |
| `pm-kit/LESSONS.md` | Why each rule exists: incidents and measurements from the origin project. Not read during a consult. |
| `pm-kit/KERNEL-MIGRATION.md` | Where each rule of the previous kernel went. |
| `pm-kit/kernel/pm-preflight.sh` | The pre-flight. Exit 0 / 1 / 2. |
| `pm-kit/kernel/rails-index.sh` | Generates the rails table from the index. |
| `pm-kit/kernel/ownership-lint.sh` | Paths against the ownership map and the claims file. |
| `pm-kit/kernel/claim.sh` | The only writer of claim rows. |
| `pm-kit/kernel/session-ledger.sh` | PostToolUse hook: which session wrote which memory file. |
| `pm-kit/lint-claims-session.sh` | Pre-commit gate for claim rows. |
| `pm-kit/doctor.sh` | Memory health. Exits 0 unless `--strict`. |
| `pm-kit/catalog.sh` | Catalog of topic files; `--grep`, `--audit`. |
| `pm-kit/load-telemetry.sh` | PostToolUse hook: counts topic-file reads. |
| `pm-kit.conf.example` | Paths and budgets for the doctor, catalog, telemetry, sync. |
| `profiles/example.conf` | Everything project-specific the kernel scripts read. |
| `skeleton/agent-example.md` | Agent file template with the bindings filled for a fictional project. |
| `skeleton/CLAUDE.md.snippet` | The consultation rule for your CLAUDE.md. |
| `skeleton/settings.example.json` | Hook wiring for `.claude/settings.json`. |
| `skeleton/hooks/pm-consult-nudge.sh` | Optional SessionStart reminder. |
| `skeleton/hooks/pm-report-back-gate.sh` | Optional one-shot gate on report-back consults. Off by default. |
| `skeleton/pm-sync.example.sh` | Session-scoped memory commit and guarded push. |
| `skeleton/*.example*`, `skeleton/index-seed.md` | Templates for the index, claims, ownership map, arbitration register, git attributes, gitignore, pre-commit hook, launcher. |

### Hooks

`skeleton/settings.example.json` wires four things. JSON has no comments, so
the notes are here. Event names, matchers, the `if` field and exec-form
`args` are as documented at <https://code.claude.com/docs/en/hooks> (read
2026-10-02).

| event and matcher | script | needed? |
|---|---|---|
| `PostToolUse`, `Read` | `load-telemetry.sh` | For the doctor's dormancy check. |
| `PostToolUse`, `Write\|Edit` | `session-ledger.sh` | For `pm-sync`: without it the sync commits nothing. |
| `PostToolUse`, `Bash` with `if: Bash(git commit *)` and `Bash(git push *)` | `pm-sync.sh` | For automatic memory commits. The `if` filter is documented as best-effort. |
| `SessionStart`, `startup\|clear\|compact` | `pm-consult-nudge.sh` | Optional. Remove the block if your CLAUDE.md carries the rule and you do not want the tokens (about 670 bytes per session start). |

The report-back gate is not in that file. It is wired in the agent file's
frontmatter, and only if you add it; `skeleton/agent-example.md` shows how
and the script's header says what it cannot do.

With `pm-sync` wired, a commit can be followed by an automatic push of memory
commits. A commit is then not a purely local act. Do not chain a push and a
deploy on the assumption that only your commits are going out.

Nothing checks that these hooks are wired. A hook cannot report its own
absence, and no script in the kit reads `.claude/settings.json`.

### Relation to Claude Code's own memory

The kit does not use the subagent `memory` frontmatter field or auto memory.
Its memory is ordinary files in your repository, read with the Read tool and
shared through git. If you also use auto memory, the two stores do not know
about each other; keep project build state in the PM's files.

## Limits

What the kit does, sorted by what actually enforces it. "Mechanical" means a
named script or hook does it without the model's cooperation. "Model" means
it is an instruction in the kernel, the CLAUDE.md snippet or the agent
description, and holds as long as the model follows it. "Absent" means
nothing does it.

| promise | what carries it | class |
|---|---|---|
| The main session consults the PM before a build | agent description; `CLAUDE.md.snippet`; optional `pm-consult-nudge.sh` | Model. Three reminders, no gate. Claude Code documents no way to force a consult, and nothing detects a build planned without one. |
| The PM runs the pre-flight first | kernel, step 0 | Model. |
| The pre-flight covers the build in question | kernel passes `--paths`; a bare run is reported as "not measured for this build" | Model. The script checks ownership and rails only for paths it is given. |
| A STOP stops the build | `pm-preflight.sh` exits 2 | Mechanical detection, model enforcement. The PM is advisory; nothing blocks the main session's tools. |
| An ambient STOP is reported as a warning | kernel | Model. The script does not mark which paths were always-checked. |
| Claims record the session | `claim.sh`; `lint-claims-session.sh` as a pre-commit hook | Mechanical, if `core.hooksPath` is set. `pm-preflight.sh` checks that setting. |
| A claimed or owned path is flagged | `ownership-lint.sh` through the pre-flight | Mechanical for the paths passed. |
| Recorded rails are found for a surface | `pm-preflight.sh` greps the rails table | Mechanical for the paths passed, if someone has run `rails-index.sh` since the index changed. Nothing regenerates the table automatically. Non-path surfaces are grepped by the PM: model. |
| The memory is updated after a build | kernel ("write before you answer"), if the main session sends a report-back; optional `pm-report-back-gate.sh` blocks once | Model on both sides. The gate is one extra turn, not a guarantee, and can provoke a filler write. A build that lands with no report-back is not detected: absent. |
| Memory files reach git | `pm-sync` with `session-ledger.sh` | Mechanical for files written with Write or Edit, when the hooks are wired and `jq` is installed. A memory file written through Bash is not in the ledger and is left uncommitted. The sync transports writes; it does not cause them. |
| The index stays within budget | `doctor.sh` measures; the pre-flight turns a doctor failure into a STOP | Half mechanical. The doctor exits 0 unless `--strict`, and the STOP binds only a PM that runs the pre-flight. |
| The index is read whole | kernel; byte budget in `pm-kit.conf` | Model. The budget is in bytes and the read limit is in tokens; the default budgets are not calibrated to your text. See "Budgets" in `PROTOCOL.md`. |
| The memory maintains itself | hygiene passes by the PM under the kernel's rules | Model, with human rulings. The origin project needed repeated human-ordered passes. No lock tool ships for the "one writer at a time" rule. |
| Unused topic files surface | `load-telemetry.sh` and the doctor | Mechanical, when the hook is wired and `jq` is installed. |
| The catalog is current | `catalog.sh` regenerates on each call | Mechanical for the file list. Trigger lines are written by the PM (model); a stale one is not detected. |
| Statements are checked or labelled | kernel, "Provenance" | Model. |
| The build serves the plan | kernel goal check against `${PLAN_DOC}` | Model. No script reads the plan document, and nothing compares what was built with what was asked. |
| The agent file carries the current kernel and binds every token | two commands in `PROTOCOL.md`, run by hand | Absent as a mechanism. The doctor compares the repository copy with the installed copy, not the kernel with `PROTOCOL.md`. |
| The hooks are wired | nothing | Absent. |
| A code commit without a memory update is flagged | nothing | Absent. Planned as a pre-flight warning. |
| Deleted files are removed from a deploy target | nothing | Absent. The profile has a variable for it that no check reads. |

Three things follow. The kit gives well-informed advice when asked and loud
detectors when run; it does not keep a session on its goal by force. Its
mechanical part is about collisions between sessions and the health of the
memory, not about what you meant to build. And several rows above depend on
optional wiring, so an install that skipped the hooks has fewer guarantees
than this table and no message saying so.

The kernel scripts are not free of the origin project's vocabulary. Some
messages and comments are still in French, the arbitration closure words are
hard-coded, and a few checks assume a SQL migration queue. The CHANGELOG
tracks their removal.

## Design rules

- Routing and journaling are different jobs. The index routes; dated entries
  live in topic files.
- A budget with a script behind it holds better than a sentence. The "keep
  it lean" rule existed in two places and the index still grew.
- Rails are compressed, not dropped. Narration moves; it is not deleted.
- Newest-first appends, so that two developers' additions merge by keeping
  both.
- Count the tool call, not the agent's account of it. Telemetry hooks the
  Read.
- Relocate before you rewrite, and check conservation by grepping tokens of
  the source text.
- The byte budget is a drift detector. Proof that the index loads is a read
  with no partial-view notice.
- Write invariants as tests, not counts. "Everything called generated has a
  generator you can point at" cannot go stale; "this is the only generated
  file" did.
- A stale line in an auto-loaded document is worse than a missing one, and a
  document that is not auto-loaded ages without anyone noticing.
- A detector that fires on every run stops being read.
- A rule needs a carrier. If nothing can carry it, say that it depends on
  memory.

The incidents behind these are in [`pm-kit/LESSONS.md`](pm-kit/LESSONS.md).

## Credits

The posture of this kit (caps in place of intentions, usage counters in place
of self-reporting, dormant-entry detection as a hygiene signal) is inspired by
[codekeel](https://github.com/HabibiCodeCH/codekeel) by
[@HabibiCodeCH](https://github.com/HabibiCodeCH): its decision-ledger
`MAX_INJECTED_ENTRIES` cap, per-entry `verifyCalls` counters, and 90-day
dormancy review. The two were built independently.

## License

MIT. See [LICENSE](LICENSE).
