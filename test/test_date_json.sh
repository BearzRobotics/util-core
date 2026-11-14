#!/bin/sh
# date --json: every field is compared with what GNU date prints for the same
# instant and zone (GNU coreutils 9.7). Needs python3 and GNU date.
BIN="$(cd "${OURS_DIR:-$(dirname "$0")/../zig-out/bin}" && pwd)"
export LC_ALL=C
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
t() { name=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi; }

field() { # TZ, date string, json key, GNU strftime format
    tzv=$1; ds=$2; key=$3; gf=$4
    want=$(TZ=$tzv date -d "$ds" "+$gf")
    got=$(TZ=$tzv "$BIN/date" --json -d "$ds" | python3 -c "import json,sys; print(json.load(sys.stdin)['$key'])")
    [ "$want" = "$got" ] && ok || bad "$tzv '$ds' $key: GNU=[$want] OURS=[$got]"
}
for tzv in UTC America/New_York Asia/Kolkata Australia/Adelaide Europe/London; do
    for ds in "@0" "@1234567890" "2024-02-29 12:34:56" "2024-07-04 23:59:59" "1999-12-31 00:00:00" "2038-01-19 03:14:08" "@-86400" "Sun Feb 15 2009 10:00 UTC"; do
        field $tzv "$ds" epoch %s
        field $tzv "$ds" iso8601 %Y-%m-%dT%H:%M:%S%:z
        field $tzv "$ds" year %Y
        field $tzv "$ds" month %-m
        field $tzv "$ds" day %-d
        field $tzv "$ds" hour %-H
        field $tzv "$ds" minute %-M
        field $tzv "$ds" second %-S
        field $tzv "$ds" weekday %A
        field $tzv "$ds" weekday_number %u
        field $tzv "$ds" day_of_year %-j
        field $tzv "$ds" zone %Z
    done
done
# Offset in seconds: GNU prints +hhmm; convert.
off() { TZ=$1 date -d "$2" +%z | python3 -c "import sys; z=sys.stdin.read().strip(); s=(int(z[1:3])*3600+int(z[3:5])*60)*(-1 if z[0]=='-' else 1); print(s)"; }
for tzv in UTC America/New_York Asia/Kolkata Australia/Adelaide; do
    for ds in "@1234567890" "2024-07-04 12:00:00"; do
        want=$(off $tzv "$ds")
        got=$(TZ=$tzv "$BIN/date" --json -d "$ds" | python3 -c "import json,sys; print(json.load(sys.stdin)['utc_offset'])")
        [ "$want" = "$got" ] && ok || bad "$tzv utc_offset '$ds': GNU=[$want] OURS=[$got]"
    done
done
t "nsec" sh -c "[ \"\$('$BIN/date' --json -d @1.5 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"nsec\"])')\" = 500000000 ]"
t "dst true in summer" sh -c "TZ=America/New_York '$BIN/date' --json -d '2024-07-04 12:00' | python3 -c 'import json,sys;assert json.load(sys.stdin)[\"dst\"] is True'"
t "dst false in winter" sh -c "TZ=America/New_York '$BIN/date' --json -d '2024-01-04 12:00' | python3 -c 'import json,sys;assert json.load(sys.stdin)[\"dst\"] is False'"
t "-u overrides TZ" sh -c "TZ=Asia/Kolkata '$BIN/date' --json -u -d @0 | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d[\"utc_offset\"]==0 and d[\"zone\"]==\"UTC\"'"
t "now parses and is recent" sh -c "'$BIN/date' --json | python3 -c 'import json,sys,time;d=json.load(sys.stdin);assert abs(d[\"epoch\"]-time.time())<5'"
t "-f: one object per line" sh -c "printf '@0\n@86400\n@172800\n' > \"\${TMPDIR:-/tmp}/dkt_dates\"; [ \"\$('$BIN/date' --json -f \"\${TMPDIR:-/tmp}/dkt_dates\" | wc -l)\" = 3 ]; rc=\$?; rm -f \"\${TMPDIR:-/tmp}/dkt_dates\"; [ \$rc = 0 ]"
t "-r file" sh -c "[ \"\$('$BIN/date' --json -r /etc/passwd | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"epoch\"])')\" = \"\$(date -r /etc/passwd +%s)\" ]"
t "invalid date fails like GNU" sh -c "! '$BIN/date' --json -d 'not a date'"
t "--json with +FORMAT is refused" sh -c "! '$BIN/date' --json +%s"
t "--json with -I is refused" sh -c "! '$BIN/date' --json -I"
t "--json with -R is refused" sh -c "! '$BIN/date' --json -R"
t "--json with --resolution is refused" sh -c "! '$BIN/date' --json --resolution"
t "--json is not in --help" sh -c "! '$BIN/date' --help | grep -q json"
t "text output is unchanged" sh -c "[ \"\$(TZ=UTC '$BIN/date' -d @1234567890)\" = \"\$(TZ=UTC date -d @1234567890)\" ]"
echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
