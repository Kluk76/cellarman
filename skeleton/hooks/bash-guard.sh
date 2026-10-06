#!/usr/bin/env bash
# bash-guard.sh -- PreToolUse(Bash) hook (cellarman skeleton; install as .claude/hooks/bash-guard.sh
# with bash-guard.cases beside it). Reads the hook JSON on stdin
# (.tool_input.command = the shell command an agent is about to run) and
# refuses or warns on a small set of dangerous command shapes.
#
# WHAT IT DOES NOT STOP (read this before trusting it):
#   * a command that lives inside a script file which is then executed
#     (`bash run.sh`, `./deploy-wrapper`, `make x`): only the command line is seen;
#   * `eval "$var"`, `bash -c "$var"`, anything whose text only exists at run time;
#   * shell aliases, shell functions, `git` aliases, GIT_CONFIG_* environment
#     variables, a different binary named like a wrapper;
#   * data piped into a shell (`echo 'git commit -n' | sh`);
#   * a human typing in a terminal: the hook only sits on the agent's Bash tool.
#   It is a guard for the agent tool channel that catches honest mistakes and
#   habits. It is NOT a security boundary.
#
# Contract
#   BLOCK  : short reason on stderr naming the rule id + the alternative, exit 2.
#   WARN   : {"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}
#            on stdout, exit 0.
#   nothing matched / empty command : exit 0, no output.
#   jq missing or stdin not parseable : "bash-guard INACTIVE: <why>" on stderr,
#            exit 1 (fails open, visibly).
#   command cannot be tokenised (unbalanced quote/paren): never blocks; a WARN
#            says it could not be analysed.
#   several rules : block wins; every matched rule id is reported.
#
# Configuration (environment, read at each run; unset = the default):
#   BASH_GUARD_HOOKS_PATH      the hooks directory R1b/R1c expect, default .githooks
#   BASH_GUARD_EXITCODE_CMDS   the R4/R5 command list above
#   BASH_GUARD_CASES           the cases file --self-test reads (default: bash-guard.cases
#                              beside this script)
# --self-test runs the cases file under the DEFAULTS, then checks the two overrides.
#
# Modes: edit ONE line of the table below to flip a rule between block and warn
# (a third value, off, silences it).
#
# Rules
#   R1  no-verify   git commit --no-verify / short cluster containing n (-n -nm -an),
#                   git push --no-verify.  (git push -n is --dry-run: allowed.)
#   R1b hooksPath   git -c core.hooksPath=<v> (any subcommand) unless <v> is exactly the
#                   expected hooks directory (default .githooks, or ./ before it; per-command
#                   arming is allowed); git config [..] core.hooksPath <other value>,
#                   --unset, --unset-all. Reads (--get, bare key) are allowed.
#   R1c hooksPath   git config [..] core.hooksPath <expected> (persistent arming: applies
#       persistent  to EVERY worktree of the shared clone, so it is announced) -- warn.
#   R2  blanket add git add -A | --all | bare `.`   (git add -u alone is allowed)
#   R4  pipe rc     an exit-code command in a NON-last pipeline stage: the pipeline returns
#                   the status of its last command. The commands come from
#                   BASH_GUARD_EXITCODE_CMDS (comma separated; "git <subcommand>" for a git
#                   subcommand, otherwise the command's or script's base name), default
#                   "git push,git pull,git rebase,git merge"; pm-preflight.sh is always added.
#   R5  echo claim  `&& echo|printf` right after a pipeline that contains an R4 trigger
#                   in a non-last stage (the echo claims a result nobody measured).
#                   Reported instead of R4 for that pipeline. A plain
#                   `a | grep x && echo "=== y ==="` matches nothing.
#
# Beyond the brief (small extensions, all parse-level): `ssh host '<cmd>'`
# and `eval '<literal>'` payloads are scanned like `bash -c`.
#
# Parsing: one awk program tokenises the command character by character
# (quotes, $'..', heredoc bodies, comments, $( ), backticks, ( ) and { } groups,
# bash -c payloads) and applies the rules to the resulting commands/pipelines.
# Portable on purpose: bash 3.2 + BSD awk + gawk/mawk (no associative arrays,
# no mapfile, no ${x,,}, no gawk-only functions). Self-test: --self-test.

# ---------------------------------------------------------------- MODE TABLE
# shellcheck disable=SC2034  # read indirectly by mode_of()
MODE_R1=block
MODE_R1b=block
MODE_R1c=warn
MODE_R2=block
MODE_R4=warn
MODE_R5=block
# ---------------------------------------------------------------------------

RULES="R1 R1b R1c R2 R4 R5"

HP="${BASH_GUARD_HOOKS_PATH:-.githooks}"
HP="${HP#./}"
EXC="${BASH_GUARD_EXITCODE_CMDS:-git push,git pull,git rebase,git merge},pm-preflight.sh"
EXC="$(printf '%s' "$EXC" | sed 's/ *, */,/g; s/^ *//; s/ *$//')"
SELF="${BASH_SOURCE[0]}"

rule_msg() {
  case "$1" in
    R1)  echo "R1 no-verify: --no-verify / -n on git commit (or --no-verify on git push) skips the pre-commit gates. Fix what the hook reports and commit again; a bypass is the operator's call, never the agent's." ;;
    R1b) echo "R1b hooksPath: setting core.hooksPath to anything but $HP, or unsetting it, disarms the pre-commit gates. Allowed: git -c core.hooksPath=$HP <subcommand>, reads (git config --get core.hooksPath)." ;;
    R1c) echo "R1c hooksPath persistent: git config core.hooksPath $HP is an operator gesture: it applies to EVERY worktree of the shared clone and must be announced. For one command prefer: git -c core.hooksPath=$HP <subcommand>." ;;
    R2)  echo "R2 blanket add: git add -A / --all / . sweeps unrelated work from the shared tree into the commit. Name the files: git add <path> [<path>...], then git diff --cached --name-only." ;;
    R4)  echo "R4 exit code through a pipe: a pipeline returns the status of its LAST command, so the status of an exit-code command ($EXC) is lost. Use: cmd > file 2>&1; rc=\$?  then read the file." ;;
    R5)  echo "R5 success message on a piped command: '&& echo/printf' after a pipeline in which an exit-code command ($EXC) is not the last stage asserts something nobody measured (the pipeline returns the last stage's status). Run: cmd > file 2>&1; rc=\$?  read the file, and print what was measured." ;;
  esac
}

# --------------------------------------------------------------- AWK PROGRAM
read -r -d '' AWK_PROG <<'AWKEOF'
function addhit(r) {
  if (index("," HITS ",", "," r ",") == 0) { if (HITS != "") HITS = HITS ","; HITS = HITS r }
}

function hashit(r) { return index("," HITS ",", "," r ",") > 0 }

function delhit(r,    t) {
  t = "," HITS ","
  sub("," r ",", ",", t)
  sub(/^,/, "", t); sub(/,$/, "", t)
  HITS = t
}

function load_string(str,    n, k, parts, off) {
  S = str; N = length(str)
  n = split(str, parts, "\n")
  off = 1
  for (k = 1; k <= n; k++) {
    L[SID, k] = parts[k]; LSTART[SID, k] = off; off += length(parts[k]) + 1
  }
  NLN[SID] = n
}

# soft = 1 for payloads that are only a best-effort reading (ssh remote command,
# eval): if such a payload does not tokenise, forget what it produced instead of
# raising the PARSE warning (the remote text may rely on variables or quoting
# that only exist at run time).
function analyze_string(str, soft,    oS, oN, oPOS, oSID, oHDLO, r, oERR, oHITS) {
  if (LV > 30) { ERR = 1; return 0 }
  oERR = ERR; oHITS = HITS
  if (soft) ERR = 0
  oS = S; oN = N; oPOS = POS; oSID = SID; oHDLO = HDLO
  SID = ++SIDMAX
  HDLO = HDN
  load_string(str)
  POS = 1
  parse_list("")
  r = RETTRIG
  HDN = HDLO
  S = oS; N = oN; POS = oPOS; SID = oSID; HDLO = oHDLO
  if (soft) { if (ERR) { HITS = oHITS; r = 0 } ERR = oERR }
  RETTRIG = r
  return r
}

function lineof(p,    lo, hi, mid) {
  lo = 1; hi = NLN[SID]
  while (lo < hi) {
    mid = int((lo + hi + 1) / 2)
    if (LSTART[SID, mid] <= p) lo = mid; else hi = mid - 1
  }
  return lo
}

# POS is at an unquoted newline and heredocs are pending: skip their bodies.
function skip_heredoc_bodies(    ln, k, t, found, ln2) {
  ln = lineof(POS)
  for (k = HDLO + 1; k <= HDN; k++) {
    found = 0
    for (ln2 = ln + 1; ln2 <= NLN[SID]; ln2++) {
      t = L[SID, ln2]
      sub(/\r$/, "", t)
      if (HDT[k]) sub(/^\t+/, "", t)
      if (t == HDD[k]) { found = 1; break }
    }
    ln = found ? ln2 : NLN[SID]
  }
  HDN = HDLO
  if (ln >= NLN[SID]) POS = N + 1; else POS = LSTART[SID, ln + 1]
}

function read_delim(    out, c, j) {
  while (substr(S, POS, 1) == " " || substr(S, POS, 1) == "\t") POS++
  out = ""
  while (POS <= N) {
    c = substr(S, POS, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r" || c == ";" || c == "|" || c == "&" || c == "<" || c == ">" || c == "(" || c == ")") break
    if (c == "'") {
      j = index(substr(S, POS + 1), "'")
      if (j == 0) { ERR = 1; POS = N + 1; break }
      out = out substr(S, POS + 1, j - 1); POS += j + 1
    } else if (c == "\"") {
      j = index(substr(S, POS + 1), "\"")
      if (j == 0) { ERR = 1; POS = N + 1; break }
      out = out substr(S, POS + 1, j - 1); POS += j + 1
    } else if (c == "\\") {
      out = out substr(S, POS + 1, 1); POS += 2
    } else { out = out c; POS++ }
  }
  return out
}

function skip_brace(    depth, c) {
  POS += 2; depth = 1
  while (POS <= N) {
    c = substr(S, POS, 1)
    if (c == "{") depth++
    else if (c == "}") { depth--; if (depth == 0) { POS++; return } }
    else if (c == "\\") POS++
    POS++
  }
  ERR = 1
}

function appw(lvl, s) {
  if (!INW[lvl]) { INW[lvl] = 1; WCS[lvl] = CS[lvl] }
  W[lvl] = W[lvl] s
}

function emit(lvl, ty, v, g,    n) {
  n = ++NT[lvl]; TY[lvl, n] = ty; TV[lvl, n] = v; TG[lvl, n] = g
}

function emitop(lvl, v,    n) {
  n = NT[lvl]
  CS[lvl] = 1; TGT[lvl] = 0
  if (v == "\n" && n > 0 && TY[lvl, n] == "o" && (TV[lvl, n] == "&&" || TV[lvl, n] == "||" || TV[lvl, n] == "|" || TV[lvl, n] == "|&")) return
  emit(lvl, "o", v, "")
}

function flushw(lvl,    wv) {
  if (!INW[lvl]) return
  wv = W[lvl]
  if (TGT[lvl]) {
    TGT[lvl] = 0
  } else if (CL[lvl] == "}" && WCS[lvl] && !WQ[lvl] && wv == "}") {
    DONE[lvl] = 1
  } else if (WCS[lvl] && !WQ[lvl] && wv == "{") {
    OPENB[lvl] = 1
  } else {
    emit(lvl, "w", wv, "")
    CS[lvl] = (WCS[lvl] && !WQ[lvl] && wv ~ /^(if|then|else|elif|do|while|until|!|time)$/) ? 1 : 0
  }
  W[lvl] = ""; INW[lvl] = 0; WQ[lvl] = 0
}

function fl(lvl) {
  flushw(lvl)
  if (OPENB[lvl]) {
    OPENB[lvl] = 0
    parse_list("}")
    emit(lvl, "w", "\002", RETTRIG)
    CS[lvl] = 0
  }
}

function scan_dq(lvl,    c, d, k) {
  appw(lvl, ""); WQ[lvl] = 1
  POS++
  while (1) {
    if (POS > N) { ERR = 1; return }
    c = substr(S, POS, 1)
    if (c == "\"") { POS++; return }
    if (c == "\\") {
      d = substr(S, POS + 1, 1)
      if (d == "\n") POS += 2
      else if (d == "$" || d == "`" || d == "\"" || d == "\\") { appw(lvl, d); POS += 2 }
      else { appw(lvl, "\\"); POS++ }
    } else if (c == "$" && substr(S, POS + 1, 1) == "(") {
      POS += 2; parse_list(")"); appw(lvl, "\001")
    } else if (c == "$" && substr(S, POS + 1, 1) == "{") {
      skip_brace(); appw(lvl, "\001")
    } else if (c == "`") {
      POS++; parse_list("`"); appw(lvl, "\001")
    } else {
      k = POS + 1
      while (k <= N && index(DQSPEC, substr(S, k, 1)) == 0) k++
      appw(lvl, substr(S, POS, k - POS)); POS = k
    }
  }
}

function parse_list(closer,    lvl, c, nx, k, j, out, closed, strip, dl) {
  lvl = ++LV
  NT[lvl] = 0; W[lvl] = ""; INW[lvl] = 0; WQ[lvl] = 0; TGT[lvl] = 0
  CS[lvl] = 1; WCS[lvl] = 1; PD[lvl] = 0; CL[lvl] = closer; DONE[lvl] = 0; OPENB[lvl] = 0
  while (!DONE[lvl]) {
    if (POS > N) { fl(lvl); if (!DONE[lvl] && closer != "") ERR = 1; break }
    c = substr(S, POS, 1)
    if (c == " " || c == "\t" || c == "\r") {
      fl(lvl); if (DONE[lvl]) continue
      POS++
    } else if (c == "\n") {
      fl(lvl); if (DONE[lvl]) continue
      emitop(lvl, "\n")
      if (HDN > HDLO) skip_heredoc_bodies(); else POS++
    } else if (c == "#") {
      if (INW[lvl]) { appw(lvl, "#"); POS++ }
      else {
        j = index(substr(S, POS), "\n")
        if (j == 0) POS = N + 1; else POS += j - 1
      }
    } else if (c == "'") {
      appw(lvl, ""); WQ[lvl] = 1
      j = index(substr(S, POS + 1), "'")
      if (j == 0) { ERR = 1; POS = N + 1 }
      else { appw(lvl, substr(S, POS + 1, j - 1)); POS += j + 1 }
    } else if (c == "\"") {
      scan_dq(lvl)
    } else if (c == "\\") {
      nx = substr(S, POS + 1, 1)
      if (nx == "\n") POS += 2
      else if (nx == "") POS++
      else { appw(lvl, nx); WQ[lvl] = 1; POS += 2 }
    } else if (c == "$") {
      nx = substr(S, POS + 1, 1)
      if (nx == "(") { POS += 2; parse_list(")"); appw(lvl, "\001"); WQ[lvl] = 1 }
      else if (nx == "{") { skip_brace(); appw(lvl, "\001"); WQ[lvl] = 1 }
      else if (nx == "'") {
        POS += 2; out = ""; closed = 0
        while (POS <= N) {
          dl = substr(S, POS, 1)
          if (dl == "\\") { out = out substr(S, POS + 1, 1); POS += 2 }
          else if (dl == "'") { POS++; closed = 1; break }
          else { out = out dl; POS++ }
        }
        if (!closed) ERR = 1
        appw(lvl, out); WQ[lvl] = 1
      }
      else { appw(lvl, "$"); POS++ }
    } else if (c == "`") {
      if (closer == "`") {
        fl(lvl); if (DONE[lvl]) continue
        POS++; DONE[lvl] = 1
      } else {
        POS++; parse_list("`"); appw(lvl, "\001"); WQ[lvl] = 1
      }
    } else if (c == ";") {
      if (PD[lvl] > 0) { appw(lvl, ";"); POS++ }
      else { fl(lvl); if (DONE[lvl]) continue; emitop(lvl, ";"); POS++ }
    } else if (c == "&") {
      if (PD[lvl] > 0) { appw(lvl, "&"); POS++ }
      else {
        fl(lvl); if (DONE[lvl]) continue
        nx = substr(S, POS + 1, 1)
        if (nx == ">") { POS += 2; if (substr(S, POS, 1) == ">") POS++; TGT[lvl] = 1 }
        else if (nx == "&") { emitop(lvl, "&&"); POS += 2 }
        else { emitop(lvl, "&"); POS++ }
      }
    } else if (c == "|") {
      if (PD[lvl] > 0) { appw(lvl, "|"); POS++ }
      else {
        fl(lvl); if (DONE[lvl]) continue
        nx = substr(S, POS + 1, 1)
        if (nx == "|") { emitop(lvl, "||"); POS += 2 }
        else if (nx == "&") { emitop(lvl, "|&"); POS += 2 }
        else { emitop(lvl, "|"); POS++ }
      }
    } else if (c == "<" || c == ">") {
      nx = substr(S, POS + 1, 1)
      if (nx == "(") {
        POS += 2; parse_list(")"); appw(lvl, "\001"); WQ[lvl] = 1
      } else {
        if (INW[lvl] && !WQ[lvl] && W[lvl] ~ /^[0-9]+$/) { W[lvl] = ""; INW[lvl] = 0 }
        else { fl(lvl); if (DONE[lvl]) continue }
        if (c == "<" && nx == "<") {
          if (substr(S, POS + 2, 1) == "<") { POS += 3; TGT[lvl] = 1 }
          else {
            POS += 2; strip = 0
            if (substr(S, POS, 1) == "-") { strip = 1; POS++ }
            dl = read_delim()
            HDN++; HDD[HDN] = dl; HDT[HDN] = strip
          }
        } else {
          POS++
          if (c == ">" && (nx == ">" || nx == "|" || nx == "&")) POS++
          else if (c == "<" && (nx == "&" || nx == ">")) POS++
          TGT[lvl] = 1
        }
      }
    } else if (c == "(") {
      if (CS[lvl] && !INW[lvl]) {
        POS++; parse_list(")"); emit(lvl, "w", "\002", RETTRIG); CS[lvl] = 0
      } else { PD[lvl]++; appw(lvl, "("); POS++ }
    } else if (c == ")") {
      if (PD[lvl] > 0) { PD[lvl]--; appw(lvl, ")"); POS++ }
      else {
        fl(lvl); if (DONE[lvl]) continue
        POS++
        if (closer == ")") DONE[lvl] = 1; else emitop(lvl, ";")
      }
    } else {
      k = POS + 1
      while (k <= N && index(SPEC, substr(S, k, 1)) == 0) k++
      appw(lvl, substr(S, POS, k - POS)); POS = k
    }
  }
  fl(lvl)
  analyze_list(lvl)
  LV = lvl - 1
}

function aw(lvl, i, cnt) { return (i >= 1 && i <= cnt) ? SWV[lvl, i] : "" }

function bname(p) { sub(/^.*\//, "", p); return p }

function is_assign(v) { return v ~ /^[A-Za-z_][A-Za-z0-9_]*=/ }

function analyze_list(lvl,    n, i, ty, v, sc, pn, k, tr, trigAny, prevN, prevOp, firstcmd, curTrig, prevTrig, prevR4new, r4new) {
  n = NT[lvl]; sc = 0; pn = 0; trigAny = 0; prevN = 0; prevOp = ""; firstcmd = ""
  prevTrig = 0; prevR4new = 0
  for (i = 1; i <= n + 1; i++) {
    if (i <= n) { ty = TY[lvl, i]; v = TV[lvl, i] } else { ty = "o"; v = "" }
    if (ty == "w") { sc++; SWV[lvl, sc] = v; SWG[lvl, sc] = TG[lvl, i]; continue }
    if (sc > 0) {
      tr = analyze_stage(lvl, sc)
      pn++; STR[lvl, pn] = tr
      if (pn == 1) firstcmd = RETCMD
      if (tr) trigAny = 1
    }
    sc = 0
    if (v == "|" || v == "|&") continue
    if (pn > 0) {
      if ((firstcmd == "echo" || firstcmd == "printf") && prevOp == "&&" && prevTrig) {
        addhit("R5")
        if (prevR4new) delhit("R4")
      }
      curTrig = 0
      for (k = 1; k < pn; k++) if (STR[lvl, k]) { curTrig = 1; break }
      r4new = 0
      if (curTrig) { if (!hashit("R4")) r4new = 1; addhit("R4") }
      prevN = pn; prevTrig = curTrig; prevR4new = r4new
    } else { prevN = 0; prevTrig = 0; prevR4new = 0 }
    prevOp = v
    pn = 0
  }
  RETTRIG = trigAny
}

function analyze_stage(lvl, cnt,    i, v, w, b, r) {
  i = 1
  while (i <= cnt) {
    v = SWV[lvl, i]
    if (v == "\002") { RETCMD = "(group)"; return SWG[lvl, i] + 0 }
    if (is_assign(v)) { i++; continue }
    if (v ~ /^(if|then|else|elif|do|while|until|!|\{|\}|nohup|builtin|fi|done|esac)$/) { i++; continue }
    if (v == "time") { i++; while (i <= cnt && aw(lvl, i, cnt) ~ /^-/) i++; continue }
    if (v == "command") {
      i++
      while (i <= cnt && aw(lvl, i, cnt) ~ /^-/) {
        if (aw(lvl, i, cnt) ~ /[vV]/) { RETCMD = "command"; return 0 }
        i++
      }
      continue
    }
    if (v == "exec") { i++; while (i <= cnt && aw(lvl, i, cnt) ~ /^-/) { if (aw(lvl, i, cnt) == "-a") i += 2; else i++ } continue }
    if (v == "sudo") {
      i++
      while (i <= cnt && aw(lvl, i, cnt) ~ /^-/) {
        w = aw(lvl, i, cnt)
        if (w == "--") { i++; break }
        if (w == "-u" || w == "-g" || w == "-h" || w == "-p" || w == "-C" || w == "-T" || w == "-U" || w == "-r" || w == "-t" || w == "-D" || w == "-R" || w == "--user" || w == "--group" || w == "--host") i += 2
        else i++
      }
      continue
    }
    if (v == "env") {
      i++
      while (i <= cnt) {
        w = aw(lvl, i, cnt)
        if (w ~ /^-/) { if (w == "-u" || w == "-C" || w == "-S" || w == "--unset" || w == "--chdir") i += 2; else i++ }
        else if (is_assign(w)) i++
        else break
      }
      continue
    }
    if (v == "timeout") {
      i++
      while (i <= cnt && aw(lvl, i, cnt) ~ /^-/) { w = aw(lvl, i, cnt); if (w == "-s" || w == "-k") i += 2; else i++ }
      i++
      continue
    }
    if (v == "nice") { i++; while (i <= cnt && aw(lvl, i, cnt) ~ /^-/) { if (aw(lvl, i, cnt) == "-n") i += 2; else i++ } continue }
    break
  }
  if (i > cnt) { RETCMD = ""; return 0 }
  b = bname(SWV[lvl, i])
  if (b == "git") r = git_check(lvl, i + 1, cnt)
  else if (b ~ /^(bash|sh|zsh|dash|ksh|ash)$/) r = shell_check(lvl, i + 1, cnt)
  else if (b == "eval") r = eval_check(lvl, i + 1, cnt)
  else if (b == "ssh") r = ssh_check(lvl, i + 1, cnt)
  else if (b ~ /^php[0-9.]*$/) r = php_check(lvl, i + 1, cnt)
  else r = script_check(lvl, i, cnt)
  RETCMD = b
  return r
}

# An R4 trigger is a name in the comma list EXC ("git push", "make", "pm-preflight.sh").
function is_exit_cmd(name) { return index("," EXC ",", "," name ",") > 0 }

function script_check(lvl, i, cnt,    sb) {
  sb = bname(aw(lvl, i, cnt))
  return is_exit_cmd(sb) ? 1 : 0
}

function php_check(lvl, a, cnt,    j, w) {
  j = a
  while (j <= cnt && aw(lvl, j, cnt) ~ /^-/) {
    w = aw(lvl, j, cnt)
    if (w == "-d" || w == "-c" || w == "-z" || w == "-r") j += 2; else j++
  }
  if (j > cnt) return 0
  return script_check(lvl, j, cnt)
}

function shell_check(lvl, a, cnt,    j, w, p) {
  j = a
  while (j <= cnt) {
    w = aw(lvl, j, cnt)
    if (w == "--") { j++; break }
    if (w == "-o" || w == "-O" || w == "+o" || w == "+O") { j += 2; continue }
    if (w ~ /^-[A-Za-z]*c[A-Za-z]*$/) {
      p = j + 1
      if (aw(lvl, p, cnt) == "--") p++
      if (p > cnt) return 0
      return analyze_string(SWV[lvl, p], 0)
    }
    if (w ~ /^[-+]/) { j++; continue }
    break
  }
  if (j > cnt) return 0
  return script_check(lvl, j, cnt)
}

function eval_check(lvl, a, cnt,    j, s) {
  s = ""
  for (j = a; j <= cnt; j++) { if (j > a) s = s " "; s = s SWV[lvl, j] }
  if (s == "") return 0
  return analyze_string(s, 1)
}

function ssh_check(lvl, a, cnt,    j, w, s) {
  j = a
  while (j <= cnt) {
    w = aw(lvl, j, cnt)
    if (w ~ /^-[bcDEeFIiJLlmOopQRSWw]$/) j += 2
    else if (w ~ /^-/) j++
    else break
  }
  j++
  if (j > cnt) return 0
  s = ""
  for (; j <= cnt; j++) { if (s != "") s = s " "; s = s SWV[lvl, j] }
  return analyze_string(s, 1)
}

function nv_prefix(w) { return (length(w) >= 7 && index("--no-verify", w) == 1) }

function is_arming(v) { return v == HP || v == "./" HP }

function git_check(lvl, a, cnt,    i, w, lw, sc, cv) {
  i = a
  while (i <= cnt) {
    w = aw(lvl, i, cnt)
    if (w == "-c") {
      cv = aw(lvl, i + 1, cnt); lw = tolower(cv)
      if (lw ~ /^core\.hookspath(=|$)/) { sub(/^[^=]*=?/, "", cv); if (!is_arming(cv)) addhit("R1b") }
      i += 2
    }
    else if (w == "--config-env") { lw = tolower(aw(lvl, i + 1, cnt)); if (lw ~ /^core\.hookspath=/) addhit("R1b"); i += 2 }
    else if (w ~ /^--config-env=/) { lw = tolower(w); if (lw ~ /^--config-env=core\.hookspath=/) addhit("R1b"); i++ }
    else if (w == "-C" || w == "--git-dir" || w == "--work-tree" || w == "--namespace" || w == "--super-prefix" || w == "--attr-source") i += 2
    else if (w ~ /^-/) i++
    else break
  }
  if (i > cnt) return 0
  sc = SWV[lvl, i]; i++
  if (sc == "commit") { git_commit(lvl, i, cnt); return 0 }
  if (sc == "push") { git_push(lvl, i, cnt); return is_exit_cmd("git push") }
  if (sc == "add") { git_add(lvl, i, cnt); return 0 }
  if (sc == "config") { git_config(lvl, i, cnt); return 0 }
  return is_exit_cmd("git " sc)
}

function git_commit(lvl, i, cnt,    w, n, j, ch) {
  while (i <= cnt) {
    w = SWV[lvl, i]
    if (w == "--") break
    if (w ~ /^--/) {
      if (nv_prefix(w)) addhit("R1")
      else if (w ~ /^--(message|file|author|date|reuse-message|reedit-message|fixup|squash|template|cleanup|trailer|pathspec-from-file)$/) i++
      i++
    } else if (w ~ /^-[A-Za-z]/) {
      n = length(w)
      for (j = 2; j <= n; j++) {
        ch = substr(w, j, 1)
        if (ch == "n") addhit("R1")
        else if (index("mFCct", ch) > 0) { if (j == n) i++; break }
        else if (ch == "u" || ch == "S") break
      }
      i++
    } else i++
  }
}

function git_push(lvl, i, cnt,    w) {
  while (i <= cnt) {
    w = SWV[lvl, i]
    if (w == "--") break
    if (w ~ /^--/) {
      if (nv_prefix(w)) addhit("R1")
      else if (w ~ /^--(push-option|receive-pack|exec|repo)$/) i++
      i++
    } else if (w == "-o") i += 2
    else i++
  }
}

function git_add(lvl, i, cnt,    w, dot, hasU, dd) {
  dot = 0; hasU = 0; dd = 0
  while (i <= cnt) {
    w = SWV[lvl, i]
    if (!dd && w == "--") dd = 1
    else if (!dd && w ~ /^--/) { if (w == "--all") addhit("R2"); else if (w == "--update") hasU = 1 }
    else if (!dd && w ~ /^-[A-Za-z]/) { if (w ~ /A/) addhit("R2"); if (w ~ /u/) hasU = 1 }
    else if (w == ".") dot = 1
    i++
  }
  if (dot && !hasU) addhit("R2")
}

function git_config(lvl, i, cnt,    w, unset, getm, np, key, val) {
  unset = 0; getm = 0; np = 0; key = ""; val = ""
  while (i <= cnt) {
    w = SWV[lvl, i]
    if (w == "--unset" || w == "--unset-all") unset = 1
    else if (w ~ /^(--get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|--list|-l)$/) getm = 1
    else if (w == "--file" || w == "-f" || w == "--blob" || w == "--type" || w == "--default") i++
    else if (w ~ /^-/) { }
    else { np++; if (np == 1) key = w; else if (np == 2) val = w }
    i++
  }
  if (tolower(key) != "core.hookspath") return
  if (unset) addhit("R1b")
  else if (np >= 2 && !getm) { if (is_arming(val)) addhit("R1c"); else addhit("R1b") }
}

BEGIN { RS = "\001"; SIDMAX = 0; LV = 0; HITS = ""; ERR = 0; HDN = 0; HDLO = 0
        SPEC = " \t\r\n\"'\\$`;&|<>()#"; DQSPEC = "\"\\$`" }
{ S0 = (NR == 1) ? $0 : S0 "\n" $0 }
END {
  analyze_string(S0, 0)
  print "HITS=" HITS
  print "ERR=" ERR
}
AWKEOF
# ---------------------------------------------------------------------------

scan_command() {
  # $1 = command text. Sets SCAN_HITS (comma list) and SCAN_ERR (0/1).
  local out rc
  out=$(printf '%s' "$1" | LC_ALL=C awk -v HP="$HP" -v EXC="$EXC" "$AWK_PROG" 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    echo "bash-guard INACTIVE: awk scan failed (rc=$rc)" >&2
    exit 1
  fi
  SCAN_HITS=${out#HITS=}
  SCAN_HITS=${SCAN_HITS%%$'\n'*}
  SCAN_ERR=${out##*ERR=}
}

mode_of() {
  local v="MODE_$1"
  echo "${!v:-warn}"
}

run_hook() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "bash-guard INACTIVE: jq not found on PATH" >&2
    exit 1
  fi
  local input cmd rc
  input=$(cat)
  cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "bash-guard INACTIVE: stdin is not parseable JSON" >&2
    exit 1
  fi
  [ -z "$cmd" ] && exit 0

  scan_command "$cmd"

  if [ "$SCAN_ERR" = "1" ]; then
    jq -n --arg c "bash-guard WARN [PARSE]: this command could not be analysed (unbalanced quote, parenthesis or heredoc?). The guard did not apply its rules to it; check by eye that it does not use git commit -n/--no-verify, git add -A, core.hooksPath, or an exit code read through a pipe." \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}'
    exit 0
  fi
  [ -z "$SCAN_HITS" ] && exit 0

  local r m ids="" blocks=0 text=""
  for r in $RULES; do
    case ",$SCAN_HITS," in
      *",$r,"*)
        m=$(mode_of "$r")
        [ "$m" = "off" ] && continue
        ids="${ids:+$ids,}$r"
        [ "$m" = "block" ] && blocks=1
        text="$text
- $(rule_msg "$r") [mode: $m]"
        ;;
    esac
  done
  [ -z "$ids" ] && exit 0
  if [ $blocks -eq 1 ]; then
    printf 'bash-guard BLOCKED [%s]%s\n' "$ids" "$text" >&2
    exit 2
  fi
  jq -n --arg c "bash-guard WARN [$ids]:$text" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}'
  exit 0
}

# ------------------------------------------------------------------ SELF-TEST
selftest_one() {
  # $1 = line number, $2 = expect, $3 = label, $4 = command
  local json res rc got ids
  total=$((total + 1))
  json=$(jq -n --arg c "$4" '{tool_input: {command: $c}}')
  res=$(bash "$SELF" 2>&1 <<<"$json")
  rc=$?
  if [ $rc -eq 2 ]; then
    ids=${res#*\[}; ids=${ids%%\]*}
    got="block:${ids//,/+}"
  elif [ $rc -eq 0 ]; then
    if [ -z "$res" ]; then got="allow"
    else ids=${res#*\[}; ids=${ids%%\]*}; got="warn:${ids//,/+}"
    fi
  else
    got="rc=$rc"
  fi
  if [ "$got" != "$2" ]; then
    failed=$((failed + 1))
    printf 'FAIL line %s [%s] expected %s got %s\n' "$1" "$3" "$2" "$got"
  fi
}

run_selftest() {
  local f="${BASH_GUARD_CASES:-$(dirname "$SELF")/bash-guard.cases}"
  if [ ! -r "$f" ]; then
    echo "bash-guard self-test: cases file missing or unreadable: $f" >&2
    exit 3
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "bash-guard INACTIVE: jq not found on PATH" >&2
    exit 1
  fi
  total=0; failed=0
  unset BASH_GUARD_HOOKS_PATH BASH_GUARD_EXITCODE_CMDS   # the cases run under the defaults
  local line rest expect label cmd hline lineno=0 have=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      "### "*)
        if [ $have -eq 1 ]; then selftest_one "$hline" "$expect" "$label" "${cmd%$'\n'}"; fi
        rest=${line#"### "}
        expect=${rest%% *}
        label=${rest#"$expect"}
        label=${label# }; label=${label#— }
        cmd=""; have=1; hline=$lineno
        ;;
      *)
        [ $have -eq 1 ] && cmd="$cmd$line"$'\n'
        ;;
    esac
  done < "$f"
  if [ $have -eq 1 ]; then selftest_one "$hline" "$expect" "$label" "${cmd%$'\n'}"; fi
  if [ $total -eq 0 ]; then
    echo "bash-guard self-test: cases file holds zero cases: $f" >&2
    exit 3
  fi
  # The two overrides, each against the default behaviour.
  export BASH_GUARD_HOOKS_PATH="hooks/gates"
  selftest_one ovr allow "override: arming value hooks/gates" 'git -c core.hooksPath=hooks/gates commit -m x'
  selftest_one ovr block:R1b "override: .githooks is not the expected value" 'git -c core.hooksPath=.githooks commit -m x'
  selftest_one ovr warn:R1c "override: persistent arming of hooks/gates" 'git config core.hooksPath hooks/gates'
  unset BASH_GUARD_HOOKS_PATH; export BASH_GUARD_EXITCODE_CMDS="make,git fetch"
  selftest_one ovr warn:R4 "override: make is an exit-code command" 'make all | tail'
  selftest_one ovr warn:R4 "override: git fetch is an exit-code command" 'git fetch | tail'
  selftest_one ovr allow "override: git push is no longer listed" 'git push | tail'
  selftest_one ovr warn:R4 "override: pm-preflight.sh stays listed" 'bin/pm-preflight.sh | tail'
  unset BASH_GUARD_EXITCODE_CMDS
  printf 'bash-guard self-test: %d cases, %d failed\n' "$total" "$failed"
  [ $failed -eq 0 ] && exit 0
  exit 1
}

case "${1:-}" in
  --self-test) run_selftest ;;
  "") run_hook ;;
  *) echo "usage: bash-guard.sh [--self-test]  (hook JSON on stdin)" >&2; exit 64 ;;
esac
