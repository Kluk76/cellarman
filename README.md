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

## Components

| File | Role |
|---|---|
| `pm-kit/PROTOCOL.md` | The portable system-prompt core: intake contract, 6-part response contract, memory architecture, journal discipline, multi-dev rules. Instantiate with `{{placeholders}}` + a project annex. |
| `pm-kit/doctor.sh` | Health checks: index byte budget (warn/fail), oversized lines, dated-blockquote drift, dangling links, orphan topic files, agent-copy drift, multi-dev git sync (unpushed / behind-upstream / stale fetch), dormant topic files. Warn-only from hooks; `--strict` for CI. |
| `pm-kit/load-telemetry.sh` | PostToolUse(Read) hook — stamps every PM read of a topic file into a per-machine load log (`realpath`-canonicalized, so symlinked installs count). Feeds the doctor's dormancy check. |
| `pm-kit/catalog.sh` | The card catalog: regenerates a TSV of the whole topic corpus on demand (path · bytes · mtime · load telemetry · harvested `> Trigger …` lines · title). `--grep` for routing lookups beyond the index shortlist; `--audit` lists files with no harvestable trigger line. Gitignore the output — derived, and it embeds per-machine telemetry. |
| `pm-kit.conf.example` | The instance config: all paths + budgets. The kit scripts contain zero project knowledge. |
| `skeleton/agent-example.md` | A filled-in agent definition: PROTOCOL instantiated + a minimal project annex. |
| `skeleton/index-seed.md` | A starting memory index with the standard sections. |
| `skeleton/pm-sync.example.sh` | Auto-commit + best-effort push of the memory paths on git use, with a doctor call. |

## Installing on a project

1. Copy `pm-kit/` into your repo (e.g. `claude-brain/pm-kit/`) and write a
   `pm-kit.conf` next to it (start from the example; budgets: warn 48 KB /
   fail 64 KB — raise only when the *healthy* one-liner floor demands it,
   never to accommodate narration).
2. Create the agent file from `skeleton/agent-example.md`: frontmatter
   (`name`, routing `description`, `tools`, `model`) + PROTOCOL with
   placeholders filled + a `# PROJECT ANNEX` holding your project's
   source-of-truth chain, house rules, and divergence flags.
3. Seed the memory: `skeleton/index-seed.md` as the index, plus a memory
   directory with a journal topic file.
4. Register hooks in the project's tracked `.claude/settings.json`:
   PostToolUse(Read) → `load-telemetry.sh`; and a pm-sync-style
   PostToolUse(git commit/push) hook → `pm-sync.sh`.
5. Gitignore the load log AND the catalog output (both are per-machine:
   telemetry by design, the catalog because it embeds it).

### Second developer joining

1. Clone; install the agent definition + symlink the memory into
   `~/.claude/agents/`; re-run that install after any pull that touches the
   agent files (the doctor warns on copy drift).
2. **`git pull` before consulting the PM** — the brain is shared; the doctor
   warns when you're behind upstream or your sync push is stuck.
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
