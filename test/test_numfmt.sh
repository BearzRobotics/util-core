#!/bin/sh
UTIL="numfmt"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Human readable ]\n"
run_test "--to=si 1000"                  --to=si 1000
run_test "--to=iec 1024"                 --to=iec 1024
run_test "--to=si 1000000"               --to=si 1000000

printf "\n[ From human readable ]\n"
run_test "--from=si 1K"                  --from=si 1K
run_test "--from=iec 1Ki"                --from=iec 1Ki

printf "\n[ Field selection ]\n"
run_test "--field=2"                     --field=2 "label 1000"
run_test "--padding"                     --to=si --padding=10 1000

print_summary
