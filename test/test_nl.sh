#!/bin/sh
# nl: differential tests against GNU nl (C locale). References: GNU manual "nl
# invocation"; POSIX.1-2024 nl. The pBRE numbering style needs a BRE engine
# and is not implemented, so it is not tested against GNU.
UTIL="nl"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"
printf 'a\n\nb\n\n\n\nc\n' > blank
printf 'h1\n\\:\\:\\:\nh2\nh2b\n\\:\\:\nb1\nb2\n\\:\nf1\n\\:\\:\\:\nh3\n\\:\\:\nb3\n\n\\:\nf2\n' > pages
printf 'x\n  \nspaced  line\n\ttab\n' > spaces
printf 'one\ntwo' > nonl
printf 'a\r\nb\r\n' > crlf
printf '@@@\nhdr\n@@\nbody\n@\nfoot\n' > custom
printf 'x\ny\nz\n' > xyz
: > empty

printf "\n[ Styles ]\n"
for s in a t n; do
    run_cmp "-b$s blank"       -b$s blank
    run_cmp "-b$s spaces"      -b$s spaces
    run_cmp "-h$s -b$s -f$s pages" -h$s -b$s -f$s pages
done
run_cmp "default blank"        blank
run_cmp "default pages"        pages
run_cmp "empty"                empty
run_cmp "no trailing newline"  nonl
run_cmp "CRLF"                 crlf
run_cmp "--body-numbering=a"   --body-numbering=a blank
run_cmp "--header-numbering=a" --header-numbering=a --footer-numbering=a pages
run_cmp "-b ta separate arg"   -b a blank
run_cmp "style with tail chars" -bnb blank

printf "\n[ -n format and -w -s ]\n"
for f in ln rn rz; do
    run_cmp "-n$f"             -n$f xyz
    run_cmp "-n$f -w 3"        -n$f -w 3 xyz
    run_cmp "-n$f -w 1"        -n$f -w 1 xyz
    run_cmp "-n$f -v -2 -w 4"  -n$f -v -2 -w 4 xyz
    run_cmp "-n$f negative incr" -n$f -i -3 -w 5 xyz
done
run_cmp "--number-format=ln"   --number-format=ln xyz
run_cmp "-w 10"                -w 10 xyz
run_cmp "--number-width=2"     --number-width=2 xyz
run_cmp "-s :"                 -s: xyz
run_cmp "-s empty"             -s '' xyz
run_cmp "-s multi"             -s ' | ' -ba blank
run_cmp "--number-separator=,"  --number-separator=, xyz
run_cmp "-s with unnumbered"   -s: blank
run_cmp "-w 3 -s abc unnumbered" -w 3 -s abc blank

printf "\n[ -v -i -l ]\n"
run_cmp "-v 10"                -v 10 xyz
run_cmp "-v -5"                -v -5 xyz
run_cmp "-i 5"                 -i 5 xyz
run_cmp "-i -1 -v 3"           -i -1 -v 3 xyz
run_cmp "-i 0"                 -i 0 xyz
run_cmp "-v 10 -i 10"          -v 10 -i 10 xyz
run_cmp "--starting-line-number=7" --starting-line-number=7 xyz
run_cmp "--line-increment=2"   --line-increment=2 xyz
for l in 0 1 2 3 4 5; do
    run_cmp "-ba -l $l"        -ba -l $l blank
done
run_cmp "--join-blank-lines=2" -ba --join-blank-lines=2 blank
run_cmp "-l 2 without -ba"     -l 2 blank
run_cmp "-l across pages"      -ha -ba -fa -l 2 pages

printf "\n[ Pages: -p, -d ]\n"
run_cmp "-ha -fa pages"        -ha -fa pages
run_cmp "-p -ha -fa"           -p -ha -fa pages
run_cmp "--no-renumber"        --no-renumber -ha -fa pages
run_cmp "-p -v 5"              -p -v 5 -ha -fa pages
run_cmp "-v 5 resets"          -v 5 -ha -fa pages
run_cmp "-d '@@' custom"       -d '@@' -ha -fa custom
run_cmp "-d '@' (default :)"   -d '@' -ha -fa custom
run_cmp "-d empty"             -d '' -ba pages
run_cmp "--section-delimiter"  --section-delimiter='@@' -ha -fa custom
run_cmp "-d multi-char"        -d '@@@' -ha -fa custom
run_cmp "pages default delim as text" -d 'XY' pages

printf "\n[ Files and stdin ]\n"
CMP_STDIN="$W/xyz"
run_cmp "stdin"
run_cmp "stdin as -"           -
run_cmp "two files continue"   xyz xyz
run_cmp "pages across files"   pages pages
run_cmp "missing among files"  xyz nope xyz
run_cmp "-- then file"         -- xyz
run_cmp "missing file only"    nope

printf "\n[ Errors ]\n"
run_cmp "-b x"                 -bx xyz
run_cmp "-h x"                 -hx xyz
run_cmp "-f x"                 -fx xyz
run_cmp "-b empty"             -b '' xyz
run_cmp "-w 0"                 -w0 xyz
run_cmp "-w x"                 -wx xyz
run_cmp "-w -1"                -w -1 xyz
run_cmp "-i x"                 -ix xyz
run_cmp "-l x"                 -lx xyz
run_cmp "-l -1"                -l -1 xyz
run_cmp "-v x"                 -v x xyz
run_cmp "-n zz"                -nzz xyz
run_cmp "-n empty"             -n '' xyz
run_cmp "invalid option"       -x xyz
run_cmp "unrecognized long"    --nope xyz
run_cmp "-b missing arg"       -b

cd /; rm -rf "$W"
print_summary
