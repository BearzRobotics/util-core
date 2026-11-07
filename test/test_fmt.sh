#!/bin/sh
# fmt: differential tests against GNU fmt 9.7 (C locale). References: GNU manual
# "fmt invocation". The line-breaking algorithm is deterministic, so identical
# output is required, including paragraph chunking beyond 1000 words.
UTIL="fmt"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
cat > prose <<'EOT'
The quick brown fox jumps over the lazy dog.  It was a bright cold day in April, and the clocks were striking thirteen.  Winston Smith, his chin nuzzled into his breast in an effort to escape the vile wind, slipped quickly through the glass doors of Victory Mansions.

Second paragraph here; it has semicolons, commas, and (parenthetical remarks) that may attract breaks.  "Quoted text." Another sentence?  Yes! And more.
   Indented paragraph with several words that goes on for a while so it needs to be wrapped around the line width at least twice or thrice.
   Same indent continues here on a second line.
  Different indent here.

* A bullet-like line that is rather long and should be wrapped according to the usual rules of filling text.
  continuation of the bullet line is indented by two.


Many blank lines before.
EOT
printf 'short\n' > short
printf 'no newline at the end of the file but long enough to be wrapped around the line width limit set' > nonl
printf '\tTabbed first line of a paragraph with enough text to be wrapped at the default width of seventy five columns.\n\tSecond tabbed line.\n' > tabs
printf '> quoted line one is rather long and has enough words to wrap beyond the limit\n> quoted line two\n>\n> new quoted paragraph here\nnot quoted line\n> again quoted\n' > quote
printf '# comment one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen\n  # indented comment line\n' > hash
printf 'Item: first line is the tag\n  and this is the body of the paragraph which continues on and on and on for a while\n  second body line\n\nTag two:\n   body indented three\n   more body\n' > tagged
printf 'Crown first line indent zero and long enough to wrap around the margin here\n    second line indented four spaces with some text\n    third line indented four too\n\n  Next para first two\n    next para second four\n' > crown
printf 'a  b   c    d\te.  f.   g?  h!  i)  j.)  k."  l.\n' > spaces
printf 'Sentence one.  Sentence two.  Sentence three ends here.  And a fourth one, with a comma.  Fifth?  Sixth!  Seventh.\n' > sentences
printf 'supercalifragilisticexpialidocious pneumonoultramicroscopicsilicovolcanoconiosis floccinaucinihilipilification antidisestablishmentarianism\n' > longwords
: > empty
printf '\n\n\n' > blanks
printf '   \n  x\n   \n' > spaceline
LC_ALL=C awk 'BEGIN{srand(42); for(p=0;p<40;p++){ n=1+int(rand()*60); line=""; for(i=0;i<n;i++){ l=1+int(rand()*10); w=""; for(j=0;j<l;j++) w=w sprintf("%c",97+int(rand()*26)); r=rand(); if(r<0.08) w=w "."; else if(r<0.14) w=w ","; else if(r<0.17) w="(" w; else if(r<0.19) w=w ")."; sp=(rand()<0.15)?"  ":" "; line=line w sp } print line; if(rand()<0.3) print "" }}' > rnd
LC_ALL=C awk 'BEGIN{srand(9); for(i=0;i<3000;i++){ l=1+int(rand()*9); w=""; for(j=0;j<l;j++) w=w sprintf("%c",97+int(rand()*26)); printf "%s%s", w, (rand()<0.07)?".  ":" "; if (i%40==39) printf "\n" } printf "\n"}' > huge
LC_ALL=C awk 'BEGIN{for(i=0;i<1500;i++) printf "w%d ", i; printf "\n"}' > manywords
LC_ALL=C awk 'BEGIN{for(i=0;i<700;i++) printf "word%d ", i; printf "\n"}' > bigchars
LC_ALL=C awk 'BEGIN{s=""; for(i=0;i<6000;i++) s=s "x"; print s}' > onebig

printf "\n[ Default ]\n"
for f in prose short nonl tabs quote hash tagged crown spaces sentences longwords empty blanks spaceline rnd huge manywords bigchars onebig; do
    run_cmp "default $f" $f
done
run_cmp "stdin" 
CMP_STDIN=prose run_cmp "stdin prose"
CMP_STDIN=prose run_cmp "stdin dash" -
run_cmp "two files" prose short
run_cmp "missing file" nofile
run_cmp "missing then ok" nofile short

printf "\n[ Widths ]\n"
for w in 1 5 10 20 30 40 50 60 72 75 76 80 100 200 2500; do
    run_cmp "-w $w prose"  -w $w prose
    run_cmp "-$w prose"    -$w prose
    run_cmp "-w $w rnd"    -w $w rnd
done
run_cmp "-w2501"          -w 2501 prose
run_cmp "-w abc"          -w abc prose
run_cmp "-w -5"           -w -5 prose
run_cmp "-w ''"           -w '' prose
run_cmp "--width=40"      --width=40 prose
run_cmp "--width 40"      --width 40 prose
run_cmp "-w40 attached"   -w40 prose
run_cmp "-40 not first"   prose -40
run_cmp "-w0"             -w0 prose
for g in 1 10 30 50 60 70 75; do
    run_cmp "-g $g"       -g $g prose
    run_cmp "-w 80 -g $g" -w 80 -g $g prose
    run_cmp "-g $g rnd"   -g $g rnd
done
run_cmp "-g 100"          -g 100 prose
run_cmp "-w 50 -g 60"     -w 50 -g 60 prose
run_cmp "-g abc"          -g abc prose
run_cmp "--goal=40"       --goal=40 prose

printf "\n[ Modes ]\n"
for o in -c -t -s -u -cu -tu -su -cs -ct -ts "-c -u -w 40" "-t -w 30" "-s -w 30" "-u -w 25"; do
    for f in prose tagged crown spaces sentences rnd tabs quote; do
        run_cmp "$o $f" $o $f
    done
done
run_cmp "-s long lines"   -s -w 20 longwords
run_cmp "-s -w 1 words"   -s -w 1 short
run_cmp "-s huge"         -s huge
run_cmp "-c huge"         -c huge
run_cmp "-u huge"         -u huge
run_cmp "--crown-margin"  --crown-margin crown
run_cmp "--tagged-paragraph" --tagged-paragraph tagged
run_cmp "--split-only"    --split-only prose
run_cmp "--uniform-spacing" --uniform-spacing prose

printf "\n[ Prefixes ]\n"
for p in '>' '> ' ' >' '#' '# ' '  #' '*' 'x' 'quoted' '>>'; do
    run_cmp "-p '$p' quote"   -p "$p" quote
    run_cmp "-p '$p' hash"    -p "$p" hash
    run_cmp "-p '$p' prose"   -p "$p" prose
    run_cmp "-p '$p' -w 40 quote" -p "$p" -w 40 quote
done
run_cmp "--prefix=>"      --prefix='>' quote
run_cmp "-p empty"        -p '' prose
run_cmp "-p with -c"      -p '>' -c quote
run_cmp "-p with -s"      -p '#' -s hash
run_cmp "-p with -t"      -p '>' -t quote
run_cmp "-p needs arg"    -p

printf "\n[ Options ]\n"
run_cmp "bad option"      -z prose
run_cmp "digit option not first" -c -5 prose
run_cmp "long abbrev"     --wid=30 prose
run_cmp "ambiguous"       --s prose
run_cmp "-- file"         -- prose
run_cmp "combined -cu"    -cuw30 prose
print_summary
[ "$FAIL" -eq 0 ]
