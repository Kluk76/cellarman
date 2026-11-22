// workflow-lot.example.js - an OPT-IN example of a Claude Code Workflow script for one
// "lot" of work (a unit your PM agent has already planned). It is an example, not kit
// code: init.sh does not install it. To adopt it, copy it to .claude/workflows/lot.js
// and adjust the three things marked ADJUST below.
//
// The design it keeps, in order:
//   1. a triage grid over the plan (no file is read) -> solo | mutation | full
//   2. the graph is asked whether a file of the lot is "hot" (many dependents)
//   3. the build runs in an isolated git worktree and COMMITS NOTHING
//   4. a mutation verifier ALWAYS runs (unless triage said solo and nothing is hot):
//      a green test proves nothing until it has been seen to fail on the defect it guards
//   5. a second, read-only reviewer is added when triage says so, OR when a file of the
//      lot is hot in the graph, OR when the graph measured nothing (default = add it)
//   6. a synthesis re-checks every finding itself and STOPS before any commit
//
// ADJUST 1: KIT is where the kit is installed (init.sh puts it at claude-brain/pm-kit).
// ADJUST 2: PROFILE is your profile (init.sh writes claude-brain/pm-kit/profiles/<name>.conf).
// ADJUST 3: the build and verifier prompts say "the project's linters and pre-commit
//           hook"; name your real commands there if you want them run verbatim.
//
// This file is NOT executed by the kit's test suite; only its decision logic was
// checked by hand (see CHANGELOG 0.4.1). Treat the prompts as a starting point.
//
// args = { lot: 'short name', plan: '<the PM plan, pasted as is>', files?: ['src/a.ext', ...] }

export const meta = {
  name: 'lot',
  description: 'One planned lot: triage grid, build in an isolated worktree, mutation verifier, optional second reviewer, synthesis; stops before commit',
  whenToUse: 'A lot already planned by the PM agent (plan pasted in args.plan), claim taken. Useful when a mistake would be SILENT (access, derived data, a file loaded everywhere). Not for styling or a one-line fix.',
  phases: [
    { title: 'Triage', detail: 'five-question grid -> solo / mutation / full; then the graph measures whether a file of the lot is hot (second reviewer too)' },
    { title: 'Build', detail: 'isolated worktree, project linters and pre-commit hook, no commit', model: 'sonnet' },
    { title: 'Verify', detail: 'mutation always; one merged reviewer when risk or hot file' },
    { title: 'Synthesis', detail: 're-checked findings, verdict, what the builder missed' },
  ],
}

if (!args || !args.plan) throw new Error('args.plan is required (the PM plan, pasted as is)')
const LOT = args.lot || 'lot'
const PLAN = args.plan
const FILES = Array.isArray(args.files) && args.files.length ? args.files.join(' ') : '(see the plan)'

// ADJUST 1 and 2
const KIT = 'claude-brain/pm-kit'
const PROFILE = 'claude-brain/pm-kit/profiles/example.conf'

phase('Triage')
const triage = await agent(
  `Apply this grid to the plan below without reading any file. For each question answer yes/no plus one sentence taken from the plan.
Q1 does the lot touch 3 or more domains (storage, UI, access control, derived data, scheduled jobs)?
Q2 would a mistake be SILENT (a quiet permission denial, a silent downgrade, shifted ranking, wrong but self-consistent data, an error only at run time)?
Q3 can it be split into disjoint pieces with no imposed order?
Q4 does it sweep many files for few decisions?
Q5 does it touch production (migration, deploy, shared data)?
Decision: no yes among Q1-Q4 => "solo"; Q2 without Q1 or Q3 => "mutation"; (Q1 or Q3) and Q2 => "full"; Q1/Q3/Q4 without Q2 => "solo". Q5 only adds a human stop.

PLAN:
${PLAN}`,
  { label: 'triage', phase: 'Triage', effort: 'low', schema: {
    type: 'object',
    properties: {
      answers: { type: 'array', items: { type: 'object', properties: { q: { type: 'string' }, yes: { type: 'boolean' }, why: { type: 'string' } }, required: ['q', 'yes', 'why'] } },
      decision: { type: 'string', enum: ['solo', 'mutation', 'full'] },
    },
    required: ['answers', 'decision'],
  } })
log(`Triage: ${triage.decision}`)

// Pure decision: triage x graph measurement -> which verifiers run.
// When the graph measured nothing, the default is to ADD the reviewer.
//   solo + hot file      => no early return, mutation only
//   solo + unmeasured    => early return, as without a graph
//   mutation + cold      => mutation; mutation + hot / unmeasured / no graph => mutation + review
//   full                 => mutation + review
function reviewPlan(decision, graph) {
  const hot = !!(graph && graph.measured && Array.isArray(graph.hot_files) && graph.hot_files.length)
  const unmeasured = !graph || !graph.measured || (Array.isArray(graph.unmeasured) && graph.unmeasured.length > 0)
  if (decision === 'solo') return hot ? { early: false, keys: ['mutation'], hot, unmeasured } : { early: true, keys: [], hot, unmeasured }
  if (decision === 'full') return { early: false, keys: ['mutation', 'review'], hot, unmeasured }
  return { early: false, keys: (hot || unmeasured) ? ['mutation', 'review'] : ['mutation'], hot, unmeasured }
}

let graph = null
if (triage.decision !== 'full' && Array.isArray(args.files) && args.files.length) {
  graph = await agent(
    `Measure whether a file of the lot is among the most depended-on files of the repository. You read NO source file.
1. Read N from the profile with a plain grep: grep '^PF_GRAPH_HOT_RANK_N=' ${PROFILE} (a file is hot when it is in the top N by in-degree).
2. Ranking: bash ${KIT}/kernel/graph.sh rank --top N > f 2>&1; echo rc=$? (one "in-degree<TAB>path" line per file, most depended-on first; the rank is the line number). Add --kind K if your profile has several edge kinds and one is the meaningful one.
3. For EACH file of the lot: bash ${KIT}/kernel/graph.sh summary <file> > f 2>&1; echo rc=$?. Every exit code is read OUTSIDE a pipe.
   rc 0 = measured: hot if it appears in the ranking (give rank and in_degree), else cold. rc 2, 3, 4 or 5 = NOT measured (put it in unmeasured with the rc and why).
   Files no extractor reads (tests, generated code, files of a kind the profile has no extractor for) are NOT measured by definition: list them as unmeasured without calling the graph.
4. measured = true only if at least one file was measured (rc 0). If rank itself exits non-zero, measured = false.
Files of the lot (args.files): ${args.files.join(' ')}`,
    { label: 'graph', phase: 'Triage', effort: 'low', schema: {
      type: 'object',
      properties: {
        measured: { type: 'boolean' },
        hot_files: { type: 'array', items: { type: 'object', properties: { file: { type: 'string' }, rank: { type: 'integer' }, in_degree: { type: 'integer' } }, required: ['file', 'rank', 'in_degree'] } },
        unmeasured: { type: 'array', items: { type: 'object', properties: { file: { type: 'string' }, rc: { type: 'integer' }, why: { type: 'string' } }, required: ['file', 'rc', 'why'] } },
      },
      required: ['measured', 'hot_files', 'unmeasured'],
    } })
}
const plan = reviewPlan(triage.decision, graph)
log(`Graph: ${graph ? (graph.measured ? 'measured' : 'nothing measured') : 'not measured (no files, or the agent died)'}; hot=${graph && graph.hot_files ? graph.hot_files.length : 0}; unmeasured=${graph && graph.unmeasured ? graph.unmeasured.length : 'all'} => ${plan.early ? 'solo, no verifier' : 'verifiers: ' + plan.keys.join('+')}`)

phase('Build')
const build = await agent(
  `You build the lot ${LOT} in the isolated git worktree you run in (your current directory). Before editing, load any skill the plan names.

Hard constraints:
- You COMMIT nothing, push nothing, deploy nothing; no shared database or remote host is touched; a migration in the plan stays a draft and is not applied.
- You modify only the files of the plan: ${FILES}.
- Every exit code is read OUTSIDE a pipe: cmd > file 2>&1; echo "rc=$?", then read the file.
- Re-measure line numbers in YOUR worktree before editing.
- If the plan asks for a test: run it against the origin/main version first (git show origin/main:<file> into your scratch directory; copy the whole folder if the file has relative imports); it must FAIL where the defect exists. Then run it against your candidate; it must pass.
- AFTER your LAST edit, and not before: run the project's linters on every file you touched, stage the exact files (git add <files>, never a blanket add), then run the project's pre-commit hook and read its exit code. If you touch a file afterwards, run both again.

PLAN (authoritative):
${PLAN}

Report the absolute worktree path, the exact list of staged files (git diff --cached --name-only), the exact command of each test, the baseline/candidate exit codes, the linter and pre-commit exit codes (run after the last edit), and every deviation from the plan with its reason.`,
  { label: `build:${LOT}`, phase: 'Build', model: 'sonnet', isolation: 'worktree', schema: {
    type: 'object',
    properties: {
      worktree: { type: 'string' },
      staged: { type: 'array', items: { type: 'string' } },
      benches: { type: 'array', items: { type: 'object', properties: {
        cmd: { type: 'string' }, baseline_rc: { type: 'integer' }, candidate_rc: { type: 'integer' }, excerpt: { type: 'string' },
      }, required: ['cmd', 'baseline_rc', 'candidate_rc', 'excerpt'] } },
      lint_rc: { type: 'integer' },
      precommit_rc: { type: 'integer' },
      gates_after_last_edit: { type: 'boolean' },
      deviations: { type: 'array', items: { type: 'string' } },
    },
    required: ['worktree', 'staged', 'benches', 'lint_rc', 'precommit_rc', 'gates_after_last_edit', 'deviations'],
  } })
if (!build) return { triage, graph, build: null, error: 'build agent died - nothing to verify' }
log(`Build: ${build.worktree}; ${build.staged.length} file(s); pre-commit rc=${build.precommit_rc}; gates after last edit: ${build.gates_after_last_edit}`)

if (plan.early) {
  log('Triage solo: no verifier run - the orchestrator reads the diff itself')
  return { triage, graph, build, reviews: [], synthesis: null }
}

phase('Verify')
const FINDINGS = {
  type: 'object',
  properties: {
    checks_run: { type: 'array', items: { type: 'string' } },
    findings: { type: 'array', items: { type: 'object', properties: {
      severity: { type: 'string', enum: ['blocking', 'should-fix', 'nit'] },
      file: { type: 'string' }, line: { type: 'integer' },
      claim: { type: 'string' }, evidence: { type: 'string' },
    }, required: ['severity', 'file', 'claim', 'evidence'] } },
  },
  required: ['checks_run', 'findings'],
}
const COMMON = `You are an INDEPENDENT, READ-ONLY verifier of a lot built by another agent in the worktree ${build.worktree}. Always compare to origin/main. You modify no file of the worktree or of the main repository: copies and scripts go in your scratch directory. No access to shared databases or remote hosts. Exit codes are read outside pipes. Do not trust the builder's report; measure. A finding is a proof (command + output, or file:line). If everything holds, return no findings and the list of checks you ran.

Builder's report: ${JSON.stringify({ staged: build.staged, benches: build.benches, deviations: build.deviations })}

PLAN:
${PLAN}`

const VERIFIERS = [{ key: 'mutation', prompt: `${COMMON}

Angle: MUTATION. A green test proves nothing until it has seen the defect it guards go red.
1. Re-run each test yourself against origin/main and against the candidate; confirm the announced exit codes.
2. For EACH criterion of the plan and each behaviour rule of the added code, make in your scratch directory a MUTATED COPY of the candidate that violates that rule - first the original defect the lot fixes - and re-run the test on it. Aim for 4 to 8 targeted mutations, not noise.
3. Any mutation that leaves the test green is a finding (should-fix; blocking if it is the original defect), with the exact mutation (sed or diff) and the output.
4. Also read the test: tautologies, an empty set compared to an empty set, inclusion checked in one direction only, a missing function that is a fatal error instead of a failure.` }]

if (plan.keys.includes('review')) VERIFIERS.push({ key: 'review', prompt: `${COMMON}

Angle: merged REVIEW.
- Scope: git diff origin/main touches only the files and hunks of the plan; nothing out of scope.
- Identical behaviour where the plan requires it: write YOUR OWN small comparison script (not the builder's test) between origin/main and the candidate.
- Collisions: any new global name (function, constant, class) is defined once across the worktree.
- Safety: output is escaped, handlers keep their authorization and input checks, allow-lists are neither moved nor weakened.
- Data access, if any: parameters are bound once per statement, no silent truncation, aggregates are not cut by a LIMIT.` })

const reviews = (await parallel(VERIFIERS.map(v => () =>
  agent(v.prompt, { label: `verify:${v.key}`, phase: 'Verify', schema: FINDINGS })
    .then(r => r && ({ verifier: v.key, ...r }))
))).filter(Boolean)
const nFind = reviews.reduce((n, r) => n + r.findings.length, 0)
log(`Verification: ${reviews.length} report(s), ${nFind} finding(s)`)

phase('Synthesis')
const synthesis = await agent(
  `Synthesis of the lot ${LOT}, READ-ONLY (no edit, no commit).
Builder: ${JSON.stringify(build, null, 2)}
Verifiers: ${JSON.stringify(reviews, null, 2)}

De-duplicate. Re-verify YOURSELF each blocking / should-fix finding in ${build.worktree} (one command is enough): confirmed / refuted.
Return, short:
- verdict: ready to commit / needs fixes / reject;
- confirmed findings (file:line + proposed fix), then refuted ones in one line each;
- what the builder had missed (absent from its deviations) - that is the measure of what the workflow reported;
- if gates_after_last_edit is false, say so first.
End with this list for the orchestrator, unchanged:
1. read git diff origin/main in the worktree yourself;
2. apply the fixes, re-run tests, linters and the pre-commit hook AFTER the last edit;
3. commit the exact files in the worktree, rebase on origin/main, push (exit codes read outside pipes);
4. deploy or apply migrations only per the project's own procedure;
5. close the claim, then report back to the PM agent.`,
  { label: 'synthesis', phase: 'Synthesis' })

return { triage, graph, build, reviews, synthesis }
