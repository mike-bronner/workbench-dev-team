# The end of every dispatch log it is given, in one pass, for the dev-team
# mod's runs pane (hooks/mods/runs.ts reads the output).
#
# Usage: awk -f scan-run-logs.awk <log>...
#
# Per readable file, a header line: \036 (the record separator), the count of
# its "Permission denied: " lines, a tab, and the path. Then its last three
# lines that are not refusals, as bin/dispatch-agent.sh's circuit breaker reads
# them. An empty file gets its header alone, after the others. A file it cannot
# open (a log deleted since the pane listed it) is skipped and gets no header,
# so the pane drops that run rather than the whole list. It writes nothing.

BEGIN {
  for (i = 1; i < ARGC; i++) {
    if ((getline line < ARGV[i]) < 0) ARGV[i] = ""
    else { close(ARGV[i]); want[ARGV[i]] = 1 }
  }
}

function flush(  i, s) {
  if (f == "") return
  seen[f] = 1
  print "\036" c "\t" f
  s = (k > 3 ? k - 3 : 0)
  for (i = s; i < k; i++) print t[i % 3]
}

FNR == 1 { flush(); f = FILENAME; c = 0; k = 0 }
/^Permission denied: / { c++; next }
{ t[k % 3] = $0; k++ }
END {
  flush()
  for (p in want) if (!(p in seen)) print "\036" 0 "\t" p
}
