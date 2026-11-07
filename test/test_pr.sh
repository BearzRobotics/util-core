#!/bin/sh
# pr: differential tests against GNU pr 9.7 (C locale, TZ fixed per case).
# References: GNU manual "pr invocation"; POSIX.1-2024 pr. Header dates come
# from file modification times, which are set explicitly; for standard input
# the clock is used, so those cases pass -D with a constant format.
UTIL="pr"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
export TZ=UTC
seq 1 100 > f100; seq 1 7 > f7; seq 1 60 > f60; seq 1 56 > f56; seq 1 57 > f57; : > empty
printf 'no newline at end' > nonl
printf 'a\tb\tc\n\tx\ny\t\tz\n' > tabs
printf 'ctl\001\002\003 \033[1m\177 \200\377 end\nback\bsp\bace\n' > ctl
printf 'one\ntwo\n\fthree\nfour\n\f\nfive\n\f\f\nsix\n' > ff
printf 'page1 line1\npage1 line2\n\fpage2 line1\n\npage2 line3\n' > ff2
LC_ALL=C awk 'BEGIN{srand(5); for(i=0;i<80;i++){n=int(rand()*90); s=""; for(j=0;j<n;j++) s=s sprintf("%c",97+int(rand()*26)); print s}}' > rnd
LC_ALL=C awk 'BEGIN{for(i=1;i<=200;i++) printf "line %d has some text\n", i}' > text200
printf 'alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n' > greek
printf '1\n2\n3\n' > three
for f in f100 f7 f60 f56 f57 empty nonl tabs ctl ff ff2 rnd text200 greek three; do touch -d @1700000000 $f; done
touch -d @1000000000 f7; touch -d @1700003600 greek; touch -d "2024-02-29 23:59:59" three

DATE="-D FIXED"
printf "\n[ Defaults ]\n"
for f in f100 f7 f60 f56 f57 empty nonl tabs ctl ff ff2 rnd text200 greek three; do
    run_cmp "default $f" $f
    run_cmp "-t $f"      -t $f
    run_cmp "-T $f"      -T $f
done
CMP_STDIN=f7 run_cmp "stdin"  $DATE
CMP_STDIN=f7 run_cmp "stdin dash" $DATE -
run_cmp "two files" f7 greek
run_cmp "missing" nofile
run_cmp "missing then ok" nofile f7
run_cmp "-r missing" -r nofile
run_cmp "directory" .

printf "\n[ Time zones and date formats ]\n"
for tzv in UTC America/New_York Asia/Kolkata Europe/London Australia/Sydney EST5EDT "<+0530>-5:30" UTC+3 ""; do
    TZ="$tzv" run_cmp "TZ=$tzv" f7 greek three
done
for fmt in '%Y-%m-%d' '%b %e %H:%M %Y' '%c' '%s' '%A, %B %d' '%H%M%S%z' '' 'x%%y' '%j %U %V' '%F %T' '%Z'; do
    run_cmp "-D '$fmt'" -D "$fmt" f7
done
run_cmp "--date-format" --date-format='%d/%m/%y' f7
run_cmp "-h" -h "My Header" f7
run_cmp "-h empty" -h "" f7
run_cmp "--header" --header=TITLE f7
run_cmp "-h long" -h "a very long header title that overflows the page width easily" f7
run_cmp "-h with -w" -h TITLE -w 40 f7
run_cmp "-h on stdin" -h TITLE $DATE
CMP_STDIN=f7 run_cmp "-h stdin" -h TITLE $DATE

printf "\n[ Page length and pages ]\n"
for l in 1 2 3 5 6 10 11 12 15 20 25 66 100; do
    run_cmp "-l $l f60" -l $l f60
    run_cmp "-l $l -t f60" -l $l -t f60
    run_cmp "-l $l -f f60" -l $l -f f60
    run_cmp "-l $l -F f60" -l $l -F f60
    run_cmp "-l $l -d f60" -l $l -d f60
done
run_cmp "-l 0" -l 0 f7
run_cmp "-l x" -l x f7
run_cmp "--length=20" --length=20 f60
for pg in +1 +2 +3 +5 +100 +2:3 +1:1 +2:2 +3:2 +0 +x +1: +:2 +1:x; do
    run_cmp "$pg" "$pg" -l 20 f100
    run_cmp "$pg -t" "$pg" -l 20 -t f100
    run_cmp "$pg -n" "$pg" -l 20 -n f100
    run_cmp "$pg ff" "$pg" ff
done
run_cmp "--pages=2:3" --pages=2:3 -l 20 f100
run_cmp "--pages=2" --pages=2 -l 20 f100
run_cmp "--pages bad" --pages=3:2 f100
run_cmp "--pages=0" --pages=0 f100
run_cmp "--pages missing" --pages
run_cmp "+2 then --pages" +2 --pages=3 -l 20 f100
run_cmp "--pages then +2" --pages=3 +2 -l 20 f100

printf "\n[ Columns ]\n"
for c in 1 2 3 4 5 7 10 20; do
    for f in f100 f7 greek rnd text200 nonl three; do
        run_cmp "-$c $f"        -$c $f
        run_cmp "-$c -a $f"     -$c -a $f
        run_cmp "-$c -t $f"     -$c -t $f
    done
    run_cmp "--columns=$c"      --columns=$c f60
    run_cmp "-$c -w 40 f100"    -$c -w 40 f100
    run_cmp "-$c -W 50 f100"    -$c -W 50 f100
    run_cmp "-$c -d f60"        -$c -d f60
    run_cmp "-$c -l 20 f100"    -$c -l 20 f100
    run_cmp "-$c -n f100"       -$c -n f100
    run_cmp "-$c -a -n f100"    -$c -a -n f100
    run_cmp "-$c -o 5 f60"      -$c -o 5 f60
    run_cmp "-$c -J f60"        -$c -J f60
    run_cmp "-$c -s f60"        -$c -s f60
    run_cmp "-$c -s: f60"       -$c -s: f60
    run_cmp "-$c -S: f60"       -$c -S: f60
    run_cmp "-$c -S'ab' f60"    -$c -Sab f60
    run_cmp "-$c --sep-string f60" -$c --sep-string=' | ' f60
    run_cmp "-$c ff"            -$c ff
    run_cmp "-$c -a ff"         -$c -a ff
    run_cmp "-$c -t ff"         -$c -t ff
    run_cmp "-$c tabs"          -$c tabs
    run_cmp "-$c -e tabs"       -$c -e tabs
    run_cmp "-$c -i tabs"       -$c -i tabs
    run_cmp "-$c ctl"           -$c ctl
    run_cmp "-$c -c ctl"        -$c -c ctl
    run_cmp "-$c -v ctl"        -$c -v ctl
done
run_cmp "-0"              -0 f7
run_cmp "-x"              -x f7
run_cmp "-99999"          -99999 f7
run_cmp "-2 -3"           -2 -3 f60
run_cmp "-2 --columns=3"  -2 --columns=3 f60
run_cmp "--columns=3 -2"  --columns=3 -2 f60
run_cmp "--columns=0"     --columns=0 f7
run_cmp "--columns=x"     --columns=x f7
run_cmp "narrow width"    -10 -w 5 f7
run_cmp "narrow width -W" -10 -W 10 f7
run_cmp "column digits split" -1 -2 f7

printf "\n[ Merge ]\n"
run_cmp "-m two"          -m f7 greek
run_cmp "-m three"        -m f7 greek three
run_cmp "-m same"         -m f60 f60
run_cmp "-m different len" -m f100 f7
run_cmp "-m -n"           -m -n f7 greek
run_cmp "-m -t"           -m -t f7 greek three
run_cmp "-m -s"           -m -s f7 greek
run_cmp "-m -s,"          -m -s, f7 greek
run_cmp "-m -J"           -m -J f7 greek
run_cmp "-m -w 40"        -m -w 40 f7 greek
run_cmp "-m -W 40"        -m -W 40 f7 greek three
run_cmp "-m -S"           -m -S f7 greek
run_cmp "-m -S:"          -m -S: f7 greek
run_cmp "-m ff"           -m ff ff2
run_cmp "-m ff -t"        -m -t ff ff2
run_cmp "-m missing"      -m f7 nofile greek
run_cmp "-m missing -r"   -m -r f7 nofile greek
run_cmp "-m all missing"  -m nofile1 nofile2
run_cmp "-m with -2"      -m -2 f7 greek
run_cmp "-m -a"           -m -a f7 greek
run_cmp "-m stdin"        -m - f7
run_cmp "-m empty"        -m empty f7
run_cmp "-m -d"           -m -d f7 greek
run_cmp "-m -l 15"        -m -l 15 f100 f60
run_cmp "-m nonl"         -m nonl f7
run_cmp "-m tabs"         -m tabs greek
run_cmp "-m -o 4"         -m -o 4 f7 greek

printf "\n[ Numbering ]\n"
for n in "" 3 :4 x6 ,2 a b 0 11 -2; do
    run_cmp "-n$n"          -n$n f7
    run_cmp "-n$n -2"       -n$n -2 greek
done
run_cmp "--number-lines"    --number-lines f7
run_cmp "--number-lines=:3" --number-lines=:3 f7
run_cmp "-N 10 -n"          -N 10 -n f7
run_cmp "-N -5 -n"          -N -5 -n f7
run_cmp "-N 99998 -n"       -N 99998 -n f7
run_cmp "-N x"              -N x -n f7
run_cmp "--first-line-number=100 -n" --first-line-number=100 -n f7
run_cmp "-n +2 skip"        -n +2 -l 20 f100
run_cmp "-n -N +2"          -n -N 1 +2 -l 20 f100
run_cmp "-n tab sep -2"     -n -2 -w 30 f100
run_cmp "-n -e -2"          -n -e -2 tabs
run_cmp "-n:2 -i"           -n:2 -i tabs

printf "\n[ Tabs, control characters and widths ]\n"
for o in -e -e: -e:4 -e,3 -i -i: -i:4 -ia2 -e -i "-e -i" -c -v "-c -v" -ec -eX -e5; do
    run_cmp "$o tabs"       $o tabs
    run_cmp "$o ctl"        $o ctl
    run_cmp "$o -2 tabs"    $o -2 tabs
    run_cmp "$o -t rnd"     $o -t rnd
done
run_cmp "--expand-tabs"     --expand-tabs tabs
run_cmp "--expand-tabs=:3"  --expand-tabs=:3 tabs
run_cmp "--output-tabs=:4"  --output-tabs=:4 -2 tabs
run_cmp "--show-control-chars" --show-control-chars ctl
run_cmp "--show-nonprinting" --show-nonprinting ctl
run_cmp "-e0"               -e0 tabs
run_cmp "-e ''"             -e'' tabs
for w in 1 5 10 20 40 80 100 200; do
    run_cmp "-w $w rnd"     -w $w rnd
    run_cmp "-W $w rnd"     -W $w rnd
    run_cmp "-W $w -J rnd"  -W $w -J rnd
    run_cmp "-W $w -t rnd"  -W $w -t rnd
    run_cmp "-w $w -2 rnd"  -w $w -2 rnd
done
for o in 0 1 5 10 30; do
    run_cmp "-o $o"         -o $o f7
    run_cmp "-o $o -t"      -o $o -t rnd
    run_cmp "-o $o -2 -n"   -o $o -2 -n greek
done
run_cmp "-o x"              -o x f7
run_cmp "-o -1"             -o -1 f7
run_cmp "--indent=3"        --indent=3 f7
run_cmp "--across"          --across -3 greek
run_cmp "--double-space"    --double-space f7
run_cmp "--form-feed"       --form-feed f7
run_cmp "--omit-header"     --omit-header f7
run_cmp "--omit-pagination" --omit-pagination ff
run_cmp "--join-lines"      --join-lines -2 greek
run_cmp "--merge"           --merge f7 greek
run_cmp "--no-file-warnings" --no-file-warnings nofile f7
run_cmp "--separator=,"     --separator=, -2 greek
run_cmp "--width=40 -2"     --width=40 -2 greek
run_cmp "--page-width=40 -2" --page-width=40 -2 greek

printf "\n[ Form feeds ]\n"
for o in "" -t -T -f -F -l 10 "-l 10 -t" "-d" "-2" "-2 -a" "-2 -t" "-n" "-m" "-J -2"; do
    run_cmp "ff [$o]"       $o ff
    run_cmp "ff2 [$o]"      $o ff2
    run_cmp "ff ff2 [$o]"   $o ff ff2
done
printf 'a\nb\n\f' > fftail; printf '\fonly\n' > ffhead; printf '\f' > ffonly; printf '\f\n\f\n' > ffnl
for f in fftail ffhead ffonly ffnl; do
    touch -d @1700000000 $f
    for o in "" -t -T -2 -l 10; do run_cmp "$f [$o]" $o $f; done
done
printf 'x\n' > one; for i in $(seq 1 55); do printf '%s\n' "y$i"; done > l55; printf '\f' >> l55; echo tail >> l55
touch -d @1700000000 l55
run_cmp "ff after full page" l55
run_cmp "ff after full page -t" -t l55
run_cmp "ff after full -l 20" -l 20 l55

printf "\n[ Options misc ]\n"
run_cmp "bad option"        -z f7
run_cmp "-- file"           -- f7
run_cmp "no args stdin"     $DATE
run_cmp "-s alone"          -s f7
run_cmp "-sX alone"         -sX f7
run_cmp "-w and -s"         -w 30 -s -2 greek
run_cmp "-W and -s"         -W 30 -s -2 greek
run_cmp "-S and -s"         -S: -s -2 greek
run_cmp "-s and -S"         -s -S: -2 greek
run_cmp "-J alone"          -J f7
run_cmp "-J -w"             -J -w 20 -2 rnd
run_cmp "-a alone"          -a f7
run_cmp "-a -m"             -a -m f7 greek
run_cmp "-2 -m"             -2 -m f7 greek
run_cmp "-t -n"             -t -n f7
run_cmp "-d -n"             -d -n f7
run_cmp "-d -t"             -d -t f7
run_cmp "-d -2 -n"          -d -2 -n greek
run_cmp "-D with newline"   -D 'a
b' f7
run_cmp "-l 11 -d"          -l 11 -d f60
run_cmp "-l 12 -d -2"       -l 12 -d -2 f60

printf "\n[ Random option combinations ]\n"
LC_ALL=C awk 'BEGIN{srand(77); split("-a -c -d -e -f -i -J -n -r -t -T -v -m -2 -3 -4 -w40 -W50 -l15 -l12 -o3 -s -s: -S: -N5 -h X +2 +1:2 -F -e: -i:4 -n:3", opt, " "); n=34;
  for(i=0;i<250;i++){ k=1+int(rand()*4); line=""; for(j=0;j<k;j++) line=line " " opt[1+int(rand()*n)]; print line }}' > combos
while IFS= read -r combo; do
    case "$combo" in *-m*) files="f100 text200" ;; *) files="text200" ;; esac
    run_cmp "random [$combo]" $combo $files
    run_cmp "random ff [$combo]" $combo ff
done < combos

print_summary
[ "$FAIL" -eq 0 ]
