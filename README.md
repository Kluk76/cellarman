# cellarman

**A project-manager work-companion for Claude Code — with a persistent,
git-synced, self-maintaining memory, and the enforcement that keeps that
memory from eating your token budget.**

A cellarman keeps the brewery's cellar: he minds what's maturing, knows
exactly what's in every tank, and tells you what's ready. This kit gives a
Claude Code project the same figure — a PM subagent that holds the whole
picture of a long-running build across sessions (and across developers), so
every consult starts from the true state of the project instead of a cold
context window.

Extracted from a real production system: a brewery ERP where this pattern has
tracked ~150 build arcs across two developers.

## The architecture in one paragraph

The PM is a Claude Code subagent (`.claude/agents/` or `~/.claude/agents/`)
whose memory is **two-tier**: an always-read **index** (the map — build-state,
sequencing, one-line pointers with load-triggers) and lazy-loaded **topic
files** (the depth — one per arc, read only when a trigger fires). The index
must stay small because every invocation pays for it; the corpus can grow
without bound because it's only loaded on demand — and because routing scales
past the index through a **card catalog**: a derived, regenerate-on-demand
TSV of every topic file (path, size, load telemetry, harvested trigger lines,
title) that the PM greps instead of growing the index, keeping the always-read
tier O(1) in corpus size. Memory writes itself back:
the PM records every consult's new build-state (bidirectional duty), and a
PostToolUse hook auto-commits + pushes the memory paths whenever you use git.
Discipline is **enforced mechanically, not instructionally**: a doctor script
caps the index, and a telemetry hook counts which topic files actually get
loaded so dead pointers surface.

Underneath that memory sits a **kernel pre-flight tier** that runs BEFORE the
PM opens its memory at all: **STEP 0** of the protocol is "measure before you
speak" — run `pm-kit/kernel/pm-preflight.sh` first, act on its exit code
(0 clear / 1 proceed-with-named-warnings / 2 STOP), and never sequence a
build past a STOP. Where the doctor watches the PM's *own* memory, the
pre-flight watches the *world* the PM is about to advise on: upstream
divergence, a shared mutable queue (e.g. migrations applied as a lexically-
ordered lot), global-namespace collisions, migration-slug-vs-created-object
drift, the open arbitration queue (age recomputed from an immutable ID, never
a hand-maintained field), and — via two companion kernel scripts — artefact-
keyed rails and path/lane ownership. **STEP 2** of the protocol pairs with
`rails-index.sh`, which mines the always-read index into a grep-able TSV
keyed on the artefact each rail protects (table/file/column/symbol), so a
build touching that artefact is warned by ADDRESS rather than by the PM
recalling it out of tens of KB of arc prose; `ownership-lint.sh` maps touched
paths against a durable `OWNERSHIP.map` (lanes by *concern*, not by file) and
a volatile `CLAIMS.tsv` (who is building here right now), with a `RATIFIED:`
receipt for legitimate cross-concern crossings. All three kernel scripts
carry **zero project nouns** — every project-specific value (team identities,
the shared git reference, queue paths, deploy target, ownership lanes,
artefact regexes) lives in one `profiles/<project>.conf` the scripts source
at startup (see `profiles/example.conf`). This is also why `PROTOCOL.md`
changed its instantiation style: the kernel now resolves `${TOKEN}` names
against an explicit **PROFILE BINDINGS** table, replacing the older inline
`{{placeholder}}` fill-in — so the kernel text itself never needs editing per
project.

## Components

| File | Role |
|---|---|
| `pm-kit/PROTOCOL.md` | The portable system-prompt KERNEL: STEP 0 pre-flight, STEP 1 index read (+ know-what-you-didn't-read), STEP 2 artefact-keyed rail routing, intake/response contracts, coordination duties (claims, post-merge coherence, sandbox-vs-global-namespace, environment-constant handoffs), memory discipline. Instantiate by copying the kernel block **verbatim**, filling a **PROFILE BINDINGS** table (`${TOKEN}` → real path/command — see the worked example inside the file), and adding a `# PROJECT ANNEX`. |
| `pm-kit/doctor.sh` | Health checks: index byte budget (warn/fail), oversized lines, dated-blockquote drift, dangling links, orphan topic files, agent-copy drift, multi-dev git sync (unpushed / behind-upstream / stale fetch), dormant topic files. Warn-only from hooks; `--strict` for CI. |
| `pm-kit/load-telemetry.sh` | PostToolUse(Read) hook — stamps every PM read of a topic file into a per-machine load log (`realpath`-canonicalized, so symlinked installs count). Feeds the doctor's dormancy check. |
| `pm-kit/catalog.sh` | The card catalog: regenerates a TSV of the whole topic corpus on demand (path · bytes · mtime · load telemetry · harvested `> Trigger …` lines · title). `--grep` for routing lookups beyond the index shortlist; `--audit` lists files with no harvestable trigger line. Gitignore the output — derived, and it embeds per-machine telemetry. |
| `pm-kit/kernel/pm-preflight.sh` | **STEP 0** — the clash detector: measure before you speak, before the PM reads anything else. Checks (repo-wide, not just the memory paths): upstream divergence + who's ahead/behind by name, a shared mutable queue applied as a lexically-ordered lot (disk ⇄ shared ref ⇄ deploy target, three-way, never a two-way "pending 0"), global-namespace collisions for anything new (a sandbox proves syntax, never uniqueness against the real target), declared-subject-vs-created-object drift, ownership (delegates to `ownership-lint.sh`), the open arbitration queue (age recomputed from an immutable ID, never a hand-maintained field), memory-store health (delegates to `doctor.sh`), and artefact-keyed rails (delegates to `rails-index.sh`). Exit 0 clear / 1 proceed-with-named-warnings / 2 STOP — a checker that can't stop a session is decoration. Zero project nouns; resolves everything from a profile. |
| `pm-kit/kernel/rails-index.sh` | **STEP 2**'s generator — mines the PM's always-read index (+ any extra corpus a profile declares) for rails whose violation surface names an artefact (table/file/column/symbol), and writes a grep-able `artefact <TAB> severity <TAB> rail <TAB> source <TAB> origin` TSV: recall by ADDRESS instead of recall by association. `--refresh-graph` expands transitively over a cached view-dependency graph, so a rail posed on a table also fires for every view (direct or transitive) that reads it — without a cache, expansion is reported UNMEASURED, never a silent pass. |
| `pm-kit/kernel/ownership-lint.sh` | Maps touched paths against a durable `OWNERSHIP.map` (lanes by *concern*, not by file — so a correct cross-concern change isn't blocked forever) and a volatile `CLAIMS.tsv` (who is building here right now). A `RATIFIED:` receipt records a legitimate cross-concern crossing, scoped to the act that carries it, rather than just refusing it forever; a `frozen` lane is the one wall ratification can't open. Exit 0 own-lane / 1 shared-or-ratified / 2 blocked-or-claimed — read the printed `own lane`/`SHARED lane` line, never the bare exit code. |
| `pm-kit.conf.example` | The instance config: all paths + budgets (index byte budget, topic-file split ceiling, archive-snapshot retention, optional skill-mirror check). The kit scripts contain zero project knowledge. |
| `profiles/example.conf` | The **one file allowed to carry project nouns**: team identities + the domains each rules on, the shared git reference, the shared mutable queue's paths, the deploy target, `OWNERSHIP.map`/`CLAIMS.tsv` locations, the string-coupled emitter⇄consumer watch-list, and the artefact-table regex `rails-index.sh` uses to tell a table from a column. Copy it, fill it in, and all three kernel scripts run unmodified — they never contain the project's own vocabulary. |
| `skeleton/agent-example.md` | A filled-in agent definition: kernel referenced (not duplicated) + a worked PROFILE BINDINGS table + a minimal project annex. |
| `skeleton/index-seed.md` | A starting memory index with the standard sections. |
| `skeleton/pm-sync.example.sh` | Auto-commit + best-effort push of the memory paths on git use, with a doctor call. |
| `skeleton/bin-pm-preflight.example.sh` | The thin project entrypoint a PROFILE BINDINGS table's `${PREFLIGHT_CMD}` points at: resolves the repo root and the project's profile, then execs `pm-kit/kernel/pm-preflight.sh` with it. Copy to `bin/pm-preflight.sh`. |

## Installing on a project

1. Copy `pm-kit/` — **including `pm-kit/kernel/`** — into your repo (e.g.
   `claude-brain/pm-kit/`) and write a `pm-kit.conf` next to it (start from
   the example; budgets: warn 48 KB / fail 64 KB — raise only when the
   *healthy* one-liner floor demands it, never to accommodate narration).
2. **Write a profile.** Copy `profiles/example.conf` to
   `pm-kit/profiles/<project>.conf` and fill in your team's identities and
   ruling domains, the shared git reference, your shared mutable queue's
   paths (if you have one), the deploy target, `OWNERSHIP.map`/`CLAIMS.tsv`
   locations, and the artefact regexes `rails-index.sh` needs to tell a table
   from a column. This is the only file allowed to name your project.
3. **Wire the pre-flight.** Copy `skeleton/bin-pm-preflight.example.sh` to
   `bin/pm-preflight.sh` — it just resolves the repo root and your profile,
   then execs `pm-kit/kernel/pm-preflight.sh` with it. This is the command a
   PROFILE BINDINGS table's `${PREFLIGHT_CMD}` row points at.
4. Create the agent file from `skeleton/agent-example.md`: frontmatter
   (`name`, routing `description`, `tools`, `model`) + the `PROTOCOL.md`
   kernel copied in **verbatim** + a **PROFILE BINDINGS** table resolving
   every `${TOKEN}` the kernel uses (`${PREFLIGHT_CMD}`, `${PM_INDEX}`,
   `${RAILS_INDEX}`, `${SHIPPED_INDEX}`, `${CLAIMS_FILE}`, `${CATALOG_CMD}`)
   + a `# PROJECT ANNEX` holding your project's source-of-truth chain, house
   rules, and divergence flags.
5. Seed the memory: `skeleton/index-seed.md` as the index, plus a memory
   directory with a journal topic file.
6. Register hooks in the project's tracked `.claude/settings.json`:
   PostToolUse(Read) → `load-telemetry.sh`; and a pm-sync-style
   PostToolUse(git commit/push) hook → `pm-sync.sh`.
7. Gitignore the load log, the catalog output, and the two `pm-preflight`-
   generated artefacts (`RAILS-BY-ARTEFACT.tsv`, the artefact-graph cache) —
   all four are derived and/or per-machine; every clone rebuilds them.

### Second developer joining

1. Clone; install the agent definition + symlink the memory into
   `~/.claude/agents/`; re-run that install after any pull that touches the
   agent files (the doctor warns on copy drift).
2. **`git pull` before consulting the PM** — the brain is shared; the doctor
   warns when you're behind upstream or your sync push is stuck. The kernel
   pre-flight needs no separate install: it runs straight off the shared
   `pm-kit/` + your profile, so its own P1 check (upstream divergence) is
   exactly what tells you that you're behind, on a fresh clone, before you've
   done anything else.
3. Your telemetry log is yours alone; dormancy findings are per-developer.

## Credits

The enforcement posture of this kit — hard caps instead of written intentions,
usage counters instead of trusted self-reporting, dead/dormant-entry detection
as a first-class memory-hygiene signal — is directly inspired by
[**codekeel**](https://github.com/HabibiCodeCH/codekeel) by
[@HabibiCodeCH](https://github.com/HabibiCodeCH): its decision-ledger
`MAX_INJECTED_ENTRIES` cap, per-entry `verifyCalls` counters, and
dead-scope/90-day-dormancy staleness review. codekeel is the *enforcement*
half of a project-memory story; cellarman is the *knowledge* half — they were
built independently and converged on "keep the always-loaded context thin,
verify mechanically."

## Design rules learned the hard way

- **Routing and journaling are different jobs.** The index routes; journals
  (dated entries) live in topic files. Gluing them together is how a 192 KB
  index happens (measured on the origin project: 44% of the index was one
  section's migration journal — compacted to 73 KB with zero information
  loss, all moves verbatim).
- **Caps + counters beat intentions.** The "keep it lean" rule existed in two
  places and still drifted — the doctor is the rule with teeth.
- **Rails compressed, never dropped.** Compaction moves narration; hard
  warnings stay in the index in short form.
- **Newest-first appends everywhere** — trivial merge conflicts between
  developers; resolution is always "keep both".
- **Don't trust self-reporting.** Telemetry hooks the tool call, not the
  agent's promise to log.
- **Verbatim relocation, wholesale snapshot first.** Every compaction starts
  by snapshotting the whole index into the memory's archive dir; moved content
  is never paraphrased at move time. Corollary, learned twice: **relocate
  BEFORE you rewrite** — compressing a line first and moving "it" second moves
  the paraphrase and silently deletes the original, and the result is coherent,
  shorter, and wrong. And conservation checks must grep SOURCE tokens, never
  your rewording of them.
- **The byte budget is a drift detector, not proof the index loads.** The
  binding constraint is the reader's token cap: an oversized index returns a
  successful-looking PARTIAL read and the routing table at the bottom silently
  falls off. Measure your corpus's tokens-per-byte, set the FAIL tier below
  the one-pass wall, and trust only the re-read (no partial banner) as proof.
  (Measured on the origin project: 0.53–0.54 tok/byte on dense emoji-heavy
  prose ⇒ wall ≈ 46 KB against a 25 000-token cap — under this kit's default
  64 KB FAIL.)
- **Write invariants as tests, not counts.** "This file names the ONLY
  generated artefact" was falsified by the very edit that added a second
  generator. "Everything called generated must have a generator you can point
  at" cannot go stale.

## License

MIT — see [LICENSE](LICENSE).
