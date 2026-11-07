#!/bin/sh
# touch: differential tests against GNU touch 9.7 (C locale). References: GNU
# manual "touch invocation"; POSIX.1-2024 touch. Cases with explicit times
# compare atime/mtime to the nanosecond (TREE_TIMES); cases that use the
# current time compare everything but the times.
UTIL="touch"
. "$(dirname "$0")/testlib.sh"
help_cmp
S='printf x > f; mkdir d; ln -s f lnk; ln -s nowhere dangling; printf y > g; chmod 444 g; touch -d @1000000000.123456789 f; touch -d @1100000000 g; touch -d @1200000000 d; : > ro; touch -d @1300000000 ro; chmod 000 ro; touch -h -d @900000000 lnk dangling'
TREE_TIMES=1
export TZ=UTC

printf "\n[ Explicit times ]\n"
for d in @0 @1 @-1 @1700000000 @1700000000.5 @1700000000.123456789 @-1.5 '2024-02-29 12:34:56' '2024-02-29' '2024-02-29 12:34:56.789' '2024-02-29T12:34:56Z' '2024-02-29 12:34:56 +0530' '2024-02-29 12:34:56 EST' '1999-12-31 23:59:59' '1970-01-01' '2038-01-19 03:14:08' '2100-01-01' 'TZ="America/New_York" 2024-07-01 12:00' '2024-02-30' 'garbage' '' '@' '2024-03-10 02:30'; do
    run_tree "-d '$d' new"      "$S" -d "$d" new
    run_tree "-d '$d' f"        "$S" -d "$d" f
    run_tree "-d '$d' -a f"     "$S" -a -d "$d" f
    run_tree "-d '$d' -m f"     "$S" -m -d "$d" f
    run_tree "-d '$d' dir"      "$S" -d "$d" d
    run_tree "-d '$d' lnk"      "$S" -d "$d" lnk
    run_tree "-d '$d' -h lnk"   "$S" -h -d "$d" lnk
done
for tzv in America/New_York Asia/Kolkata Europe/London; do
    TZ=$tzv run_tree "-d local string $tzv" "$S" -d '2024-06-15 08:09:10' f new
    TZ=$tzv run_tree "-t $tzv"              "$S" -t 202406150809.10 f new
done
for t in 202401020304 202401020304.05 2401020304 2401020304.59 0102030405 0102030405.06 7001020304 6901020304 6801020304 9912312359 200002290000 190001010000 203801190314 210001010000 202402300000 202413010000 202401320000 202401012500 202401010060 202401010000.60 202401010000.61 202401010000.62 abc 20240102030 2024010203045 '' 12 202401020304. 202401020304.5 202401020304.555; do
    run_tree "-t $t f"          "$S" -t "$t" f
    run_tree "-t $t new"        "$S" -t "$t" new
done
run_tree "-t then -d"         "$S" -t 202401020304 -d @5 f
run_tree "-d then -t"         "$S" -d @5 -t 202401020304 f
run_tree "-t -r"              "$S" -t 202401020304 -r g f
run_tree "-r -d"              "$S" -r g -d @5 f

printf "\n[ Reference files ]\n"
run_tree "-r g f"             "$S" -r g f
run_tree "-r g new"           "$S" -r g new
run_tree "-r missing"         "$S" -r nofile f
run_tree "-r dir"             "$S" -r d f
run_tree "-r lnk (follow)"    "$S" -r lnk new
run_tree "-r -h lnk"          "$S" -r lnk -h new f
run_tree "-r dangling"        "$S" -r dangling new
run_tree "-r dangling -h"     "$S" -r dangling -h f
run_tree "-r g -a"            "$S" -r g -a f
run_tree "-r g -m"            "$S" -r g -m f
run_tree "-r g -d +1day"      "$S" -r g -d '1 day' f
run_tree "-r g -d '2 hours ago' -a" "$S" -r g -a -d '2 hours ago' f
run_tree "-r g -d '2 hours ago' -m" "$S" -r g -m -d '2 hours ago' f
run_tree "-r g -d absolute"   "$S" -r g -d '2000-01-01' f
run_tree "-r g -d invalid"    "$S" -r g -d garbage f
run_tree "--reference=g"      "$S" --reference=g f

printf "\n[ -a -m --time ]\n"
for o in -a -m "-a -m" "--time=atime" "--time=access" "--time=use" "--time=mtime" "--time=modify" "--time=a" "--time=m" "--time=bad" "--time=at -m" "--time=mod -a" "--time"; do
    run_tree "[$o] -d @5 f"     "$S" $o -d @5 f
    run_tree "[$o] -r g f"      "$S" $o -r g f
    run_tree "[$o] -t f"        "$S" $o -t 200001020304 f
done

printf "\n[ Creation and options ]\n"
run_tree "creates"            "$S" -d @5 n1 n2 n3
run_tree "-c no create"       "$S" -c -d @5 nope f
run_tree "-c only missing"    "$S" -c nope
run_tree "-c dangling"        "$S" -c -d @5 dangling
run_tree "dangling creates target?" "$S" -d @5 dangling
run_tree "-h dangling"        "$S" -h -d @5 dangling
run_tree "-h missing"         "$S" -h -d @5 nope
run_tree "--no-create"        "$S" --no-create -d @5 nope
run_tree "--no-dereference"   "$S" --no-dereference -d @5 lnk
run_tree "--date="            "$S" --date=@5 f
run_tree "unreadable file"    "$S" -d @5 ro
run_tree "dir parent missing" "$S" -d @5 nodir/x
run_tree "dir parent unwritable" "$S; mkdir rodir; chmod 555 rodir" -d @5 rodir/x
run_tree "readonly existing"  "$S" -d @5 g
run_tree "directory"          "$S" -d @5 d
run_tree "-f"                 "$S" -f -d @5 f
run_tree "no operand"         "$S" -d @5
run_tree "no operand no date" "$S"
run_tree "bad option"         "$S" -z f
run_tree "-- file"            "$S" -d @5 -- -weird
run_tree "dash stdout file"   "$S" -d @5 - > /dev/null
run_tree "-c -"               "$S" -c -d @5 -
run_tree "name with space"    "$S" -d @5 'a b' 'c	d'
run_tree "long abbrev"        "$S" --dat=@5 f
run_tree "ambiguous"          "$S" --r=g f
run_tree "date format error"  "$S" -d 'not a date' f
run_tree "multiple sources"   "$S" -t 202401020304 -d @5 f

printf "\n[ Current time ]\n"
now_ok() { # run both and check the mtime of the target is within 5 s of now
    desc="$1"; shift
    d1="$TEST_TMP/now1"; rm -rf "$d1"; mkdir -p "$d1"
    (cd "$d1" && ours "$@") >/dev/null 2>&1
    n=$(date +%s); m=$(stat -c %Y "$d1"/new 2>/dev/null || echo 0)
    if [ "$m" -ge $((n - 5)) ] && [ "$m" -le $((n + 5)) ]; then PASS=$((PASS + 1)); printf "PASS %s\n" "$desc"; else FAIL=$((FAIL + 1)); printf "FAIL %s (mtime %s now %s)\n" "$desc" "$m" "$n"; fi
}
now_ok "touch new"            new
now_ok "-d now"               -d now new
now_ok "-a new"               -a new
now_ok "-m new"               -m new
now_ok "-d 'now' -a"          -d now -a new
now_ok "-d '2 sec ago'"       -d '2 sec ago' new
TREE_TIMES= run_tree "touch existing"    "$S" f
TREE_TIMES= run_tree "touch -a existing" "$S" -a f
TREE_TIMES= run_tree "touch -d now"      "$S" -d now f
TREE_TIMES= run_tree "touch readonly (owner)" "$S" g
print_summary
[ "$FAIL" -eq 0 ]
