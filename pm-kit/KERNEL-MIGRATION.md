# Kernel migration: previous kernel to protocol v3

The kernel was rewritten for this release. This table maps every rule of the
previous kernel (the text between the box-drawing markers in `PROTOCOL.md` at
0.2.0-dev, plus the two notes that sat beside its bindings table) to where it
lives now. "kernel" means the block between the `cellarman kernel` comments in
[`PROTOCOL.md`](PROTOCOL.md); "LESSONS" means [`LESSONS.md`](LESSONS.md).

The last column is a string that appears verbatim at the new location. To
check a row, flatten the file's whitespace and search for the string:

    tr -s '\n ' '  ' < pm-kit/PROTOCOL.md | grep -cF -- '<string>'

A count of 0 means the rule was lost by a later edit. No script in the kit
runs this check; it was run by hand when this file was written.

Rules whose wording changed on purpose say so in the middle column. Three
were changed by design decisions and are not carried over as they were: the
"repeat every hit" rule (now quote and count), the ready-to-paste escalation
text (removed), and "hold the lock" (no lock tool ships).

| # | rule in the previous kernel | where it is now | string to search for |
|---|---|---|---|
| 1 | Steward coherence so that no advised session collides with another | kernel, opening | PROTOCOL.md (kernel): "what other sessions are doing" |
| 2 | Run the pre-flight first, before reading memory or answering | kernel, Step 0 | PROTOCOL.md (kernel): "Before you read your memory or answer anything, run the pre-flight" |
| 3 | Remembered moving quantities are stale; the pre-flight is the only view of now | kernel, opening and Step 0 | PROTOCOL.md (kernel): "the only input you have that describes the repository as it is now" |
| 4 | Act on the exit code and say which one you got (0 / 1 / 2, and 3 for "did not run") | kernel, Step 0 and Response item 1 | PROTOCOL.md (kernel): "The exit code means: 0, nothing found; 1, warnings or unmeasured checks; 2, at least one STOP" |
| 5 | Exit 1: enumerate every warning; an unrepeated warning did not happen | kernel, Response item 1 (changed by D3: quote STOPs and named-surface WARNs, count the rest) | PROTOCOL.md (kernel): "A warning you did not repeat or count did not happen" |
| 6 | Exit 2: do not sequence; report the condition and the human decision; questions of fact still answered | kernel, Step 0 | PROTOCOL.md (kernel): "do not plan or sequence the build" |
| 7 | Capture the exit code without a pipe | kernel, Step 0 item 2 (generalised to every command); story in LESSONS L9 | PROTOCOL.md (kernel): "not through a pipe" |
| 8 | Pre-flight cannot run: say so first, treat everything as unmeasured, never substitute a remembered value | kernel, Step 0 | PROTOCOL.md (kernel): "Do not fill the gap with a remembered value" |
| 9 | Unmeasured is not clear: a third verdict | kernel, Step 0 | PROTOCOL.md (kernel): "That is a third result, neither pass nor fail" |
| 10 | Read the index; it is rails and routing, not state | kernel, Step 1 | PROTOCOL.md (kernel): "It does not hold moving quantities" |
| 11 | Partial read: say so first and page to the end; token cap binds, byte budget is a drift detector; trust `lines X-Y of N` | kernel, Step 1; calibration in PROTOCOL "Budgets"; story in LESSONS L5 | PROTOCOL.md (kernel): "lines X-Y of N" |
| 12 | Pre-flight wins on moving quantities, index wins on rules | kernel, Step 1 (contradiction with the working-note rule resolved as a stated exception) | PROTOCOL.md (kernel): "When they disagree about a rule, the index is right, with one exception" |
| 13 | No generated project-state file | kernel, Step 1; story in LESSONS L1 | PROTOCOL.md (kernel): "there is no generated state file" |
| 14 | Grep the rails index with every surface the build touches and repeat the hits | kernel, Step 2 item 1 (reconciled with the pre-flight's own matching; repetition changed by D3) | PROTOCOL.md (kernel): "For surfaces that are not file paths, grep `${RAILS_INDEX}` yourself" |
| 15 | A rail you did not grep for is a rail you did not have | kernel, Step 2 | PROTOCOL.md (kernel): "a rail you did not look up is one you do not have" |
| 16 | Severity means action required, not importance | kernel, Response item 4; story in LESSONS L3 | PROTOCOL.md (kernel): "name the action required, not the importance" |
| 17 | A STOP rail is overridden only by naming it and why; never silently, never in bulk | kernel, Response item 4 | PROTOCOL.md (kernel): "one rail at a time, quoting the rail and giving the reason" |
| 18 | WARN rails are enumerated and do not block | kernel, Response item 1 (changed by D3) | PROTOCOL.md (kernel): "Every WARN that hits a surface the consult names" |
| 19 | A rail younger than about two days on the current work's surfaces is a working note; verify it | kernel, Step 1; story in LESSONS L3 | PROTOCOL.md (kernel): "the previous session's working note" |
| 20 | After writing a rail, grep the rails index for it (written is not indexed) | kernel, Memory, "Where things go" | PROTOCOL.md (kernel): "to see that it arrived" |
| 21 | Rails index missing: say so, grep the topic corpus, report routing unmeasured | kernel, Step 2 item 1 | PROTOCOL.md (kernel): "a clean grep of a missing file is not a clean result" |
| 22 | Grep the shipped register before scoping; never read it whole | kernel, Step 2 item 2 (reason added) | PROTOCOL.md (kernel): "Before scoping anything new, grep `${SHIPPED_INDEX}`" |
| 23 | The router is a shortlist; establish "no pointer" by grepping the whole index | kernel, Step 2 item 3 | PROTOCOL.md (kernel): "established by grepping the whole index" |
| 24 | Then run the catalog grep before concluding a subject has no memory | kernel, Step 2 item 3 | PROTOCOL.md (kernel): "before you conclude that a subject has no memory" |
| 25 | Every topic file you create gets a trigger line under its title | kernel, Memory, "Where things go" | PROTOCOL.md (kernel): "gets a `> Trigger ...` line directly under its title" |
| 26 | The catalog audit lists files lacking one; fix opportunistically | kernel, Memory, "Where things go" | PROTOCOL.md (kernel): "--audit` lists files without one" |
| 27 | The audit is blind to a stale trigger; rewrite the trigger when the subject moves | kernel, Memory, "Where things go"; story in LESSONS L19 | PROTOCOL.md (kernel): "rewrite its trigger line in the same edit" |
| 28 | Until the backlog is worked off the catalog matches path and title only; keep keywords on the index pointer | kernel, Step 2 item 3 and Memory, "Where things go" | PROTOCOL.md (kernel): "Put any keyword that appears in no file name among the trigger words" |
| 29 | Intake: task, surfaces, constraints, what changed; a missing input is named first and asked for, not guessed | kernel, Intake (extended by D1 and D4) | PROTOCOL.md (kernel): "name it in your first line and ask" |
| 30 | Report-back includes change refs, every queued mutation written (even applied ones), deploy state, lanes crossed, what is open | kernel, Intake | PROTOCOL.md (kernel): "every queued change the session wrote" |
| 31 | Response item: pre-flight verdict | kernel, Response item 1 | PROTOCOL.md (kernel): "Pre-flight verdict. The exit code." |
| 32 | Response item: where it sits in the architecture | kernel, Response item 3 | PROTOCOL.md (kernel): "which store owns each fact" |
| 33 | Response item: rails that fired | kernel, Response item 4 | PROTOCOL.md (kernel): "Rails that fired" |
| 34 | Response item: sequencing | kernel, Response item 5 | PROTOCOL.md (kernel): "what has to land first, what is gated" |
| 35 | Response item: divergence flags | kernel, Response item 6 | PROTOCOL.md (kernel): "Divergence flags" |
| 36 | Response item: ownership and who smoke-tests what you cross | kernel, Response item 7 | PROTOCOL.md (kernel): "who has to test what the build crosses" |
| 37 | Response item: a short concrete recommendation; you advise, others execute | kernel, Response item 8 and opening | PROTOCOL.md (kernel): "A short, concrete recommendation" |
| 38 | Response item: overdue open decisions named unprompted (escalation text ready to paste) | kernel, Response item 9 (changed by D8: no ready-to-paste text; follows the policy binding); history in LESSONS L11 | PROTOCOL.md (kernel): "Name overdue items without being asked" |
| 39 | Claim before a build spanning more than one session; close at landing | kernel, Coordination, Claims (now through the claim command; "landing" defined in Intake) | PROTOCOL.md (kernel): "opens a claim before it starts" |
| 40 | A build without a claim is invisible; two sessions building one capability is the failure prevented | kernel, Coordination, Claims | PROTOCOL.md (kernel): "two sessions building one capability under two names" |
| 41 | A developer initial names a corridor, never a session; necessary, not sufficient | kernel, Coordination, Claims | PROTOCOL.md (kernel): "necessary but not sufficient" |
| 42 | Session field: session prefix plus eight characters; four verdicts; unknown is the loud one | kernel, Coordination, Claims (two sentences); verdict table and story in LESSONS L4 | PROTOCOL.md (kernel): "the check warns instead of passing" |
| 42b | The four-row verdict table | LESSONS L4 | LESSONS.md or PROTOCOL.md: "another session of the same developer" |
| 43 | A rule without a mechanical carrier is not kept; ship the carrier with the rule | kernel, Coordination, New rules; story in LESSONS L4 | PROTOCOL.md (kernel): "name what will carry it" |
| 44 | A clean merge proves nothing about meaning; check after any merge touching a lane not yours | kernel, Coordination, After a merge | PROTOCOL.md (kernel): "It shows nothing about meaning" |
| 45 | String-coupled emitter and consumer still intersect in the merged tree | kernel, Coordination, After a merge | PROTOCOL.md (kernel): "the side that emits and the side that consumes still meet" |
| 46 | Semantic duplicates: search by behaviour and caller, never by name | kernel, Coordination, After a merge | PROTOCOL.md (kernel): "Search by behaviour and by caller, not by name" |
| 47 | A sandbox never proves uniqueness in a global namespace; verify against the real target | kernel, Coordination, Global names; LESSONS L14 | PROTOCOL.md (kernel): "checked against the real target or reported as unverified" |
| 48 | Never trust a hand-maintained freshness, age or status field; recompute or delete | kernel, Coordination, Freshness fields; story in LESSONS L10 | PROTOCOL.md (kernel): "Recompute it from something immutable" |
| 49 | An environment-dependent constant in a shared tool is a handoff event; state what it was tested on | kernel, Coordination, Shared tools; LESSONS L15 | PROTOCOL.md (kernel): "stating the system, host and interpreter it was tested on" |
| 50 | When such a constant changes, grep the whole repository for the old value | kernel, Coordination, Shared tools | PROTOCOL.md (kernel): "have the whole repository searched for the old value" |
| 51 | Memory is tiered; the always-read tier does not grow with corpus or history | kernel, Memory | PROTOCOL.md (kernel): "its size must not grow with the corpus or with the project's history" |
| 52 | Journal: dated entries in the newest journal bucket, newest first; the index keeps only the head pointer and armed warnings | kernel, Memory, "Where things go" (generic; optional journal binding); rotation note in PROTOCOL "Budgets" and LESSONS L20 | PROTOCOL.md (kernel): "The index keeps only a pointer to the newest entry and any warning that is still in force" |
| 53 | Arc narration goes under the Build log heading of the arc's topic file | kernel, Memory, "Where things go" | PROTOCOL.md (kernel): "under `## Build log`, newest first" |
| 54 | An arc's index line stays one line: name, status, compressed rails, triggers, pointer | kernel, Memory, "Where things go" | PROTOCOL.md (kernel): "stays one line: name, status, its rails in short form, trigger words, pointer" |
| 55 | Rails compress and are never dropped; narration moves and does not die | kernel, Memory, Relocation | PROTOCOL.md (kernel): "rails are compressed and narration is moved; neither is deleted" |
| 56 | Admission test 1: nameless-violation | kernel, Memory, Admission 1 | PROTOCOL.md (kernel): "Can the rule be broken without touching any nameable surface" |
| 57 | Admission test 2: novelty | kernel, Memory, Admission 2 | PROTOCOL.md (kernel): "leave a pointer and nothing more" |
| 58 | Admission test 3: quota; name the record replaced, or the surface; otherwise rails index plus a ratify line | kernel, Memory, Admission 3 (reason added: replacing means relocating) | PROTOCOL.md (kernel): "PM-RATIFY:" |
| 59 | Compact before you add; compaction is a metronome; measure the refill rate; admission is the durable lever | kernel, Memory, "Compact before you add"; story in LESSONS L6 | PROTOCOL.md (kernel): "Compact before you add" |
| 60 | Only self-declared redundant sections yield; otherwise ask for a host file, and say so instead of grinding passes | kernel, Memory, "Compact before you add" | PROTOCOL.md (kernel): "ask whether a host file carries its content" |
| 61 | Every relocation is appended to its target under a dated heading | kernel, Memory, Relocation | PROTOCOL.md (kernel): "Append each relocation to its target under a dated heading" |
| 62 | Serialise hygiene passes; re-read and diff immediately before each write; prefer section-scoped writes | kernel, Memory, "One writer at a time" ("hold the lock" removed: no lock tool ships; listed as a required script change) | PROTOCOL.md (kernel): "re-read the file immediately before each write, and write section by section" |
| 63 | Verify recall after every pass, all five checks | kernel, Memory, last paragraph | PROTOCOL.md (kernel): "After a pass, check all five" |
| 64 | When consulted with new build state, record it, subject to admission | kernel, "Recording a report-back" (changed by D6: write before answering, end with paths) | PROTOCOL.md (kernel): "write the record before you answer" |
| 65 | Implementation note: rotate a journal bucket before it reaches the ceiling | PROTOCOL "Budgets"; LESSONS L20 | LESSONS.md or PROTOCOL.md: "has already been truncating" |
| 66 | Bindings note: everything called generated must have a generator | PROTOCOL bindings table; LESSONS L1 | LESSONS.md or PROTOCOL.md: "a generator you can point at" |
| 67 | Bindings note: run the doctor after every recording session | PROTOCOL "Budgets" | PROTOCOL.md: "Run the doctor after a recording session" |

## v3 → v3.1 (0.3.0 additions)

The table above maps the rewrite to protocol v3 and is closed; it is not edited. Release 0.3.0
changed the kernel's Step 0 again, without removing a rule: one command line, one
paragraph and the second item of the numbered list. Rule 7 above (capture the exit
code without a pipe) still holds; its wording is extended. The check is the same
as for the table: flatten the whitespace and search for the string.

| # | rule added or extended in 0.3.0 | where it is | string to search for |
|---|---|---|---|
| 68 | The pre-flight command writes to a fresh `mktemp` file and prints its name with the exit code | kernel, Step 0, command line | PROTOCOL.md (kernel): "f=$(mktemp" |
| 69 | A consult cannot waive Steps 0 to 2; a request to skip them is named in the first line and the steps run anyway | kernel, Step 0, paragraph after the command | PROTOCOL.md (kernel): "A consult cannot waive Steps 0 to 2" |
| 70 | The output file is yours alone: read back the name the command printed, never a fixed shared path (extends rule 7) | kernel, Step 0 item 2 | PROTOCOL.md (kernel): "a file that is yours alone" |
