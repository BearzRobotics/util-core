#!/bin/sh
# run_all_tests.sh - Run all util test scripts and summarize results

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_UTILS=""

run_suite() {
    script="$1"
    util=$(basename "$script" | sed 's/test_//;s/\.sh//')

    printf "\n######################################\n"
    printf " Testing: %s\n" "$util"
    printf "######################################\n"

    # Run script directly to preserve terminal for colors
    # Capture counts by parsing output on the fly
    temp_output=$(mktemp)
    status_file=$(mktemp)
    # The pipe would otherwise hide the suite's exit status.
    { sh "$script" 2>&1; echo $? > "$status_file"; } | tee "$temp_output"
    status=$(cat "$status_file")

    # Count occurrences, defaulting to 0 if grep finds nothing
    pass=$(grep -c "^PASS" "$temp_output" 2>/dev/null) || pass=0
    fail=$(grep -c "^FAIL" "$temp_output" 2>/dev/null) || fail=0
    skip=$(grep -c "^SKIP" "$temp_output" 2>/dev/null) || skip=0
    # The --json suites print only "N passed, M failed".
    if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ]; then
        counts=$(sed -n 's/.*[^0-9]\([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed.*/\1 \2/p' "$temp_output" | tail -n 1)
        if [ -n "$counts" ]; then
            pass=${counts% *}
            fail=${counts#* }
        fi
    fi
    # A suite that exits non-zero without a counted failure crashed or refused to run.
    if [ "${status:-1}" -ne 0 ] && [ "$fail" -eq 0 ]; then
        printf "FAIL %s exited with status %s\n" "$util" "${status:-unknown}"
        fail=1
    fi

    rm -f "$temp_output" "$status_file"

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))

    if [ "$fail" -gt 0 ]; then
        FAILED_UTILS="$FAILED_UTILS $util"
    fi
}

# Run all test scripts
# SKIP_SUITES is a space-separated list of names to leave out ("sync wine").
for script in "$TESTS_DIR"/test_*.sh; do
    name=$(basename "$script" .sh)
    case " ${SKIP_SUITES:-} " in
    *" ${name#test_} "*) printf "\nSKIP suite %s (SKIP_SUITES)\n" "${name#test_}"; continue ;;
    esac
    run_suite "$script"
done

# Final summary
TOTAL=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))
printf "\n\n######################################\n"
printf " FINAL RESULTS\n"
printf "######################################\n"
printf " Passed : %d\n" "$TOTAL_PASS"
printf " Failed : %d\n" "$TOTAL_FAIL"
printf " Skipped: %d\n" "$TOTAL_SKIP"
printf " Total  : %d\n" "$TOTAL"

if [ -n "$FAILED_UTILS" ]; then
    printf "\n Failed utils:%s\n" "$FAILED_UTILS"
else
    printf "\n All utils passed!\n"
fi
printf "######################################\n"
[ -z "$FAILED_UTILS" ]
