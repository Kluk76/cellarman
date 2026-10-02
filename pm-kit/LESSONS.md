# Lessons

The kernel in [`PROTOCOL.md`](PROTOCOL.md) states each rule once, with its
reason, and nothing else. This file holds what was taken out of it: the
incidents behind the rules, the measurements, and the design notes that an
installer needs and a PM does not need on every consult.

Everything here was observed on the project this kit was extracted from (the
"origin project": two developers, each running several agent sessions, over
several months). Figures are that project's. They are evidence that a failure
happens, not thresholds to copy.

The PM does not read this file during a consult. Read it when you wonder why
a rule exists, or before you delete one.

## L1. Why there is no generated state file

An earlier kernel named a `<project>-pm-state.md` file and called it
"generated". Nothing generated it. The sentence sat in an auto-loaded
document, so every session read it and believed it, and no error was ever
raised until the origin project noticed it itself.

Two things follow. A false premise in an auto-loaded document is the most
expensive class of error, because it is re-read and re-believed on every
session. And the pre-flight already prints every moving quantity live, so a
state file could only be a copy that goes stale. If you want one anyway, first
answer what it would hold that the pre-flight cannot print.

The test that replaced the count: "everything called generated has a generator
you can point at". The earlier wording, "this is the only generated file", was
falsified by the edit that added a second generator.

## L2. A stale auto-loaded line is worse than a missing one

A missing rule makes a session ask. A stale rule makes it act. On the origin
project one false premise survived twenty days in four separate carriers,
because it happened to recommend the right action and so nothing ever went
wrong when people followed it. The kernel's question, "what would be different
if this were false", comes from that case.

Related: a document that is not auto-loaded ages without anyone noticing, and
a deletion should never be scoped from documentation alone. The documentation
says what was intended; the repository says what exists.

## L3. Rails: severity is an action, not a grade

When the origin's rails were first mined, 86% of the entries carried the
highest severity marker. Always red and always green produce the same
behaviour in the reader: overriding by reflex. So severity was redefined as
the action required, and a STOP rail may be set aside only one at a time, by
name, with a reason.

The two-day exception has its own incident. A pre-flight once presented the
PM's own notes from the previous night, two of them factually wrong, with the
same severity as long-standing prohibitions. A rail that recent, on the
surfaces of the work in progress, is a working note until someone checks it
against the code.

"Written" and "indexed" are different states. The miner reads list items and
backticked names only; a rail in a blockquote or a heading is in the index
file and absent from the rails index. Only a grep of the generated table
tells the two apart.

Quoting every hit does not scale. The origin's rails table reached about
21,000 rows, three quarters of them warnings. Repeating all of them produced
a wall that the orchestrator skimmed, which is why the kernel now quotes
STOPs and the warnings on the named surfaces, and counts the rest.

## L4. Claims and the session field

The claim rule was first a sentence: "name your session in the claim text".
After five days, 1 claim in 42 did (2.4%). What made it hold was a writer
(`claim.sh`, which refuses to open a claim without a session) and a
pre-commit gate that refuses a live row without the field. Hence the kernel's
rule about new rules: name the carrier, or say that the rule depends on
memory.

Before the session field existed, a matching developer initial printed "under
your open claim". Every session of a developer therefore got a pass on every
other session's claims of that developer. Measured on the live corpus: 32
open claims under one initial, all reported as "yours" to every session.

The ownership check answers in four ways:

| current session | claim's session field | result |
|---|---|---|
| unknown | any | warning: cannot tell whose claim it is |
| known | absent | warning: the initial alone does not establish it |
| known | same | yours |
| known | different | blocked: another session of the same developer |

The warning on "unknown" matters when a corpus of older rows without the
field is migrated: if unknown passed, the old false pass would be back on the
first day.

A claim row carries a developer initial, not a person's identity, and the
claims file is union-merged, so duplicates appear instead of conflicts. The
gate warns about duplicates and never removes them.

## L5. The index is truncated silently

An index that is too large does not fail to load. The read returns a
successful-looking partial view, and what is missing is the end of the file.
That is where the routing table and the register of shipped work usually
sit, so the PM advises without them and does not know.

The byte budget did not catch it. Token density depends on what the text is
made of: the origin's index, dense with markers and abbreviations, cost about
twice as many tokens per byte as plain prose, so the file was past the read
limit while still under its byte budget. The calibration method in
`PROTOCOL.md` ("Budgets") is the result: measure the wall on your own text
with the tool the PM uses, and set the budget under it.

The same happened to register files: two of them were being truncated
silently at about 204 KB. That is why the kernel says to grep the shipped
register and not read it.

## L6. Compaction does not hold, admission does

The origin's index was compacted from 158 KB to 45 KB over a month and then
sat within a few percent of its cap for six weeks, refilling at several
kilobytes a day. Each pass was used up within days. What holds the size is
the admission tests applied at write time.

One lever lowered the pressure instead of moving it: promoting a rule into a
document the project auto-loads. The rule then fails the novelty test and
leaves the index for good. Everything else relocates bytes from one
always-read place to another.

Compression has a cost that the byte count hides. Rails squeezed into marker
shorthand lose their condition and their reason; the model can match the
keyword and cannot judge whether the rail applies. And when every line is
bold and red, nothing ranks. Prefer a full sentence with its reason, or a
pointer.

Triage a pass by asking whether a section has a host file that already
carries its content, not whether it is verbose. Sections with no host file do
not move without a human ruling, and running small passes over them wastes
the session.

## L7. Relocate before you rewrite

Twice, a line was compressed first and "moved" second. What moved was the
paraphrase; the original was gone, and the result was shorter, coherent and
wrong. Conservation checks must grep for tokens from the source text, not
from the rewording.

A scripted line replace once removed five index lines unrecoverably. The edit tool fails visibly when its target
text has changed. A scripted replace does not.

Before a large pass, the origin snapshots the whole index into an archive
directory. Git also holds every version, so past a handful the snapshots are
duplication.

## L8. One writer at a time

An automatic memory sync committed whatever was on disk whenever any session
used git. With several sessions on one clone, it committed a neighbour's
half-written file as if it were finished, and produced hundreds of commits a
month. The fix was to scope the sync to the files the calling session wrote
(the session ledger) and to refuse a push when the branch carries anything
but memory commits.

The kernel asks for one hygiene pass at a time. No lock tool ships with the
kit; the rule currently depends on the PM re-reading before each write.

A consequence worth knowing: where an automatic pusher exists, a commit is
not a local act. Do not chain a push and a deploy in one command line on the
assumption that only your commits are going out.

## L9. Exit codes read through a pipe

`a | b` returns the status of `b`. Four times in ten days, across two
sessions and three commands, a result was misreported because of it: a
rejected push followed by a printed "pushed", and a failed rebase reported as
exit 0, which left the tree in an intermediate state that later steps treated
as clean. The rule in the kernel is general for that reason.

A second trap: one exit code over two checked locations. The code said that
something differed and did not say where; the lines above it did. Read the
verdict lines first.

## L10. Hand-maintained counts and ages

An arbitration register carried a hand-written "N days open" field. Of eleven
open items, nine had a stale age, eight of them past the escalation threshold
while reading "0 days". A hand count goes stale on the reassuring side. The
age is now computed from the date inside the item's identifier.

The same applies to anything written into memory: a count, a queue state or a
"next free number" is true on the day it is written and read as true
afterwards.

## L11. Closing an item

A register that marks closure with a word is read by a pattern, and an open
vocabulary read by equality gives false results in both directions: a
near-miss spelling closes an item silently, and a word outside the list
leaves it open indefinitely. The closure form belongs in the profile and in the register's own
header, anchored and checked. The kit's scripts still hard-code the origin's
closure words; see the README's limits.

Two human rules came from the same register, both recorded as lessons by the
origin project. The author of a question does not close it. And correcting a
false premise in a question is not answering it; re-read what was asked.

An earlier kernel had the PM write out the escalation text for overdue items,
ready to paste. The origin withdrew that by ruling. The kernel now names the
delay and defers to `${ESCALATION_POLICY}`, which each project sets.

## L12. Delegated work

A subagent's "pass" or "deployed" is a claim, and an agent that read a change
has not run it. A reader does not replace an executor.

Subagents inherit the permissions of the session that starts them. "Do not
push" in a prompt is advice. The only enforcement is checking what the agent
did after it returns.

Text produced by an agent is not a source either. A PM that records an
orchestrator's summary as fact serves it back later with the authority of
memory. Hence the provenance label on recorded facts.

## L13. Negative findings

"No caller", "never clicked", "not used anywhere" were recorded as facts and
outlived the code that made them true. A negative finding has no artefact to
contradict it when it goes stale. Date it, say how it was established, and
when it proves wrong, correct it where it was written.

Twice in one audit, a probe reported an absence that was really a failure of
the probe. Check that a probe can find a known positive before believing its
negative. The kernel's "unmeasured" is the general form.

## L14. Sandboxes and global names

A sandbox proves syntax and behaviour. The object a new name would collide
with is exactly what the sandbox left out, so anything that creates a name in
a shared namespace is checked against the real target.

## L15. Environment constants in shared tools

Host addresses, shell and operating-system assumptions, interpreter versions
and paths differ per machine, and the developer who wrote a shared tool is
usually the only one who has run it, so that machine becomes an unstated
assumption. Copies of such a value also live in onboarding documents and
shell snippets that no build touches.

## L16. A hook cannot detect its own absence

Git reads hooks only from the directory named by `core.hooksPath`. A clone
without that setting commits with no gate and no message. On the origin
project one developer's clone was found without the setting while the gates
sat in the repository. The
check therefore lives in the pre-flight, which runs whether or not the hooks
do. The same is true of the Claude Code hooks in this kit: nothing verifies
that `.claude/settings.json` wires them.

## L17. Detectors that always fire

A warning printed on every run stops being read. The pre-flight
kept one such warning for projects without a deploy target. Where a check has
nothing to measure it should say "not applicable" once and stay quiet.

## L18. Deploys that do not delete

A deploy that copies files without deleting leaves removed files alive on the
target, and a verification that compares only tracked files cannot see them
(measured: two deleted files stayed reachable after a clean deploy and a
clean verification).
The kit has a profile variable for this and no check that uses it.

## L19. The catalog and trigger lines

The catalog is regenerated on each call, so its file list is always current.
Its trigger lines are only as good as the files' own `> Trigger` lines. On
the origin project 44% of topic files had none after six weeks of "fix them
when you touch them", and for those files the catalog matches on path and
title only. A present trigger line that no longer describes its file is
worse: it routes away from the file, and the audit, which looks for absence,
cannot see it.

## L20. Journals

Routing and journaling are different jobs. On the origin project 44% of the
index was one section's dated journal. Moving dated entries into topic files
cut the index by more than half with nothing lost.

Projects that keep a journal directory should rotate to a new file before the
current one reaches the size the read tool returns whole. A file that has
reached the limit has already been truncating for days.
