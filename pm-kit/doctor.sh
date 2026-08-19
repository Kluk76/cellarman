#!/usr/bin/env bash
# pm-kit/doctor.sh — health checks for a PM work-companion instance.
#
# The PM's memory discipline ("keep the index lean, compile out anything
# historical") is a written rule with no enforcement — this script IS the
# enforcement. Generic: zero project knowledge here; everything comes from a
# pm-kit.conf (default: ../pm-kit.conf next to this kit, or pass a path as the
# first non-flag argument).
#
# Usage:
#   doctor.sh [conf-path] [--strict]
#
# Default mode always exits 0 (safe to call from hooks). --strict exits 1 if
# any FAIL-level finding is present (index over hard budget, dangling links) —
# for manual runs and CI.
set -u

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$KIT_DIR/../.." && pwd)"

STRICT=0
CONF=""
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        *) CONF="$arg" ;;
    esac
done
CONF="${CONF:-$KIT_DIR/../pm-kit.conf}"

if [ ! -f "$CONF" ]; then
    echo "pm-doctor: FAIL — conf not found: $CONF"
    [ "$STRICT" = 1 ] && exit 1
    exit 0
fi
# shellcheck disable=SC1090
. "$CONF"

WARNINGS=0
FAILS=0
warn() { echo "pm-doctor: WARN — $*"; WARNINGS=$((WARNINGS+1)); }
fail() { echo "pm-doctor: FAIL — $*"; FAILS=$((FAILS+1)); }
ok()   { echo "pm-doctor: ok   — $*"; }

# ── 1. Index byte budget ─────────────────────────────────────────────────────
if [ ! -f "$PM_INDEX" ]; then
    fail "index missing: $PM_INDEX"
else
    SIZE=$(wc -c < "$PM_INDEX")
    if [ "$SIZE" -gt "$PM_BUDGET_FAIL" ]; then
        fail "index is ${SIZE} bytes (> hard budget ${PM_BUDGET_FAIL}) — you owe a compaction: compile narration out to topic-file Build logs"
    elif [ "$SIZE" -gt "$PM_BUDGET_WARN" ]; then
        warn "index is ${SIZE} bytes (> soft budget ${PM_BUDGET_WARN}) — compaction due soon"
    else
        ok "index ${SIZE} bytes (budget ${PM_BUDGET_WARN}/${PM_BUDGET_FAIL})"
    fi

    # ── 2. Oversized lines (narration masquerading as routing) ───────────────
    OVER=$(awk -v max="$PM_LINE_WARN" 'length($0)>max { printf "    line %d (%d bytes): %s...\n", NR, length($0), substr($0,1,60) }' "$PM_INDEX")
    if [ -n "$OVER" ]; then
        warn "index lines over ${PM_LINE_WARN} bytes (move narration to the topic file's Build log):"
        printf '%s\n' "$OVER"
    else
        ok "no index line over ${PM_LINE_WARN} bytes"
    fi

    # ── 3. Dated blockquotes accumulating in the index ───────────────────────
    DATED=$(grep -c '^> \*\*20[0-9][0-9]-' "$PM_INDEX" || true)
    if [ "${DATED:-0}" -gt "$PM_DATED_WARN" ]; then
        warn "index holds ${DATED} dated blockquote entries (> ${PM_DATED_WARN}) — journal entries belong in the journal/topic files"
    else
        ok "dated blockquotes in index: ${DATED:-0} (<= ${PM_DATED_WARN})"
    fi

    # ── 4. Dangling links index -> topic files ───────────────────────────────
    MEM_BASE="$(basename "$PM_MEMORY_DIR")"
    INDEX_DIR="$(dirname "$PM_INDEX")"
    DANGLING=""
    while IFS= read -r rel; do
        [ -e "$INDEX_DIR/$rel" ] || DANGLING="${DANGLING}    $rel"$'\n'
    done < <(grep -o "]("$MEM_BASE"/[^)]*)" "$PM_INDEX" | sed 's/^](//; s/)$//' | sed 's/#.*$//' | sort -u)
    if [ -n "$DANGLING" ]; then
        fail "index links to missing topic files:"
        printf '%s' "$DANGLING"
    else
        ok "all index topic-file links resolve"
    fi

    # ── 5. Orphan topic files (referenced nowhere) ───────────────────────────
    if [ -d "$PM_MEMORY_DIR" ]; then
        ORPHANS=""
        while IFS= read -r f; do
            base="$(basename "$f")"
            if ! grep -rql -- "$base" "$PM_INDEX" "$PM_MEMORY_DIR" --include='*.md' --exclude="$base" 2>/dev/null; then
                ORPHANS="${ORPHANS}    ${f#"$PM_MEMORY_DIR"/}"$'\n'
            fi
        done < <(find "$PM_MEMORY_DIR" -name '*.md' -type f)
        if [ -n "$ORPHANS" ]; then
            warn "topic files referenced neither by the index nor by any other topic file:"
            printf '%s' "$ORPHANS"
        else
            ok "no orphan topic files"
        fi
    fi
fi

# ── 6. Oversized topic files (a file doing a directory's job) ────────────────
# The index budget is blind to the corpus: a topic file can double the split
# threshold for weeks and no check says a word. Past that size a single file is
# a directory waiting to happen — split it and turn the old file into a small
# pointer index.
#
# The archive directory is EXCLUDED: a verbatim snapshot is meant to be one
# monolithic block — splitting it would destroy the thing it exists for. Its
# size is check 7's business, and letting check 6 shout about it buries the
# real signal under six lines of noise.
if [ -d "$PM_MEMORY_DIR" ]; then
    TOPIC_WARN="${PM_TOPIC_WARN:-81920}"
    BIG=$(find "$PM_MEMORY_DIR" \
              ${PM_ARCHIVE_DIR:+-path "$PM_ARCHIVE_DIR" -prune -o} \
              -name '*.md' -type f -printf '%s\t%P\n' 2>/dev/null \
          | awk -F'\t' -v max="$TOPIC_WARN" '$1 > max' \
          | sort -rn | head -10 \
          | awk -F'\t' '{ printf "    %4d KB  %s\n", $1/1024, $2 }')
    if [ -n "$BIG" ]; then
        warn "topic file(s) over $((TOPIC_WARN/1024)) KB — split into a directory + pointer index (largest first):"
        printf '%s\n' "$BIG"
    else
        ok "no topic file over $((TOPIC_WARN/1024)) KB"
    fi
fi

# ── 7. Archive retention (verbatim snapshots) ────────────────────────────────
# Pre-compaction snapshots are a safety net, not a store: git already holds
# every one of them (`git show <sha>:<index-path>`). They accumulate silently
# because nothing weighs them — check 1 measures the index alone, and check 5
# never calls them orphans since the archive README references them.
# Skipped entirely when PM_ARCHIVE_DIR is unset.
if [ -n "${PM_ARCHIVE_DIR:-}" ] && [ -d "$PM_ARCHIVE_DIR" ]; then
    ARCH_MAX="${PM_ARCHIVE_MAX:-3}"
    ARCH_GLOB="${PM_ARCHIVE_GLOB:-index-verbatim-*.md}"
    ARCH_N=$(find "$PM_ARCHIVE_DIR" -maxdepth 1 -name "$ARCH_GLOB" -type f 2>/dev/null | wc -l)
    ARCH_KB=$(find "$PM_ARCHIVE_DIR" -maxdepth 1 -name "$ARCH_GLOB" -type f -printf '%s\n' 2>/dev/null \
              | awk '{ s += $1 } END { printf "%d", (s+0)/1024 }')
    if [ "${ARCH_N:-0}" -gt "$ARCH_MAX" ]; then
        warn "${ARCH_N} archived snapshot(s) matching '${ARCH_GLOB}' (> ${ARCH_MAX}), ${ARCH_KB} KB — they are reconstructible with 'git show <sha>:<index>'; keep the newest ${ARCH_MAX} and replace the rest with a git-show line"
    else
        ok "archived snapshots: ${ARCH_N:-0} (<= ${ARCH_MAX}), ${ARCH_KB:-0} KB"
    fi
fi

# ── 8. Agent-definition copy drift ───────────────────────────────────────────
# 🔴 COMPARE AFTER PATH NORMALIZATION, never raw bytes.
# Some install flows rewrite absolute paths at copy time — e.g. a bootstrap
# script that rewrites the original author's $HOME/repo-root into the
# INSTALLING machine's own $HOME/repo-root. On any machine that is not the
# one the canonical copy was authored on, a raw md5 diverges BY CONSTRUCTION
# and this check could NEVER go green. Measured 2026-08-13 on dev B's
# machine: the installed definition was up to date, correctly rewritten by
# the installer, and the check still fired anyway — and ⭐ a detector that
# shouts every single run stops being read on the day it is right. So we
# apply the SAME rewrite the installer performs before comparing; a
# remaining difference is then a REAL copy lag.
#
# Entirely conf-driven and optional — with nothing set below this is a
# no-op passthrough (safe on a fresh install where no such rewrite ever
# happened, or where the checking machine IS the authoring machine):
#   PM_BOOTSTRAP_SOURCE_ROOT — the original repo root the installer rewrites
#                              FROM (e.g. /home/alice/projects/myapp).
#                              Unset = no root rewrite applied.
#   PM_BOOTSTRAP_SOURCE_HOME — the original $HOME the installer rewrites
#                              FROM. Unset = no $HOME rewrite applied.
#   PM_PATH_ALIASES          — colon-separated old=new path-fragment pairs
#                              for anything the two above cannot express —
#                              e.g. a historical project rename that left
#                              old path fragments baked into a canonical
#                              file ("/projects/oldname=/projects/newname").
#                              Unset = no aliasing applied.
_norm_agent_def() {
    local -a sed_args=()
    if [ -n "${PM_BOOTSTRAP_SOURCE_ROOT:-}" ]; then
        sed_args+=(-e "s|$(printf '%s' "$PM_BOOTSTRAP_SOURCE_ROOT" | tr '/' '-')|$(printf '%s' "$REPO_ROOT" | tr '/' '-')|g")
        sed_args+=(-e "s|${PM_BOOTSTRAP_SOURCE_ROOT}|${REPO_ROOT}|g")
        sed_args+=(-e "s|$(dirname "$PM_BOOTSTRAP_SOURCE_ROOT")|$(dirname "$REPO_ROOT")|g")
    fi
    if [ -n "${PM_BOOTSTRAP_SOURCE_HOME:-}" ]; then
        sed_args+=(-e "s|${PM_BOOTSTRAP_SOURCE_HOME}|${HOME}|g")
    fi
    if [ -n "${PM_PATH_ALIASES:-}" ]; then
        local pair old new
        IFS=':' read -ra _pairs <<< "$PM_PATH_ALIASES"
        for pair in "${_pairs[@]}"; do
            old="${pair%%=*}"; new="${pair#*=}"
            sed_args+=(-e "s|${old}|${new}|g")
        done
    fi
    if [ "${#sed_args[@]}" -eq 0 ]; then
        cat "$1"
    else
        sed "${sed_args[@]}" "$1"
    fi
}
if [ -f "$PM_AGENT_CANONICAL" ] && [ -f "$PM_AGENT_INSTALLED" ]; then
    if [ "$(_norm_agent_def "$PM_AGENT_CANONICAL" | md5sum)" != "$(md5sum < "$PM_AGENT_INSTALLED")" ]; then
        warn "agent definition drift: $PM_AGENT_INSTALLED != $PM_AGENT_CANONICAL (re-copy / re-run bootstrap)"
    else
        ok "agent definition copies in sync"
    fi
elif [ ! -f "$PM_AGENT_INSTALLED" ]; then
    warn "agent definition not installed at $PM_AGENT_INSTALLED"
fi

# ── 8b. Skill mirror drift ───────────────────────────────────────────────────
# Check 8 watches ONE file (the agent definition) and stopped there, so the
# skill store — dozens of files, mirrored by the same one-directional publish —
# drifted unwatched. Dev B's edits were overwritten TWICE on 2026-08-03 with no
# signal, because `publish.sh` copies live → mirror and never merges.
#
# 🔴 THE TELL IS DIRECTION, NOT DIFFERENCE. A mirror file that is merely
# different is usually just a publish that has not run yet — harmless. A mirror
# file NEWER than its live twin is work that exists only in the mirror, and the
# next publish deletes it. Those are the only ones worth waking someone for, so
# they are counted and named separately.
if [ -n "${PM_SKILLS_LIVE:-}" ] && [ -n "${PM_SKILLS_MIRROR:-}" ] \
   && [ -d "$PM_SKILLS_LIVE" ] && [ -d "$PM_SKILLS_MIRROR" ]; then
    SK_AT_RISK=""; SK_AT_RISK_N=0; SK_STALE_N=0; SK_ONLY_MIRROR=""
    while IFS= read -r M; do
        REL="${M#"$PM_SKILLS_MIRROR"/}"
        L="$PM_SKILLS_LIVE/$REL"
        if [ ! -f "$L" ]; then
            # In the mirror, absent from live: either a skill deleted upstream
            # (publish will not remove it) or content that only ever existed
            # here. Both are worth naming; neither is automatically a loss.
            SK_ONLY_MIRROR="$SK_ONLY_MIRROR $REL"
            continue
        fi
        [ "$(md5sum < "$M")" = "$(md5sum < "$L")" ] && continue
        if [ "$M" -nt "$L" ]; then
            SK_AT_RISK_N=$((SK_AT_RISK_N + 1))
            SK_AT_RISK="$SK_AT_RISK $REL"
        else
            SK_STALE_N=$((SK_STALE_N + 1))
        fi
    done <<EOF
$(find "$PM_SKILLS_MIRROR" -type f -name '*.md' 2>/dev/null)
EOF
    if [ "$SK_AT_RISK_N" -gt 0 ]; then
        warn "${SK_AT_RISK_N} MIRROR skill file(s) NEWER than the live copy — the next publish.sh DELETES these edits (copy them into $PM_SKILLS_LIVE first):$SK_AT_RISK"
    fi
    if [ -n "$SK_ONLY_MIRROR" ]; then
        warn "skill file(s) present in the mirror but absent from live — publish.sh never removes, so these are either deleted-upstream leftovers or mirror-only work:$SK_ONLY_MIRROR"
    fi
    if [ "$SK_AT_RISK_N" -eq 0 ] && [ -z "$SK_ONLY_MIRROR" ]; then
        ok "skill mirror: no mirror-only work at risk (${SK_STALE_N} file(s) merely awaiting a publish)"
    fi
fi

# ── 9. Multi-dev git sync state (memory paths) ───────────────────────────────
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    MEM_REL_INDEX="${PM_INDEX#"$REPO_ROOT"/}"
    MEM_REL_DIR="${PM_MEMORY_DIR#"$REPO_ROOT"/}"
    if git -C "$REPO_ROOT" rev-parse '@{u}' >/dev/null 2>&1; then
        AHEAD=$(git -C "$REPO_ROOT" rev-list --count '@{u}..HEAD' -- "$MEM_REL_INDEX" "$MEM_REL_DIR" 2>/dev/null || echo 0)
        BEHIND=$(git -C "$REPO_ROOT" rev-list --count 'HEAD..@{u}' -- "$MEM_REL_INDEX" "$MEM_REL_DIR" 2>/dev/null || echo 0)
        [ "${AHEAD:-0}" -gt 0 ] && warn "${AHEAD} memory commit(s) not pushed — pm-sync push may be stuck (pull, then push)"
        [ "${BEHIND:-0}" -gt 0 ] && warn "${BEHIND} memory commit(s) on upstream not pulled — another dev updated the brain: PULL BEFORE CONSULTING THE PM"
        # 🔴 SCOPE, stated in the message on purpose. This check pathspec-limits to the
        # two MEMORY paths. It is blind to db/migrations/, public/, app/ and bin/ — i.e.
        # to every surface where the two devs actually collide. Measured 2026-08-06: this
        # said "in sync" while six of origin/main's migrations were absent from disk, five
        # of them the other dev's. A green whose scope is not named IS a false green.
        # Repo-wide divergence + a real fetch belong to pm-preflight P1; this check is
        # deliberately NOT widened, so the two instruments cannot drift apart.
        [ "${AHEAD:-0}" = 0 ] && [ "${BEHIND:-0}" = 0 ] && ok "MEMORY paths in sync with upstream (code surfaces NOT checked here — run bin/pm-preflight.sh)"
    fi
    FETCH_HEAD="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || git -C "$REPO_ROOT" rev-parse --git-dir)/FETCH_HEAD"   # bare --git-dir is CWD-relative: wrong file when invoked from outside the repo
    if [ -f "$FETCH_HEAD" ]; then
        # `stat -c` is GNU-only: on BSD/macOS it prints "illegal option -- c" and
        # SUBSTITUTES NOTHING, so the arithmetic became `( 1785343838 - ) / 3600`
        # — a shell syntax error the script printed and then walked past, still
        # reporting "0 fail(s)". Measured on dev B's Mac 2026-07-29: this check
        # had never run there, while the PM index sat at 86 049 B.
        # ⇒ A check that prints its own failure and still returns green is worse
        #   than an absent check: the absent one is visibly absent.
        # `stat -f %m` is the BSD spelling; try GNU first, fall back, and if
        # NEITHER works say UNMEASURED rather than inventing an age.
        MTIME="$(stat -c %Y "$FETCH_HEAD" 2>/dev/null || stat -f %m "$FETCH_HEAD" 2>/dev/null || echo '')"
        case "$MTIME" in
            ''|*[!0-9]*)
                warn "cannot read the mtime of FETCH_HEAD on this platform — fetch age UNMEASURED (neither 'stat -c' nor 'stat -f' worked)" ;;
            *)
                AGE_H=$(( ( $(date +%s) - MTIME ) / 3600 ))
                [ "$AGE_H" -gt 24 ] && warn "last git fetch was ${AGE_H}h ago — brain freshness unknown (git pull)" ;;
        esac
    else
        warn "never fetched from remote — brain freshness unknown (git pull)"
    fi

    # ── 9b. Uncommitted memory edits, right now ──────────────────────────────
    # Check 9 compares COMMITTED state to upstream — it is blind to a
    # concurrent session editing the memory tree in the shared worktree. That
    # blindness nearly cost a compaction pass: a draft built from a 20-minute-
    # old read would have overwritten another session's fresher measurements,
    # a regression wearing the costume of tidying.
    # Informational by design: pm-sync commits on a cron, so a dirty memory
    # tree right after a recording is NORMAL and must not raise a warning.
    # The value is the LIST — if you did not touch one of these files, someone
    # else is writing, and you diff before you rewrite.
    DIRTY=$(git -C "$REPO_ROOT" status --porcelain -- "$MEM_REL_INDEX" "$MEM_REL_DIR" 2>/dev/null \
            | awk '{ $1=$1; print }' | cut -d' ' -f2- | head -10)
    if [ -n "$DIRTY" ]; then
        DIRTY_N=$(git -C "$REPO_ROOT" status --porcelain -- "$MEM_REL_INDEX" "$MEM_REL_DIR" 2>/dev/null | wc -l)
        ok "${DIRTY_N} uncommitted memory path(s) — diff before rewriting any you did not touch:"
        printf '%s\n' "$DIRTY" | sed 's/^/    /'
    else
        ok "memory tree clean (no uncommitted edits)"
    fi
fi

# ── 10. Dormant topic files (telemetry-backed) ───────────────────────────────
if [ -f "${PM_LOAD_LOG:-/nonexistent}" ] && [ -d "$PM_MEMORY_DIR" ]; then
    CUTOFF=$(date -d "-${PM_DORMANT_DAYS} days" +%F 2>/dev/null || date -v -"${PM_DORMANT_DAYS}"d +%F)
    RECENT=$(awk -F'\t' -v c="$CUTOFF" '$1 >= c { print $2 }' "$PM_LOAD_LOG" | sort -u)
    DORMANT=0
    DORMANT_LIST=""
    while IFS= read -r f; do
        rel="${f#"$PM_MEMORY_DIR"/}"
        if ! printf '%s\n' "$RECENT" | grep -qx -- "$rel"; then
            DORMANT=$((DORMANT+1))
            [ "$DORMANT" -le 10 ] && DORMANT_LIST="${DORMANT_LIST}    ${rel}"$'\n'
        fi
    done < <(find "$PM_MEMORY_DIR" -name '*.md' -type f)
    if [ "$DORMANT" -gt 0 ]; then
        warn "${DORMANT} topic file(s) with zero recorded loads in ${PM_DORMANT_DAYS} days (dead pointer or mis-matched trigger — first 10):"
        printf '%s' "$DORMANT_LIST"
    fi
else
    ok "no load telemetry yet (dormancy check skipped)"
fi

# ── 11. Dead relative links INSIDE the corpus (topic → topic) ────────────────
# Check 4 walks index → topic: the graph the index owns. This walks the OTHER
# half — topic → topic — which nothing watched, so a file citing one that was
# renamed or relocated kept a dead link forever while the doctor reported
# all-clear. Found the hard way on 2026-07-29 (three pruned snapshots, index
# clean, two dead links inside an unrelated arc file).
#
# WARN-only, and deliberately so: this surfaces a large PRE-EXISTING debt
# (relocation leaves the text moved and the paths behind). A FAIL tier would
# break --strict on day one and the check would be switched off, which is worse
# than the debt. The archive directory is excluded — a verbatim snapshot is
# frozen by definition, so its stale paths are historical facts, not defects.
if [ -d "$PM_MEMORY_DIR" ]; then
    DEAD_N=0
    DEAD_LIST=""
    # 🔑 SNAPSHOTS VERBATIM — comptés À PART, jamais en défaut (ruling dev B,
    # 2026-08-13 : « garde les photocopies fidèles »). Un snapshot est une copie
    # mot-à-mot d'un index d'origine ; ses liens ont été écrits depuis
    # `claude-brain/agents/` et ne seront JAMAIS réécrits — les réécrire
    # détruirait la seule chose qui fait sa valeur. Chacun porte en tête une CLÉ
    # DE RÉSOLUTION (`<!-- CLE-RESOLUTION-LIENS -->`) qui donne le préfixe à
    # appliquer. Les compter en défaut faisait 734 alertes permanentes, et
    # ⭐ un détecteur qui crie à chaque passage cesse d'être lu le jour où il a
    # raison. Le fichier n'est reconnu comme snapshot que s'il PORTE la clé :
    # un nom qui y ressemble sans clé reste contrôlé normalement.
    SNAP_N=0
    ABS_N=0
    ABS_LIST=""
    while IFS= read -r f; do
        FDIR="$(dirname "$f")"
        IS_SNAP=0
        grep -q 'CLE-RESOLUTION-LIENS' "$f" 2>/dev/null && IS_SNAP=1
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            case "$p" in http*|mailto:*|'<'*) continue ;; esac
            # Un chemin ABSOLU n'est pas un lien relatif — le compter ici
            # produisait une alerte permanente et FAUSSE de nom. Ceux qu'on
            # trouve visent la mémoire auto-recall PERSONNELLE d'un dev
            # (/home/<dev>/.claude/projects/…) : par construction elle n'existe
            # pas sur la machine de l'autre, et rien dans ce dépôt ne peut la
            # réparer. Compté à part, dit une fois, jamais en défaut.
            case "$p" in
                /*) if [ ! -e "$p" ]; then
                        ABS_N=$((ABS_N+1))
                        [ "$ABS_N" -le 3 ] && ABS_LIST="${ABS_LIST}    ${f#"$PM_MEMORY_DIR"/} → ${p}"$'\n'
                    fi
                    continue ;;
            esac
            [ -e "$FDIR/$p" ] && continue
            if [ "$IS_SNAP" = 1 ]; then
                SNAP_N=$((SNAP_N+1))
                continue
            fi
            DEAD_N=$((DEAD_N+1))
            [ "$DEAD_N" -le 10 ] && DEAD_LIST="${DEAD_LIST}    ${f#"$PM_MEMORY_DIR"/} → ${p}"$'\n'
        done < <(grep -o ']([^)]*)' "$f" 2>/dev/null \
                 | sed 's/^](//; s/)$//; s/#.*$//' | grep '\.md$')
    done < <(find "$PM_MEMORY_DIR" \
                 ${PM_ARCHIVE_DIR:+-path "$PM_ARCHIVE_DIR" -prune -o} \
                 -name '*.md' -type f -print)
    if [ "$DEAD_N" -gt 0 ]; then
        warn "${DEAD_N} dead relative link(s) between topic files (invisible to check 4 — it only walks index → topic; first 10):"
        printf '%s' "$DEAD_LIST"
    else
        ok "no dead relative link between topic files"
    fi
    if [ "$SNAP_N" -gt 0 ]; then
        ok "snapshots verbatim: ${SNAP_N} lien(s) index-relatifs, NON comptés en défaut (clé de résolution en tête de chaque fichier)"
    fi
    if [ "$ABS_N" -gt 0 ]; then
        ok "${ABS_N} lien(s) en chemin ABSOLU vers la mémoire personnelle d'un dev — irréparables depuis ce dépôt, jamais en défaut :"
        printf '%s' "$ABS_LIST"
    fi
fi

# ── 12. Routeur ⇄ corps : comparer l'ÉTAT, pas seulement la PRÉSENCE ─────────
# P6 de pm-preflight lit UN SEUL fichier (`PF_ARB_FILE`, le routeur) et n'y parse
# que les lignes `### H-20…`. Depuis la découpe du 2026-08-13 les corps vivent
# dans `dev-handoff-register/` et le routeur ne garde que les EN-TÊTES. Ce qui
# rend ça sûr n'est donc pas UN invariant mais DEUX : tout item a son en-tête des
# deux côtés, ET les deux en-têtes portent le MÊME état.
#
# 🔴 CE BLOC A ÉTÉ ÉLARGI LE 2026-08-18 (arbitrage dev A, option (d) d'un
# arbitrage de passation portant sur un gate partiel lisant une clôture
# ornée, demandé par dev B).
# La version d'avant ne comparait que des ENSEMBLES D'OUVERTS et ne rendait qu'un
# `comm -13` — « présent dans un corps, absent du routeur ». Mesuré au banc, elle
# avait trois défauts, et deux avaient déjà coûté :
#   ① AVEUGLE à « routeur OUVERT / corps RÉPONDU » — la réponse est écrite au bon
#     endroit, dans le bon vocabulaire, et l'item continue de VIEILLIR quand même,
#     jusqu'à pousser vers une escalade automatisée (mail réel, écriture prod)
#     d'une question déjà tranchée. Deux cas le 18-08 : 8 j et 11 j d'âge FANTÔME ;
#   ② le sens inverse (routeur CLOS / corps OUVERT) était bien signalé mais avec
#     un diagnostic FAUX — « absent du routeur » alors qu'il y EST : le lecteur
#     part chercher un en-tête manquant qui existe. Ce sens-là est le plus grave
#     des deux : une question RÉELLEMENT ouverte cesse d'être comptée ;
#   ③ AVEUGLE à l'en-tête de routeur SANS corps (tout le contenu tient dans la
#     ligne du routeur). P6 le voit, donc rien ne ment — mais l'item n'a nulle
#     part où recevoir une réponse.
# ⭐⭐ LE RAIL : une garde qui vérifie la PRÉSENCE d'une clé ne dit RIEN de sa
# VALEUR — et ici c'est la valeur qui pilote l'escalade. Le mode de panne d'un
# gate qui lit une population partielle n'est pas une alerte manquante, c'est une
# alerte RASSURANTE sur la mauvaise population.
#
# ⛔ Un corps CLOS sans en-tête au routeur est SILENCIEUX et doit le rester :
# c'est l'état NORMAL de tout item archivé dans `clos-YYYY-MM.md`, dont l'en-tête
# a été retiré du routeur. Faire crier là-dessus rendrait la garde inutilisable
# le jour où elle sert.
HR="$PM_MEMORY_DIR/dev-handoff-register.md"
HD="$PM_MEMORY_DIR/dev-handoff-register"
if [ -f "$HR" ] && [ -d "$HD" ]; then
    # Un seul passage awk : le routeur d'abord, les corps ensuite, départagés par
    # FILENAME (⛔ pas par ARGIND, qui est une extension gawk et rendrait la
    # garde muette sous mawk — le cas exact contre lequel elle existe).
    _RC="$(awk -v RFILE="$HR" '
      /^### H-20/ {
        if (!match($0, /H-[0-9]{8}-[a-z]-[a-z0-9-]+/)) next
        id = substr($0, RSTART, RLENGTH)
        st = ($0 ~ /· *(CLOS|RÉPONDU|CADUQUE)/) ? "clos" : "ouvert"
        # ⛔ MÊME VOCABULAIRE que P6 (pm-preflight.sh) et que les règles du
        # routeur — 3 sites, à modifier ensemble. Ici on couvre ce que P6 ne
        # peut PAS voir : les en-têtes des CORPS.
        # ⚠️ Aucune apostrophe ASCII dans ce bloc : quotes simples de shell.
        if (st == "ouvert") {
          if ($0 ~ /· *[^A-Za-z0-9]* *(CLOS|RÉPONDU|CADUQUE)/) f[id]="HORS-GABARIT"
          else if ($0 ~ /(CLOS|RÉPONDU|CADUQUE)/)              f[id]="SUSPECT"
        }
        if (FILENAME == RFILE) {
          if (id in r && r[id] != st) r[id] = "CONFLIT-INTERNE"; else r[id] = st
        } else {
          if (id in b && b[id] != st) b[id] = "CONFLIT-INTERNE"; else b[id] = st
        }
      }
      END {
        for (id in r) {
          if (!(id in b))      { print "ROUTEUR-SANS-CORPS\t" id "\t" r[id]; continue }
          if (r[id] != b[id])    print "DIVERGENT\t" id "\trouteur=" r[id] "\tcorps=" b[id]
        }
        for (id in b) if (!(id in r) && b[id] == "ouvert") print "CORPS-SANS-ROUTEUR\t" id "\t" b[id]
        for (id in f) print "HORS-VOCABULAIRE\t" id "\t" f[id] | "sort"
      }' "$HR" "$HD"/*.md 2>/dev/null)"

    _DIV="$(printf '%s\n' "$_RC" | grep '^DIVERGENT' || true)"
    _CSR="$(printf '%s\n' "$_RC" | grep '^CORPS-SANS-ROUTEUR' || true)"
    _RSC="$(printf '%s\n' "$_RC" | grep '^ROUTEUR-SANS-CORPS' || true)"
    _FMT="$(printf '%s\n' "$_RC" | grep '^HORS-VOCABULAIRE' || true)"
    N_ROUTEUR=$(grep -c '^### H-20' "$HR" 2>/dev/null || echo 0)

    if [ -n "$_DIV" ]; then
        fail "routeur ⇄ corps : ÉTATS DIVERGENTS — P6 ne lit QUE le routeur, donc l'âge et l'escalade suivent la colonne de GAUCHE :"
        printf '%s\n' "$_DIV" | sed 's/^DIVERGENT\t/    /' | sed 's/\t/  /g'
    fi
    if [ -n "$_CSR" ]; then
        fail "arbitrages ouverts INVISIBLES au pré-vol (dans un corps, AUCUN en-tête au routeur) :"
        printf '%s\n' "$_CSR" | sed 's/^CORPS-SANS-ROUTEUR\t/    /' | sed 's/\t.*//'
    fi
    if [ -n "$_RSC" ]; then
        warn "en-tête(s) de routeur SANS corps — visibles de P6, mais sans endroit où recevoir une réponse :"
        printf '%s\n' "$_RSC" | sed 's/^ROUTEUR-SANS-CORPS\t/    /' | sed 's/\t.*//'
    fi
    if [ -n "$_FMT" ]; then
        warn "en-tête(s) HORS VOCABULAIRE de clôture — comptés OUVERTS faute d'être lus (« · CLOS » / « · RÉPONDU » / « · CADUQUE », le mot COLLÉ au « · », ornement APRÈS) :"
        printf '%s\n' "$_FMT" | sed 's/^HORS-VOCABULAIRE\t/    /' | sed 's/\t/  /g'
    fi
    [ -z "$_DIV$_CSR$_RSC$_FMT" ] && ok "routeur ⇄ corps: ${N_ROUTEUR} en-tête(s), états concordants des deux côtés"
fi

echo "pm-doctor: ${FAILS} fail(s), ${WARNINGS} warning(s)"
if [ "$STRICT" = 1 ] && [ "$FAILS" -gt 0 ]; then exit 1; fi
exit 0
