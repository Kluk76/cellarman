# Dev handoff register

Open questions that need a ruling from the other developer (or a human outside
the team) before work can continue. This file is the ROUTER: one header line
per item. Long bodies belong in a `dev-handoff-register/` directory, one file
per item or month, so this file stays small enough to read whole.

Read by `kernel/pm-preflight.sh` (P6, path = `PF_ARB_FILE`) and `doctor.sh`.

## Format

Header, exactly:

    ### H-YYYYMMDD-<dev initial>-<slug> · <one-line question>

- The ID `H-YYYYMMDD-<initial>-<slug>` is immutable. **Age is recomputed from
  the date inside the ID.** Never write a hand-maintained "N days" field: it
  rots (measured on the origin project: 9 of 11 open items carried a stale
  age, eight of them past the escalation threshold while reading "0 days").
- An item is OPEN until its header carries a closure word glued to the
  separator, decoration only AFTER it: `· DONE`. The closure vocabulary is the
  profile variable `PF_ARB_CLOSED_RE` (default
  `CLOSED|DONE|RESOLVED|ANSWERED|OBSOLETE`), read by both `pm-preflight.sh` (P6)
  and `doctor.sh`: change it in the profile and both follow. The header pattern is
  `PF_ARB_HEADER_RE` (default `^### `) and the id pattern `PF_ARB_ID_RE` (default
  any lowercase initial). A header the kernel cannot read as closed is counted
  OPEN and flagged, never silently closed; a closure word written off-template
  (`· ✅ DONE`, or after a dash instead of the separator) is named in the
  pre-flight output.
- Close an item by editing its header AND, if it has a body, the body's header
  too: the doctor compares the two.
- Escalation (what happens past `PF_ARB_WARN_DAYS` / `PF_ARB_STOP_DAYS`) is a
  HUMAN act, and the policy is yours: write it in the agent file's
  `${ESCALATION_POLICY}` binding (the scripts carry no policy wording). Past the stop
  threshold the pre-flight reports the item as an ambient warning with its id, title,
  age and the threshold; the PM names overdue items in its recommendation and does
  not open the ticket or send the message itself.

## Template for a body

    ### H-YYYYMMDD-a-example-slug · Which of X or Y should the importer use?
    **Asked by:** a · **Ruling needed from:** b · **Blocks:** import rewrite
    **Context:** what you know, what you measured, with the date.
    **Options:** (1) ... (2) ...
    **Recommendation:** ...
    **Answer:** (filled in by the ruler, with the date)

## Open items

<!-- one header line per open item, newest first -->
