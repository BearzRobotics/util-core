#!/bin/sh
# ptx: differential tests against GNU ptx 9.7 (C locale). References: GNU manual
# "ptx invocation". User regular expressions (-S/-W) are limited to constructs
# where the project's regex engine and glibc agree.
UTIL="ptx"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
cat > t1 <<'EOT'
The quick brown fox jumps over the lazy dog.  It was a bright cold day in April, and the clocks were striking thirteen.
Winston Smith, his chin nuzzled into his breast in an effort to escape the vile wind, slipped quickly through the glass doors of Victory Mansions.
"Quoted text," he said; (and parenthetical remarks!) Then more... Really?  Yes!
EOT
printf 'one two three\nfour five six\n\nseven eight nine\n' > t2
printf 'ref1 alpha beta gamma\nref2 delta epsilon\nref3 zeta eta theta iota\n' > refs
printf 'tab\tseparated\twords\there\nand  two  spaces  there\n' > tabs
printf 'Hello, World! Hello again.\nHELLO world hello\nhello\n' > case
printf 'x' > one
: > empty
printf 'no trailing newline here' > nonl
printf '.\n\n. start\n' > odd
printf 'the\na\nof\n' > ignore
printf 'quick\nbrown\nfox\nWinston\n' > only
printf ',.;:!?()"\n' > brk
LC_ALL=C awk 'BEGIN{srand(8); for(i=0;i<60;i++){ n=1+int(rand()*14); s=""; for(j=0;j<n;j++){ l=1+int(rand()*9); w=""; for(k=0;k<l;k++) w=w sprintf("%c",97+int(rand()*26)); r=rand(); if(r<0.1) w=w "."; else if(r<0.2) w=w ","; s=s w (rand()<0.2?"  ":" ") } print s }}' > rnd

printf "\n[ Defaults ]\n"
for f in t1 t2 refs tabs case one empty nonl odd rnd; do
    run_cmp "default $f" $f
    run_cmp "-G $f"      -G $f
    run_cmp "-A $f"      -A $f
    run_cmp "-r $f"      -r $f
    run_cmp "-f $f"      -f $f
    run_cmp "-O $f"      -O $f
    run_cmp "-T $f"      -T $f
    run_cmp "-R -A $f"   -R -A $f
    run_cmp "-R -r $f"   -R -r $f
done
CMP_STDIN=t2 run_cmp "stdin"
CMP_STDIN=t2 run_cmp "stdin dash" -
CMP_STDIN=t2 run_cmp "stdin -A" -A
run_cmp "two files"       t1 t2
run_cmp "two files -A"    -A t1 t2 refs
run_cmp "-A -R two"       -A -R t2 refs
run_cmp "missing"         nofile
run_cmp "missing then ok" nofile t2
run_cmp "directory"       .
run_cmp "empty name"      ''

printf "\n[ Widths and gaps ]\n"
for w in 1 5 10 20 30 40 50 60 72 80 100 200; do
    run_cmp "-w $w t1"      -w $w t1
    run_cmp "-w $w -A t1"   -w $w -A t1
    run_cmp "-w $w -R -A rnd" -w $w -R -A rnd
    run_cmp "-w $w -G t2"   -w $w -G t2
done
for g in 1 2 3 5 10 40; do
    run_cmp "-g $g t1"      -g $g t1
    run_cmp "-g $g -w 50 t1" -g $g -w 50 t1
    run_cmp "-g $g -r refs" -g $g -r refs
done
run_cmp "-w 0"            -w 0 t1
run_cmp "-w x"            -w x t1
run_cmp "-w -5"           -w -5 t1
run_cmp "-w 0x20"         -w 0x20 t1
run_cmp "-w 040"          -w 040 t1
run_cmp "-g 0"            -g 0 t1
run_cmp "-g x"            -g x t1
run_cmp "--width=40"      --width=40 t1
run_cmp "--gap-size=4"    --gap-size=4 t1

printf "\n[ Truncation, macro names, formats ]\n"
for fl in / '...' '' '<>' '\x41' '\n' '--' '*'; do
    run_cmp "-F '$fl'"      -F "$fl" -w 30 t1
    run_cmp "-F '$fl' -O"   -F "$fl" -w 30 -O t1
    run_cmp "-F '$fl' -T"   -F "$fl" -w 30 -T t1
done
run_cmp "--flag-truncation=+" --flag-truncation=+ -w 30 t1
run_cmp "-M foo -O"       -M foo -O t2
run_cmp "-M foo -T"       -M foo -T t2
run_cmp "--macro-name=bar -O" --macro-name=bar -O t2
run_cmp "--format=roff"   --format=roff t2
run_cmp "--format=tex"    --format=tex t2
run_cmp "--format=r"      --format=r t2
run_cmp "--format=bad"    --format=bad t2
run_cmp "--format=ambig"  --format= t2
run_cmp "-O -A"           -O -A refs
run_cmp "-T -A"           -T -A refs
run_cmp "-O -r"           -O -r refs
run_cmp "-T -r"           -T -r refs
run_cmp "-O special chars" -O case
run_cmp "-T special chars" -T t1
printf 'a $b %%c &d #e _f {g} \\h "q"\n' > special
run_cmp "-T special"      -T special
run_cmp "-O special"      -O special
run_cmp "special dumb"    special
run_cmp "-G special"      -G special
run_cmp "-G -T special"   -G -T special
run_cmp "-O -T"           -O -T t2
run_cmp "-T -O"           -T -O t2
run_cmp "--traditional"   --traditional t2
run_cmp "--auto-reference" --auto-reference t2
run_cmp "--references"    --references refs
run_cmp "--right-side-refs -A" --right-side-refs -A t2
run_cmp "--ignore-case"   --ignore-case case

printf "\n[ Word lists and break files ]\n"
for f in t1 t2 case rnd; do
    run_cmp "-i ignore $f"  -i ignore $f
    run_cmp "-o only $f"    -o only $f
    run_cmp "-i -o $f"      -i ignore -o only $f
    run_cmp "-b brk $f"     -b brk $f
    run_cmp "-b -G $f"      -G -b brk $f
    run_cmp "-b -i $f"      -b brk -i ignore $f
    run_cmp "-f -i $f"      -f -i ignore $f
done
run_cmp "-i missing"      -i nofile t1
run_cmp "-o missing"      -o nofile t1
run_cmp "-b missing"      -b nofile t1
run_cmp "-i empty"        -i empty t1
run_cmp "-o empty"        -o empty t1
run_cmp "--ignore-file="  --ignore-file=ignore t1
run_cmp "--only-file="    --only-file=only t1
run_cmp "--break-file="   --break-file=brk t1
run_cmp "-b space break"  -b brk -G t2

printf "\n[ Regular expressions ]\n"
for s in '' '\n' '\.' '[.?!]' 'x' ';' ',' '[,;]' '[.]  ' '\. ' 'a' '\n\n' '[a-c]'; do
    run_cmp "-S '$s' t1"    -S "$s" t1
    run_cmp "-S '$s' rnd"   -S "$s" rnd
done
for ws in '[a-z]+' '[A-Za-z]+' '\w+' '[^ ]+' 'a' '' '[a-z]+[0-9]*' '\(ab\|cd\)'; do
    run_cmp "-W '$ws' t1"   -W "$ws" t1
    run_cmp "-W '$ws' refs" -W "$ws" refs
done
run_cmp "-W bad"          -W '[' t1
run_cmp "-S bad"          -S '[' t1
run_cmp "-S '\\'"         -S '\' t1
run_cmp "--sentence-regexp" --sentence-regexp='\.' t1
run_cmp "--word-regexp"   --word-regexp='[a-z]+' t1
run_cmp "-S newline start" -S '\n' odd
run_cmp "-S dot start"    odd
run_cmp "-W -f"           -W '[a-z]+' -f case

printf "\n[ Options ]\n"
run_cmp "-t"              -t t2
run_cmp "bad option"      -x t2
run_cmp "-G extra operand" -G t2 /dev/null extra
run_cmp "-G output file"  -G t2 outfile
run_cmp "-G output dir"   -G t2 nodir/outfile
run_cmp "ptx -- file"     -- t2
run_cmp "long abbrev"     --wid=30 t2
run_cmp "ambiguous"       --a t2
run_cmp "ambiguous 2"     --f t2

printf "\n[ Random combinations ]\n"
LC_ALL=C awk 'BEGIN{srand(31); split("-A -G -R -r -f -O -T -w40 -w25 -w100 -g1 -g6 -F... -F -M_m -i_ignore -o_only -b_brk -S._ -S;", opt, " "); n=18;
  for(i=0;i<200;i++){ k=1+int(rand()*4); line=""; for(j=0;j<k;j++){ o=opt[1+int(rand()*n)]; gsub(/_/," ",o); line=line " " o } print line }}' > combos
while IFS= read -r combo; do
    run_cmp "random [$combo]" $combo t1 refs
done < combos

print_summary
[ "$FAIL" -eq 0 ]
