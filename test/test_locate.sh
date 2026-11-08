#!/bin/sh
# locate: differential tests against GNU findutils 4.10 locate, built from
# source (tools/build-gnu-findutils.sh) because distributions ship plocate.
UTIL="locate"
FU="${GNU_BIN:-$HOME/.cache/util-core/findutils/bin}"
if [ ! -x "$FU/locate" ]; then
    echo "SKIP: GNU findutils not built; run tools/build-gnu-findutils.sh" >&2
    exit 0
fi
GNU_BIN="$FU"; export GNU_BIN
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
export TZ=UTC LC_ALL=C
set -f
mkdir -p tree/a/b tree/c "tree/sp ace" tree/d/e/f
for f in a/one.txt a/b/Two.TXT a/b/three.c c/four.sh "sp ace/five six" top.md d/e/f/deep.dat d/e/UPPER LOWER; do : > "tree/$f"; done
: > "tree/new
line"; : > "tree/$(printf 'caf\303\251')"; : > 'tree/we*ird[name]?'; : > tree/back\\slash; ln -s one.txt tree/a/link; ln -s nowhere tree/dangling
"$FU/updatedb" --localpaths="$W/tree" --output="$W/db1" --prunepaths=/nonexistent
"$FU/updatedb" --localpaths="$W/tree/a $W/tree/c" --output="$W/db2" --prunepaths=/nonexistent
printf '' > empty_file
cp db1 db1_copy
# an old database and an slocate database
"$FU/updatedb" --localpaths="$W/tree/c" --output="$W/db_old" --prunepaths=/nonexistent; touch -d '2020-01-01' db_old
"$FU/updatedb" --localpaths="$W/tree" --output="$W/db_sl" --dbformat=slocate --prunepaths=/nonexistent
rm -f tree/top.md
loc() { d="$1"; shift; CMP_STDIN=/dev/null run_cmp "$d" "$@"; }
# the database holds absolute paths of this run; both programs read the same file
D="-d $W/db1"
for pat in one .txt TXT '*.txt' '*TXT' 'a/b' '*/b/*' '/a/' 'one.txt' '?ne' '[ot]*' 'sp' 'space' '*ace*' 'six' 'five six' '\*' '*\[*' 'we*' 'ird' 'caf' "$(printf 'caf\303\251')" '?' '*' '' '[' '[a' 'back' '\\' 'new' 'line' 'deep' 'DEEP' 'UPPER' 'upper' 'LOWER' 'tree' 'nowhere' 'link' '/' '..' '.'; do
    for o in "" "-i" "-b" "-bi" "-w" "-c" "-ci" "-S" "-0" "-e" "-E" "-eb" "-P -e" "-H -e" "-L -e" "-P -E" "-l 1" "-l 3" "-l 0" "-p" "-cb" "-bc -l 2" "-r" "-ri" "-rb" "-A" "-Ab"; do
        loc "locate $o '$pat'" locate -d "$W/db1" $o -- "$pat"
    done
done
for rt in "" "--regextype=posix-basic" "--regextype=posix-extended" "--regextype=emacs" "--regextype=grep" "--regextype=egrep" "--regextype=awk" "--regextype=sed" "--regextype=bogus" "--regextype"; do
    for re in '\.txt$' 'one\|two' '(one|two)' 'o+' 'o\+' '[0-9]' '^/' 'a/b/.*c' '\(' '(' '[' '*x' 'x**' 'f{1,2}' 'f\{1,2\}' '.' 'e$' 'E$'; do
        loc "locate -r $rt '$re'" locate -d "$W/db1" -r $rt -- "$re"
        loc "locate -ri $rt '$re'" locate -d "$W/db1" -ri $rt -- "$re"
    done
done
loc 'two patterns' locate -d "$W/db1" one txt
loc 'two patterns -A' locate -d "$W/db1" -A one txt
loc 'three patterns -A' locate -d "$W/db1" -A tree a txt
loc 'two patterns -c' locate -d "$W/db1" -c one txt
loc 'two patterns -A -c' locate -d "$W/db1" -A -c one txt
loc 'two globs' locate -d "$W/db1" '*.txt' '*.c'
loc 'glob + substring' locate -d "$W/db1" '*.txt' four
loc 'two dbs' locate -d "$W/db1:$W/db2" one
loc 'two dbs -c' locate -d "$W/db1:$W/db2" -c one
loc 'two dbs -l 1' locate -d "$W/db1:$W/db2" -l 1 one
loc 'two dbs -S' locate -d "$W/db1:$W/db2" -S one
loc 'two dbs missing first' locate -d "$W/nosuch:$W/db2" one
loc 'two dbs missing second' locate -d "$W/db2:$W/nosuch" one
loc 'db missing' locate -d "$W/nosuch" one
loc 'db dir' locate -d "$W" one
loc 'db empty file' locate -d "$W/empty_file" one
loc 'db empty file -S' locate -d "$W/empty_file" -S one
loc 'db garbage' locate -d "$W/tree/a/one.txt" one
loc 'old db warning' locate -d "$W/db_old" one
loc 'old db warning -c' locate -d "$W/db_old" -c four
loc 'old db max age' locate -d "$W/db_old" --max-database-age 100000 four
loc 'old db max age 0' locate -d "$W/db_old" --max-database-age 0 four
loc 'max age empty' locate -d "$W/db1" --max-database-age '' one
loc 'max age bad' locate -d "$W/db1" --max-database-age x one
loc 'max age bad 2' locate -d "$W/db1" --max-database-age 1x one
loc 'slocate db' locate -d "$W/db_sl" one
loc 'slocate db -S' locate -d "$W/db_sl" -S one
loc 'slocate db -e' locate -d "$W/db_sl" -e one
loc 'slocate db -E' locate -d "$W/db_sl" -E one
loc 'slocate db -c' locate -d "$W/db_sl" -c txt
CMP_STDIN_SAVE=1; CMP_STDIN="$W/db1" run_cmp 'stdin db' locate -d - one
export LOCATE_PATH="$W/db2"
loc 'LOCATE_PATH' locate one
loc '-d beats LOCATE_PATH' locate -d "$W/db1" four
loc 'LOCATE_PATH two' locate -c four
unset LOCATE_PATH
export LOCATE_PATH="$W/db1:$W/db2"
loc 'LOCATE_PATH list' locate -c one
unset LOCATE_PATH
loc 'no pattern' locate -d "$W/db1"
loc 'no pattern -c' locate -d "$W/db1" -c
loc 'no pattern -S' locate -d "$W/db1" -S
loc 'no pattern -l 2 -S' locate -d "$W/db1" -S -l 2
loc 'no pattern -c -l 2' locate -d "$W/db1" -c -l 2
loc 'no pattern -p' locate -d "$W/db1" -p
loc '--limit' locate -d "$W/db1" --limit=2 e
loc '--limit x' locate -d "$W/db1" --limit=x e
loc '-l x' locate -d "$W/db1" -l x e
loc '-l -1' locate -d "$W/db1" -l -1 e
loc '-l 1x' locate -d "$W/db1" -l 1x e
loc '-l big' locate -d "$W/db1" -l 99999999999999999999 e
loc '--database' locate --database="$W/db1" four
loc '--existing' locate -d "$W/db1" --existing top
loc '--non-existing' locate -d "$W/db1" --non-existing top
loc '--ignore-case' locate -d "$W/db1" --ignore-case two
loc '--all' locate -d "$W/db1" --all a txt
loc '--null' locate -d "$W/db1" --null four
loc '--count' locate -d "$W/db1" --count four
loc '--wholename' locate -d "$W/db1" --wholename a/b
loc '--wholepath' locate -d "$W/db1" --wholepath a/b
loc '--basename' locate -d "$W/db1" --basename Two
loc '--print' locate -d "$W/db1" --print four
loc '--regex' locate -d "$W/db1" --regex 'four$'
loc '--statistics' locate -d "$W/db1" --statistics four
loc '--follow' locate -d "$W/db1" --follow -e link
loc '--nofollow' locate -d "$W/db1" --nofollow -e link
loc '--stdio' locate -d "$W/db1" --stdio four
loc '--mmap' locate -d "$W/db1" --mmap four
loc 'prefix --lim' locate -d "$W/db1" --lim=1 e
loc 'prefix --stat' locate -d "$W/db1" --stat four
loc 'ambiguous --n' locate -d "$W/db1" --n four
loc 'bad option' locate -Z four
loc 'bad long option' locate --bogus four
loc 'missing arg -d' locate -d
loc 'missing arg -l' locate -l
loc 'options after pattern' locate -d "$W/db1" four -c
loc '-- ' locate -d "$W/db1" -- -c
loc 'pattern starts dash' locate -d "$W/db1" -e -x
loc '--version' locate --version
loc 'version extra' locate --version four
mkdir -p "$W/live" && : > "$W/live/present" && : > "$W/live/other"
"$FU/updatedb" --localpaths="$W/live" --output="$W/db3" --prunepaths=/nonexistent
rm -f "$W/live/other"; ln -s present "$W/live/lnk" 2>/dev/null
loc '-e existing' locate -d "$W/db3" -e live
loc '-E non-existing' locate -d "$W/db3" -E live
loc '-e -c' locate -d "$W/db3" -e -c live
loc '-E -c' locate -d "$W/db3" -E -c live
loc '-e -S' locate -d "$W/db3" -e -S live
loc '-e -l 1' locate -d "$W/db3" -e -l 1 live
rm -f "$W/live/present"
loc '-L -e dangling link' locate -d "$W/db3" -L -e lnk
loc '-P -e dangling link' locate -d "$W/db3" -P -e lnk
loc '-L -E dangling link' locate -d "$W/db3" -L -E lnk
loc '-P -E dangling link' locate -d "$W/db3" -P -E lnk
cd /; print_summary
