#!/bin/sh
# tee: differential tests against GNU tee. References: GNU manual "tee
# invocation"; POSIX.1-2024 tee.
UTIL="tee"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"
printf 'one\ntwo\nthree' > "$W/in"
CMP_STDIN="$W/in"

# same_files DESC FILE...: files written by GNU (dir g) and ours (dir o) match.
both() { # DESC ARGS...  -- run in separate dirs with identical pre-state
    d="$1"; shift
    rm -rf "$W/g" "$W/o"; mkdir "$W/g" "$W/o"
    for x in g o; do printf 'OLD\n' > "$W/$x/exist"; done
    (cd "$W/g" && LC_ALL=C gnu "$@" < "$W/in" > "$W/g.out" 2> "$W/g.err"; echo $? > "$W/g.rc")
    (cd "$W/o" && ours "$@" < "$W/in" > "$W/o.out" 2> "$W/o.err"; echo $? > "$W/o.rc")
    norm_err < "$W/g.err" > "$W/g.err2"; norm_err < "$W/o.err" > "$W/o.err2"
    if cmp -s "$W/g.out" "$W/o.out" && cmp -s "$W/g.err2" "$W/o.err2" && cmp -s "$W/g.rc" "$W/o.rc" \
        && diff -r "$W/g" "$W/o" >/dev/null; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$d"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n     GNU rc=%s err=%s\n     OURS rc=%s err=%s\n" "$d" "$(cat "$W/g.rc")" "$(cat -A "$W/g.err2")" "$(cat "$W/o.rc")" "$(cat -A "$W/o.err2")"
        diff -r "$W/g" "$W/o" | head -5
    fi
}

printf "\n[ Copying ]\n"
both "stdout only"
both "one file"                 f1
both "two files"                f1 f2
both "overwrite existing"       exist
both "-a append"                -a exist
both "--append new file"        --append f1
both "-a abbreviated --app"     --app exist
both "file named - is a file"   -
both "-- then dash-file"        -- -a
both "-i accepted"              -i f1
both "--ignore-interrupts"      --ignore-interrupts f1
both "-ai clustered"            -ai exist

printf "\n[ Errors ]\n"
both "unwritable path continues" /nonexistent-dir/x f1
both "directory operand"        . f1
both "invalid option"           -x
both "unrecognized long"        --nope
both "-p"                       -p f1
both "--output-error"           --output-error f1
both "--output-error=warn"      --output-error=warn f1
both "--output-error=exit bad path" --output-error=exit /nonexistent-dir/x f1
both "--output-error=bogus"     --output-error=bogus f1

printf "\n[ Binary and empty input ]\n"
head -c 200000 /dev/urandom > "$W/in"
both "large binary input"       f1
: > "$W/in"
both "empty input"              f1

printf "\n[ Closed stdout pipe ]\n"
# Default mode: SIGPIPE kills tee, so the writer ends and the pipeline finishes.
# A timeout guards against a hang.
for t in gnu ours; do
    st=$( { yes | timeout 5 "$( [ $t = gnu ] && echo /usr/bin/tee || echo "$BIN_DIR/tee" )" | head -c 10 >/dev/null; } 2>&1; echo "rc=$?" )
    eval "pipe_$t=\$st"
done
[ "$pipe_gnu" = "$pipe_ours" ] && { PASS=$((PASS + 1)); echo "PASS default mode ends when stdout pipe closes ($pipe_ours)"; } || { FAIL=$((FAIL + 1)); echo "FAIL pipe: GNU '$pipe_gnu' OURS '$pipe_ours'"; }
# -p: a closed pipe on stdout is not an error and tee stops once nothing is left.
yes | timeout 5 "$BIN_DIR/tee" -p 2>"$W/err" | head -c 10 >/dev/null
[ ! -s "$W/err" ] && { PASS=$((PASS + 1)); echo "PASS -p is silent on a closed pipe"; } || { FAIL=$((FAIL + 1)); echo "FAIL -p stderr: $(cat "$W/err")"; }

rm -rf "$W"
print_summary
