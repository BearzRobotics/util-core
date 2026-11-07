#!/bin/sh
# truncate: differential tests against GNU truncate 9.7 (C locale). File sizes
# are part of the compared tree through the %s of a size listing.
UTIL="truncate"
. "$(dirname "$0")/testlib.sh"
sz() { :; }
S='printf 0123456789 > ten; : > empty; head -c 5000 /dev/zero > big'
for sz in 0 1 5 10 11 100 4096 1K 1KB 1KiB 2M 1G 1T 2K 1b; do
    run_tree "-s $sz new file"     "$S" -s $sz newfile
    run_tree "-s $sz ten"          "$S" -s $sz ten
    run_tree "-s +$sz ten"         "$S" -s +$sz ten
    run_tree "-s -$sz ten"         "$S" -s -$sz ten
    run_tree "-s '<$sz' ten"       "$S" -s "<$sz" ten
    run_tree "-s '>$sz' ten"       "$S" -s ">$sz" ten
    run_tree "-s /$sz big"         "$S" -s "/$sz" big
    run_tree "-s %$sz big"         "$S" -s "%$sz" big
done
run_tree "-s 0 zero rounding"      "$S" -s /0 ten
run_tree "-s %0"                   "$S" -s %0 ten
run_tree "-c missing"              "$S" -c -s 5 nofile
run_tree "-c existing"             "$S" -c -s 5 ten
run_tree "no-create long"          "$S" --no-create -s 5 nofile
run_tree "-r reference"            "$S" -r ten empty
run_tree "-r missing ref"          "$S" -r nofile empty
run_tree "-r and -s"               "$S" -r ten -s +3 empty
run_tree "-r and -s abs"           "$S" -r ten -s 3 empty
run_tree "--reference=big"         "$S" --reference=big ten
run_tree "--size=7"                "$S" --size=7 ten
run_tree "several files"           "$S" -s 3 ten empty big newone
run_tree "no -s no -r"             "$S" ten
run_tree "no file"                 "$S" -s 5
run_tree "bad size x"              "$S" -s x ten
run_tree "bad size empty"          "$S" -s '' ten
run_tree "bad size 1Q2"            "$S" -s 1Q2 ten
run_tree "bad size ++5"            "$S" -s ++5 ten
run_tree "size negative result"    "$S" -s -100 ten
run_tree "dir as target"           'mkdir d' -s 5 d
run_tree "missing dir"             "$S" -s 5 nodir/f
run_tree "-o"                      "$S" -o -s 2 ten
run_tree "-o new"                  "$S" -o -s 2 newfile
run_tree "-x"                      "$S" -x -s 5 ten
run_tree "--bogus"                 "$S" --bogus -s 5 ten
run_tree "-- operand"              "$S" -s 5 -- -dash
run_tree "-s attached"             "$S" -s5 ten
run_tree "-r attached"             "$S" -rten empty
print_summary
