# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/) from 0.2.0 on.

## [Unreleased]

### Added
- `skeleton/pm-sync.example.sh`, rewritten:
  - detects untracked new memory files, not only tracked edits;
  - session-scoped: commits only the memory files this session wrote, per the
    ledger; `--all` is the explicit escape hatch; with no stdin, no jq or no
    ledger it commits nothing and says so (fail-closed);
  - steps aside when non-memory paths are staged (a commit sequence is in
    flight);
  - serialises on a lock in the git common dir: `flock` where available, a
    portable `mkdir` lock with stale-owner reclaim where it is not (macOS);
  - refuses to push when any commit ahead of the upstream touches a non-memory
    path, and says so on stderr; the push is an explicit
    `git push <remote> HEAD:<upstream-branch>`;
  - no remote or upstream: commits locally, skips the push, exits 0;
  - `PM_SYNC_MSG` overrides the commit message; memory paths come from
    `pm-kit.conf` (`PM_MEMORY_DIR`, `PM_INDEX`, optional `PM_SYNC_EXTRA_PATHS`).
- `pm-kit/kernel/session-ledger.sh`: the write side of session scoping (a
  PostToolUse hook on Write|Edit recording which session wrote which memory
  file under `<git-common-dir>/pm-ledger/`).
- `pm-kit/kernel/claim.sh`: the only writer of claim rows
  (`open|close|restate|abandon`), with a 7th `session` field built from the
  profile's session prefix and session environment variable, TAB/CR/LF
  sanitising, `--dry-run`, `--no-commit`, refusal without the dev variable (no
  fallback), and an opt-in `--push` that is refused when the branch carries
  other unpushed work.
- `pm-kit/kernel/profile-lib.sh`: shared repo-root and profile discovery for
  the new scripts (locates `<kit>/profiles/` from the script's own path).
- `pm-kit/lint-claims-session.sh` and `skeleton/githooks-pre-commit.example`:
  a pre-commit gate that refuses an added live row without a session field and
  any blank row, warns (never dedupes) on duplicate fields 1..4, plus `--dupes`
  and a `--self-test` that exercises both polarities.
- Templates under `skeleton/`: `OWNERSHIP.map.example`, `CLAIMS.tsv.example`
  (7-field format documented), `gitattributes.example` (`merge=union` for the
  claims file only, with the reason), `gitignore.example` (every derived or
  per-machine artefact named), `dev-handoff-register.example.md`.
- `tests/ports.sh`: behavioural suite for the above, run in sandbox repos with
  a bare remote.
- `.github/workflows/smoke.yml`: smoke and ports suites on ubuntu and macOS, a
  mawk + `LC_ALL=C` job, and a non-blocking shellcheck job.
- `profiles/example.conf`: section 16 documents every profile variable the new
  scripts read.
- `VERSION` (`0.2.0-dev`) and this changelog.

### Changed
- The pm-sync example no longer pushes a bare `git push`, and no longer
  sweeps the whole memory tree regardless of who wrote it.

## [0.1.0]
- Initial release: PROTOCOL kernel, doctor, catalog, load telemetry,
  pre-flight, rails index, ownership lint, example profile and skeleton.
