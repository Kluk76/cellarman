# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/) from 0.2.0 on.

## [0.2.0] - 2026-10-02

The first release that installs and runs on a project that is not its origin.
It is the sum of four pieces of work: the audited script defects, the sync /
claims / scaffolding ports, protocol v3 with a rewritten README and optional
hooks, and an integration pass that made the scripts deliver what the new
protocol and README promise and proved the quickstart by running it.

### Behaviour changes

Read these before upgrading an existing install.

- **Exit code 3 means "did not run".** `pm-preflight.sh`, `ownership-lint.sh`,
  `rails-index.sh`, `lint-claims-session.sh` and `doctor.sh` (missing conf) exit 3
  when nothing was measured: no profile, a bad argument, a missing tool, an
  unusable repo root, and, for the lint, no ownership map or an unknown acting
  developer. Before, "no profile" was exit 2 (a STOP), usage errors were 64, the
  lint used 1 (the code of a shared lane) for "cannot judge", and the claims gate
  used 2. 0, 1 and 2 are verdicts; any other code means no verdict exists. The
  launcher passes every code through and exits 3 itself when the kernel is missing.
- **Open arbitration items past `PF_ARB_STOP_DAYS` are an ambient WARN**: marked
  `[ambient]`, with id, title, age and the threshold, counted in the verdict line
  and in `"ambient_warn"` of the `--json` summary, and never exit 2 by themselves. The
  register is checked on every run whatever the build is, so a hard STOP would freeze
  every unrelated build behind one stale item; whether an item is in this build's
  domain is the PM's call (kernel, Response item 9).
- **An always-checked (ambient) STOP is a WARN**, marked `[ambient]` in text and
  `"ambient":true` in `--json`. A STOP that comes from a governance path
  (`PF_ALWAYS_PATHS`) and not from the build's own paths no longer blocks unrelated
  work. Governance paths are passed to the lint as `--claim-exempt`: the lane check
  still applies, the claim check is waived.
- **`claim.sh` does not push unless asked** (`--push` or `PF_CLAIM_PUSH=1`), and
  even then it refuses when the branch carries other unpushed work. The pm-sync
  example no longer runs a bare `git push`: it pushes only when nothing but memory
  commits would go out.
- **Solo mode.** A repository with no remote, or whose `PF_REF_NAME` branch is not
  pushed, is one WARN ("single-clone mode"), not a permanent STOP; every comparison
  against the shared reference prints n/a. The doctor's "never fetched" warning is
  n/a with no remote.
- **`unmeasured` is a level.** A check whose target the profile declares but that
  could not be reached prints `UNMEASURED` (level `unmeasured` in `--json`, counted
  separately in the verdict line and in a new `"unmeasured"` field of the summary
  object) and keeps exit 1. A target the profile never declares prints n/a and
  changes nothing, so exit 0 (CLEAR) is reachable.
- **A claim's session field has one form**: `PF_SESSION_PREFIX` plus the first 8
  characters of the session id. `ownership-lint` recognises a hand-typed full id (or
  the 8 characters without the prefix) as the current session, and rejects any other
  malformed field by name, quoting the expected form; the pre-commit gate refuses an
  added live row that is not in that form.
- **The profile lost every variable no script read** (91 of them: queue, namespace,
  deploy, coupling, duplicate and fiscal sections, memory tiers, `DOMAIN_*`) and the
  6-field `PF_CLAIMS_FORMAT`. An old profile that still sets them keeps working
  (they are ignored); nothing to migrate. Renamed: the pre-flight check `mig-vps` is
  `queue-target`; the doctor's snapshot key `CLE-RESOLUTION-LIENS` is
  `LINK-RESOLUTION-KEY`; the fifth rails TSV column says `column:<col>` where it said
  `colonne:<col>`; the catalog no longer harvests "> Declencheur" trigger lines.
- **The doctor can FAIL on three new things** (so `doctor.sh --strict` can start
  failing on an existing install): a kernel token with no bindings row in the agent
  file, a leftover `PASTE-KERNEL-HERE` placeholder or no kernel block, and
  `PM_INDEX` and `PF_PM_INDEX` naming different files. Kernel drift against
  `PROTOCOL.md` is a WARN.
- **The pre-flight can warn on two new things**: `memory-fresh` (N code commits since
  the last memory commit; `PF_MEMORY_COMMIT_WARN`, default 10, 0 = off) and
  `rails-stale` (the index is newer than the rails table).
- **The arbitration check reads the profile**: header pattern `PF_ARB_HEADER_RE`
  (default `^### `), id pattern `PF_ARB_ID_RE`, closure words `PF_ARB_CLOSED_RE`, an
  optional declared-age pattern `PF_ARB_DECLARED_AGE_RE`. The French "· N j" age
  field is no longer read, and the pre-flight carries no escalation wording at all:
  the line states id, title, age and threshold, and the policy lives in the agent
  file's `${ESCALATION_POLICY}` binding.
  The doctor's register check (section 12) follows `PF_ARB_FILE` instead of a
  hardcoded file name.
- **`PF_QUEUE_TARGET` is now used** as the command that lists the queue on the
  deploy target (with `--probe-db`); the pre-flight used to ignore it.
- Messages and comments in every script are English.

### Added

- `pm-kit/init.sh`: installs the kit into a repository for a project name and a
  developer initial. Idempotent, never overwrites (exit 2 and nothing written when an
  existing file differs), `--dry-run`, `--no-agent-install`. Generates a profile with
  no fictional queue or deploy host and a solo ownership map, so a committed, pushed
  install reaches pre-flight exit 0.
- `tests/quickstart.sh`: extracts the README quickstart's command blocks and expected
  exit codes mechanically (marker comments) and runs them verbatim in an empty
  sandbox, once with no remote and once with a remote the publish block pushes to.
- `tests/init.sh`, `tests/conf-surface.sh` (fails with `UNREAD` / `UNDOCUMENTED` when
  the example profile or `pm-kit.conf.example` and the scripts disagree),
  `tests/ports.sh` (sync, ledger, claims) and `tests/smoke.sh` (the audited defects,
  each with a case that fails without its fix). CI runs them on ubuntu and macOS, and
  again under mawk with `LC_ALL=C`; shellcheck runs non-blocking.
- Doctor checks: tokens against bindings rows, kernel block against `PROTOCOL.md`,
  placeholder, hook wiring in `.claude/settings.json` (info only), rails written
  outside list items, one index in two configs.
- Pre-flight: the `[ambient]` marker, the `unmeasured` level, `memory-fresh`,
  `rails-stale`, each open arbitration item listed with its id and title, `--`
  to end the option list (a path may start with `--`), a tool check that exits 3.
- `skeleton/pm-sync.example.sh`, rewritten: detects untracked new memory files;
  session-scoped (commits only the memory files this session wrote, per the ledger;
  `--all` as the explicit escape; fail-closed with no stdin, no jq or no ledger);
  steps aside when non-memory paths are staged; serialises on a lock in the git
  common dir (`flock`, or a portable `mkdir` lock); refuses to push when any commit
  ahead touches a non-memory path; no remote or upstream means a local commit and
  exit 0; `PM_SYNC_MSG` overrides the message.
- `pm-kit/kernel/session-ledger.sh` (which session wrote which memory file),
  `pm-kit/kernel/claim.sh` (the only writer of claim rows: `open|close|restate|abandon`,
  7th `session` field, TAB/CR/LF sanitising, `--dry-run`, `--no-commit`, opt-in
  `--push`, refusal without the dev variable), `pm-kit/kernel/profile-lib.sh`.
- `pm-kit/lint-claims-session.sh` and `skeleton/githooks-pre-commit.example`: the
  claims pre-commit gate (refuses a live row without a canonical session field and
  any blank row, warns on duplicate fields 1..4, `--dupes`, `--self-test` in both
  polarities).
- `skeleton/` templates: `OWNERSHIP.map.example`, `CLAIMS.tsv.example`,
  `gitattributes.example`, `gitignore.example`, `dev-handoff-register.example.md`,
  `CLAUDE.md.snippet`, `settings.example.json`, the optional `pm-consult-nudge.sh`
  and `pm-report-back-gate.sh` hooks.
- `pm-kit/LESSONS.md` (the incidents behind the kernel's rules),
  `pm-kit/KERNEL-MIGRATION.md` (where each rule of the previous kernel went),
  `VERSION`, this changelog.

### Changed

- `pm-kit/PROTOCOL.md`: the kernel is rewritten (protocol v3), delimited by
  `<!-- cellarman kernel: begin -->` and `... end -->`. Agent files carrying the
  previous kernel should be re-instantiated (the re-paste command is in the file).
  Consults have a declared kind and the answer's shape follows it; a goal check
  against `${PLAN_DOC}`; a bare run is reported as not measured for the build; an
  ambient STOP is reported as a warning; "could not reach its target" is its own
  result; statements from memory, the consult or a delegated agent are checked or
  labelled; on a report-back the record is written before the answer. One bindings
  table, with `${CLAIM_CMD}`, `${SESSION_PREFIX}`, `${MEMORY_DIR}`,
  `${ARBITRATION_REGISTER}`, `${PLAN_DOC}`, `${ESCALATION_POLICY}` and
  `${JOURNAL_DIR}` added. History moved to `LESSONS.md`.
  The exit-code sentence says that 1 means warnings or unmeasured checks and that 3
  means the pre-flight did not run and nothing was measured.
- `README.md` rewritten for a first-time reader: a quickstart that is a test, a
  requirements list, an illustrative consult, token cost, and a Limits table that
  says which promises a named script enforces, which depend on the model, and which
  are absent.
- `skeleton/index-seed.md` holds no moving quantity (no change-log head, build-state
  or resume point): rules, rails as list items naming a surface, standing facts,
  pointers. It passes `doctor.sh --strict` with zero warnings.
- `profiles/example.conf` and `pm-kit.conf.example` list exactly what the scripts
  read; one index naming scheme across both; the default extra rails corpus is empty.
- `skeleton/agent-example.md`: a new description, a bindings table for every token,
  optional gate wiring.
- `rails-index.sh`: an expansion graph that is not declared at all is n/a (exit 0); a
  declared one that cannot be read stays UNMEASURED (exit 1).

### Fixed

Audit references are to the code audit that preceded 0.2.0.

- Pre-flight: slug drift consumes `PF_DRIFT_SLUG_RE`, any initial by default (A2);
  newline-safe candidate and shared-tool matching, so two new migrations no longer
  collide with themselves (A4, A5); the doctor's output is parsed anchored, so a
  topic file named `FAILOVER-notes.md` no longer STOPs, and a real FAIL is quoted (A6);
  an unset dev variable is named, not reported as a shared lane (A12); paths with
  spaces, untracked directories and renames are judged whole (A18); an empty
  `PF_QUEUE_DIR` no longer globs the filesystem root (A16); `core.hooksPath` is
  compared as a path (B7); private scratch dirs with `mktemp -d` (B6); the P8
  candidate travels through `ENVIRON`, so a path with a backslash matches its rail.
- ownership-lint: a claim is live unless its last row is closed or abandoned, so a
  `restated` row no longer erases another developer's claim (A3); staleness comes
  from `PF_CLAIM_STALE_DAYS` (A19); a hand-typed session field is recognised or
  rejected by name (A13).
- Arbitration: the id pattern and the closure vocabulary come from the profile and
  are read by the pre-flight and the doctor alike (A1, A15); `PF_ARB_STOP_DAYS`
  is honoured, as an ambient warning (A17).
- rails-index: severity no longer depends on the awk flavour or the locale (A8); an
  unconfigured or edge-less graph cache is UNMEASURED, not "MEASURED" (A7); a rail
  truncated at `PF_RAILS_TRUNCATE` no longer ends inside a UTF-8 character.
- Doctor and catalog: no `find -printf`, `md5sum`, `grep -P` or `realpath -q` (B1-B4);
  a missing tool is UNMEASURED, never a passing line; dormancy flags only files older
  than `PM_DORMANT_DAYS` (A14); a missing memory dir is an error; `--grep` with no
  pattern is a usage error, not a hang (A11); every trigger line is harvested.
- Scripts started by another shell re-exec under bash (B5); a launcher that names no
  profile; an honest `--conf` message; usage errors on missing option values.
- The seed index no longer fails the doctor out of the box; the launcher no longer
  hardcodes a profile name.

### Removed

- The kernel no longer has the PM write out escalation text for overdue items:
  overdue items are named, and `${ESCALATION_POLICY}` says what follows. The profile
  variable `PF_ARB_ESCALATION` does not exist (policy is not duplicated in a script).
- "Repeat every rail hit verbatim" and "hold the lock" (no lock tool ships).
- 91 profile variables that no script read, and the French vocabulary and the
  origin project's nouns from every script.

## [0.1.0]
- Initial release: PROTOCOL kernel, doctor, catalog, load telemetry,
  pre-flight, rails index, ownership lint, example profile and skeleton.
