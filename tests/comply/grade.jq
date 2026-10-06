# grade.jq — the deterministic detector interpreter of the PM compliance harness.
# Inputs (--argjson): calls  [{n,name,input}]   final  string   files  [path]   kind  string
#                     steps  [{id,kinds,required,after,detector,desc}]   tokens  {NAME: value}
# Output: {rows:[{id,required,status,ordinal,evidence}], req_total, req_observed}
# The detector language is documented at the top of spec.tsv. Nothing here asks a model anything.
def esc: gsub("(?<c>[.\\\\+*?\\[\\]^$(){}|/-])"; "\\\(.c)");
def bname($p): $p | rtrimstr("/") | split("/") | last;
def dname($p): $p | rtrimstr("/") | split("/") | .[:-1] | join("/");
def subst:
  reduce ($tokens | keys_unsorted[]) as $k (.;
      gsub("\\$\\{" + $k + "\\}"; ($tokens[$k] | esc))
    | gsub("\\$\\{" + $k + ":base\\}"; (bname($tokens[$k]) | esc))
    | gsub("\\$\\{" + $k + ":dir\\}"; (dname($tokens[$k]) | esc)));
def fold: gsub("[\\t\\n\\r]+"; " ");
def fieldv($c; $p):
  if $p == "input" then ($c.input | tojson)
  else ($c.input | getpath($p | ltrimstr("input.") | split("."))) as $v
       | if $v == null then "" elif ($v | type) == "string" then $v else ($v | tojson) end
  end;
def split1($s): ($s | index("~")) as $i | [$s[:$i], $s[$i+1:]];
def clause($c; $anch; $firstbash):
  . as $cl
  | if ($cl | startswith("final~")) then ($final | test($cl[6:]))
    elif ($cl | startswith("tool=")) then ($cl[5:] | split("|") | any(.[]; . == $c.name))
    elif $cl == "first-bash" then ($c.n == $firstbash)
    elif ($cl | startswith("field=")) then (split1($cl[6:]) as [$p, $re] | (fieldv($c; $p) | test($re)))
    elif ($cl | startswith("!field=")) then (split1($cl[7:]) as [$p, $re] | (fieldv($c; $p) | test($re) | not))
    elif ($cl | startswith("absent=")) then (fieldv($c; $cl[7:]) == "")
    elif ($cl | startswith("present=")) then (fieldv($c; $cl[8:]) != "")
    elif ($cl | startswith("files-in=")) then (fieldv($c; $cl[9:]) as $v | all($files[]; . as $f | $v | contains($f)))
    elif ($cl | startswith("after=")) then ($anch[$cl[6:]] as $a | ($a != null and $c.n > $a))
    elif ($cl | startswith("before=")) then ($anch[$cl[7:]] as $a | ($a != null and $c.n < $a))
    else error("unknown detector clause: " + $cl) end;
def callev($c): "#\($c.n) \($c.name) " + (if $c.name == "Bash" then ($c.input.command // "") else ($c.input | tojson) end | fold | .[0:160]);
def matches($clauses; $anch; $firstbash):
  if all($clauses[]; startswith("final~"))
  then (if all($clauses[]; clause(null; $anch; $firstbash)) then [{n: null, ev: ("final: " + ($final | fold | .[0:160]))}] else [] end)
  else [ $calls[] | . as $c | select(all($clauses[]; clause($c; $anch; $firstbash))) | {n: $c.n, ev: callev($c)} ]
  end;
def applies($s): ($s.kinds | gsub(","; " ") | split(" ") | map(select(. != ""))) as $k | ($k | any(.[]; . == "all" or . == $kind));
([$calls[] | select(.name == "Bash") | .n] | first) as $firstbash
| reduce $steps[] as $s ({anch: {}, rows: []};
    if (applies($s) | not) then .rows += [{id: $s.id, required: false, status: "n/a", ordinal: null, evidence: "(not a \($kind) step)"}]
    elif ($s.required == "files" and ($files | length) == 0) then .rows += [{id: $s.id, required: false, status: "n/a", ordinal: null, evidence: "(scenario names no files)"}]
    else
      ($s.detector | startswith("none:")) as $none
      | ($s.detector | ltrimstr("none:") | ltrimstr(" ") | subst) as $d
      | (if ($s.after != "-" and $s.after != "") then ["after=" + $s.after] else [] end) as $aft
      | (.anch) as $anch
      | ([ ($d | split(" || "))[] | (split(" && ") + $aft) as $cl | matches($cl; $anch; $firstbash)[] ] | sort_by(.n)) as $hits
      | ($s.required == "yes" or $s.required == "files") as $req
      | if $none then
          .rows += [{id: $s.id, required: $req, status: (if ($hits | length) == 0 then "yes" else "no" end), ordinal: null,
                     evidence: (if ($hits | length) == 0 then "no matching call among \($calls | length) tool calls" else $hits[0].ev end)}]
        else
          .rows += [{id: $s.id, required: $req, status: (if ($hits | length) > 0 then "yes" else "no" end),
                     ordinal: ($hits[0].n // null),
                     evidence: (if ($hits | length) > 0 then $hits[0].ev
                                else "no matching call" + (if ($aft | length) > 0 and ($anch[$s.after] == null) then " (anchor \($s.after) not observed)" else "" end) end)}]
          | if ($hits | length) > 0 and $hits[0].n != null then .anch[$s.id] = $hits[0].n else . end
        end
    end)
| .rows as $rows
| {rows: $rows,
   req_total: ($rows | map(select(.required)) | length),
   req_observed: ($rows | map(select(.required and .status == "yes")) | length)}
