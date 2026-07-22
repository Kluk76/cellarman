# acme-pm — Project Manager Knowledge Base (LEAN INDEX)

> This is the PM's memory. It is a LEAN INDEX: current build-state, sequencing, RESUME POINT, and ONE-LINE load-triggered pointers to thematic files. Detail / completed-arc / any section over ~5 lines is COMPILED OUT into `acme-pm-memory/<topic>.md`, loaded ON DEMAND only when a task touches that topic. Keep this index small + current — date load-bearing facts; verify against the live system/repo before recording.

## 🔵 CHANGE-LOG HEAD (ALWAYS re-verify at build-start)
> **HEAD = <latest migration/change id>** (<date>, commit `<hash>`). NEVER trust a memorised next-free — re-verify against the live system AND pull first (multi-dev: a committed-but-unapplied change from the other dev also reserves its number).
> Full dated journal (every change + rationale, newest-first) → [journal.md](acme-pm-memory/journal.md) — load when you need the history of a specific change.

## 📍 CURRENT BUILD-STATE (one-glance)
- **Canonical store:** <where the truth lives; how to reach it read-only>.
- <one line per standing fact a consult must never contradict>

## ⏭ RESUME POINT
**<status>.** <what the project is waiting on; what dispatches when unblocked — one line each, pointer per item>

## 🟡 OPEN ACTIVE ARCS (status one-line; READ the topic file + recap unprompted when triggers fire)
- **<Arc name>** — <status word> (<date>). 🔴 <compressed rails>. Trigger "<word>"/"<word>" → [<topic>.md](acme-pm-memory/<topic>.md).

## 🟢 SHIPPED / CLOSED (one-line; full detail in the cited topic file)
- ✅ **<Arc name> — SHIPPED <date>** (<commit>). Trigger "<word>" → [<topic>.md](acme-pm-memory/<topic>.md) §Build log.

## 📂 THEMATIC FILES (load on demand)
- [<topic>.md](acme-pm-memory/<topic>.md) — read when touching <surface/domain>.

## MAINTENANCE NOTE
Keep THIS index lean — it is read WHOLE on EVERY PM invocation. **HARD BYTE BUDGET per `claude-brain/pm-kit.conf` — `claude-brain/pm-kit/doctor.sh` enforces it; run the doctor after recording and act on its warnings.** When a section grows past ~5 lines, a line past ~1.5 KB, or anything turns historical, COMPILE IT OUT into the relevant thematic file and leave a one-line load-triggered pointer. Dated journal entries go to journal.md (newest-first); dated arc narration goes to the arc topic file under `## Build log`. Rails are COMPRESSED, never dropped. The index is the map; the depth lives in the thematic files.
