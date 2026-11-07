#!/bin/sh
# stat: differential tests against GNU stat 9.7 (C locale). References: GNU
# manual "stat invocation". Both programs examine the same files, so every
# field including inode, device and change time is comparable. File system
# counters that change over time are left out of the -f cases.
UTIL="stat"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
printf 'hello\n' > file; : > empty; head -c 100000 /dev/zero > big; mkdir dir; ln -s file lnk; ln -s nowhere dangling; ln -s dir dlnk
mkfifo fifo; ln file hard; printf x > "we ird"; printf x > "q'uote"; printf x > "$(printf 'tab\tname')"; printf x > "new
line"
chmod 4755 big; chmod 2755 dir; chmod 1777 empty; chmod 000 hard 2>/dev/null; chmod 600 "we ird"
touch -d @1234567890.123456789 file; touch -d @-100.5 empty; touch -d @4102444800 big; touch -h -d @1000000000.25 lnk
python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('sock')" 2>/dev/null || true
FILES="file empty big dir lnk dangling dlnk fifo hard /dev/null /dev/zero /dev/tty /proc /proc/self /sys /tmp ."
export TZ=UTC

printf "\n[ Default and terse ]\n"
for f in file empty big dir lnk dangling dlnk fifo hard /dev/null /dev/zero / /proc sock "we ird" "q'uote"; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    run_cmp "default $f"     "$f"
    run_cmp "-L $f"          -L "$f"
    run_cmp "-t $f"          -t "$f"
    run_cmp "-Lt $f"         -L -t "$f"
done
run_cmp "several"           file dir empty
run_cmp "missing"           nofile
run_cmp "missing and ok"    nofile file
run_cmp "-L dangling"       -L dangling
run_cmp "no operand"
run_cmp "dash stdin"        -
CMP_STDIN=file run_cmp "dash file stdin" -
run_cmp "unreadable dir"    dir/nofile
run_cmp "long name"         "$(printf 'a%.0s' $(seq 300))"

printf "\n[ Format directives ]\n"
for d in a A b B C d D f F g G h i m n N o s r R t T u U w W x X y Y z Z Hd Ld Hr Lr; do
    for f in file big dir lnk fifo /dev/null /dev/zero /; do
        run_cmp "%$d $f"     -c "%$d" "$f"
    done
    run_cmp "-L %$d lnk"     -L -c "%$d" lnk
done
for fl in '' '-' '0' '+' ' ' '#' "'" '10' '-10' '010' '+10' '.2' '10.2' '#o' '-#10' '3.1' '.0' '1' '40'; do
    for d in a s u g n A F N i x X Y W b h o d f w; do
        run_cmp "%$fl$d file"   -c "%$fl$d" file
    done
done
for fmt in '%' '%%' 'a%' '%5' '%5%' '%z%z' '%Q' '%k' '%-' '%10Z' 'plain text' '' '%n %s %n' '[%n]' '%0n' '%3n|' '%-30n|' '%.2n' '%5.3s' '%.0s' '%.0X' '%.3X' '%12.3Y' '%-12.3Y|' '%.12Y' '%012.3Z' '%+Z' '%,s' '%q' '%H' '%L' '%Hz' '%Ln' '%Hd %Hr'; do
    run_cmp "-c '$fmt'"       -c "$fmt" file
    run_cmp "--printf '$fmt'" --printf "$fmt" file
done
for fmt in 'a\nb' '\t|' '\\' '\"' '\a\b\e\f\r\v' '\101' '\0' '\1' '\18' '\x41' '\x4' '\xZ' '\q' '\' 'x\' '\0101' '\777' '\xFFg' '%n\n' '%s\0%s' '\\n'; do
    run_cmp "--printf '$fmt'" --printf "$fmt" file
    run_cmp "-c '$fmt'"       -c "$fmt" file
done
run_cmp "-c and --printf"   -c %n --printf '%s\n' file
run_cmp "--format="         --format=%n file
run_cmp "--format missing arg" --format
run_cmp "%N dangling"       -c %N dangling
run_cmp "%N dir lnk"        -c %N dlnk
run_cmp "%N special names"  -c %N "we ird" "q'uote" "new
line"
QUOTING_STYLE=literal run_cmp "QUOTING_STYLE=literal" -c %N lnk "we ird"
QUOTING_STYLE=shell run_cmp "QUOTING_STYLE=shell" -c %N lnk "we ird"
QUOTING_STYLE=c run_cmp "QUOTING_STYLE=c" -c %N lnk "we ird"
QUOTING_STYLE=bogus run_cmp "QUOTING_STYLE=bogus" -c %N lnk
run_cmp "%n weird"          -c %n "we ird" "q'uote" "new
line"
run_cmp "default weird"     "we ird"
run_cmp "default quote"     "q'uote"
run_cmp "default tab name"  "$(printf 'tab\tname')"
run_cmp "default newline name" "new
line"

printf "\n[ File systems ]\n"
for f in / /tmp /proc /dev /sys /dev/shm . file dir lnk; do
    [ -e "$f" ] || continue
    for d in n i l t T s S; do
        run_cmp "-f %$d $f"   -f -c "%$d" "$f"
    done
    run_cmp "-f -t type $f"   -f -c "%t %T %l %s %S" "$f"
done
run_cmp "-f missing"        -f nofile
run_cmp "-f dash"           -f -
run_cmp "-f -L lnk"         -f -L -c %n lnk
run_cmp "-f %Q"             -f -c %Q /
run_cmp "-f %%"             -f -c '%%' /
run_cmp "-f bad dir"        -f -c %n nodir/x
run_cmp "-f several"        -f -c %n / /tmp nofile

printf "\n[ Options ]\n"
run_cmp "--cached=always"   --cached=always file
run_cmp "--cached=never"    --cached=never file
run_cmp "--cached=default"  --cached=default file
run_cmp "--cached=bad"      --cached=bad file
run_cmp "--cached=a"        --cached=a file
run_cmp "--cached missing"  --cached
run_cmp "bad option"        -z file
run_cmp "long abbrev"       --deref lnk
run_cmp "ambiguous"         --f file
run_cmp "-- file"           -- file
run_cmp "-c -- file"        -c %n -- file
run_cmp "--dereference"     --dereference lnk
run_cmp "--file-system"     --file-system -c %T file
run_cmp "--terse"           --terse file
for tzv in America/New_York Asia/Kolkata; do
    TZ=$tzv run_cmp "default $tzv"   file empty big
    TZ=$tzv run_cmp "%x %y %z %w $tzv" -c '%x|%y|%z|%w' file empty
done
print_summary
[ "$FAIL" -eq 0 ]
