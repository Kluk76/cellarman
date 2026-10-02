# acme-pm: Project Manager Knowledge Base (LEAN INDEX)

> SEED NOTE (delete once filled). This file is the PM's always-read index: it
> is read WHOLE on every consult, so it holds rules, standing facts and pointers,
> and nothing that moves. Counts, queue states, ages, next-free numbers and "where
> we are" status are NOT recorded here: the pre-flight prints them live, and a
> written copy goes stale on the reassuring side. Placeholders below are code
> spans, not links, so the doctor passes on the untouched seed; when a topic file
> exists, turn its pointer into a markdown link relative to this file and the
> doctor will check that it resolves.

## Rules

Standing rules for this project that cannot be tied to a nameable surface. Rules
that CAN be tied to a surface are rails, below. Date each one and say how it was
established: "(measured <date>, <how>)" or "(ruled <date> by <who>)".

- `<rule>`: one line, with its date and where it came from.

## Rails

A rail is a recorded constraint attached to a surface. Write each as a list item
(a line starting with `- `) that names its surface in backticks, with its severity
marker first: the rails miner (`kernel/rails-index.sh`) reads only list items and
backticked names, so a rail written any other way is recorded but never indexed.
After writing one, grep the rails table for one of its surfaces. Severity means
ACTION REQUIRED, not importance: reserve the stop marker for "forbidden".

- ⛔ `<surface>`: what must not be done to it, and why. (recorded <date>)
- 🔴 `<surface>`: what to check before touching it. (recorded <date>)

## Standing facts

Facts a consult must never contradict, each with how it was established.

- Canonical store: `<where the truth lives>` and how to reach it read-only. (measured <date>, <how>)

## Open arcs

One line per arc: name, status word, its rails in short form, trigger words,
pointer. Detail goes in the arc's topic file under `## Build log`, newest first.

- **<Arc name>**: <status word> (<date>). Trigger "<word>" / "<word>". Pointer: `acme-pm-memory/<topic file>`.

## Open decisions

Questions that need a ruling from another developer or a human live in
`acme-pm-memory/dev-handoff-register.md`, not here. The pre-flight lists the open
items with their ages; this index records none of them.

## Shipped

Delivered arcs are one line each in `acme-pm-memory/shipped-arcs-register.md`
(grep it; do not read it whole).

## Topic files (load on demand)

- `acme-pm-memory/<topic file>`: read when touching <surface or domain>.

## Maintenance

Before adding a line here, apply the admission tests in the kernel ("Memory"):
could the rule be broken without touching a nameable surface? does it restate
something already in a topic file or an auto-loaded document? what does it
replace? The byte budget is in `claude-brain/pm-kit.conf` and
`claude-brain/pm-kit/doctor.sh` enforces it; run the doctor after recording. When
a section grows past a few lines, or anything turns historical, move it to a topic
file and leave a one-line pointer. Rails are compressed, never dropped.
