#!/bin/sh
# ls: differential tests against GNU ls 9.7 (C locale, output not a terminal).
# References: GNU manual "ls invocation", POSIX ls. Both programs list the
# same fixture directory, so owners, inodes, times and block counts compare
# byte for byte. TZ is fixed so dates are reproducible.
UTIL="ls"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
export TZ=America/New_York

mkdir -p tree/a/b tree/c tree/.hid_dir tree/empty
printf 'one\n' > tree/f1; printf 'two two\n' > tree/a/f2; printf 'three\n' > tree/a/b/f3
printf 'x' > tree/.hidden; printf 'x' > tree/c/.dot; : > tree/empty/.keep
printf 'x' > tree/f.txt; printf 'x' > tree/g.tar.gz; printf 'x' > tree/h.c; printf 'x' > tree/h.o; printf 'x' > tree/noext
printf 'x' > 'tree/with space'; printf 'x' > "tree/quo'te"; printf 'x' > 'tree/dq"uote'; printf 'x' > 'tree/back\slash'
printf 'x' > "tree/$(printf 'tab\tname')"; printf 'x' > "tree/$(printf 'new\nline')"; printf 'x' > "tree/$(printf 'ctl\001x')"
printf 'x' > "tree/$(printf 'high\351\350x')"; printf 'x' > 'tree/$dollar'; printf 'x' > 'tree/#hash'; printf 'x' > 'tree/~tilde'
printf 'x' > 'tree/semi;colon'; printf 'x' > 'tree/a&b'; printf 'x' > 'tree/qm?'; printf 'x' > 'tree/star*'; printf 'x' > 'tree/{'; printf 'x' > 'tree/='
printf 'x' > 'tree/file~'; printf 'x' > 'tree/.hid~'; printf 'x' > 'tree/v1.2'; printf 'x' > 'tree/v1.10'; printf 'x' > 'tree/v1.9'
printf 'x' > 'tree/A'; printf 'x' > 'tree/b'; printf 'x' > 'tree/B'; printf 'x' > 'tree/a1'; printf 'x' > 'tree/a10'; printf 'x' > 'tree/a2'
printf 'x' > "tree/$(printf 'a%.0s' $(seq 60))"
ln -s f1 tree/lnk; ln -s nowhere tree/dangling; ln -s a tree/dlnk; ln -s 'with space' tree/lsp; ln -s lnk tree/chain; ln -s "$W/tree/a" tree/abs
mkfifo tree/fifo; ln tree/f1 tree/hard; printf 'x' > tree/exec; chmod 755 tree/exec
printf 'x' > tree/suid; chmod 4755 tree/suid; printf 'x' > tree/sgid; chmod 2755 tree/sgid
mkdir tree/sticky tree/ow tree/stow; chmod 1755 tree/sticky; chmod 777 tree/ow; chmod 1777 tree/stow
head -c 5000 /dev/zero > tree/big; head -c 1234567 /dev/zero > tree/huge; : > tree/zero
python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind('tree/sock')" 2>/dev/null || true
touch -d '2001-02-03 04:05:06' tree/f1 tree/hard; touch -d '2020-06-07 08:09:10.5' tree/a tree/c
touch -d '1 hour ago' tree/f.txt tree/big; touch -d '3 days ago' tree/h.c; touch -d '2 years ago' tree/h.o
touch -d '1970-01-01 00:00:00' tree/zero; touch -d '2 years' tree/noext; touch -d '@4102444800' tree/huge
touch -d '20 days ago' tree/g.tar.gz; touch -h -d '2005-05-05 05:05' tree/lnk
sleep 0.05; for i in 1 2; do for f in tree/lnk tree/dangling tree/dlnk tree/chain tree/lsp tree/abs; do readlink "$f" > /dev/null; done; sleep 0.05; done
mkdir -p 'co:lon' 'sp ace'; printf x > 'co:lon/f:x'; printf x > 'sp ace/f g'
mkdir -p loop/sub; ln -s ../../loop loop/sub/back
cp -a tree plain; find plain -type l -delete
N=tree

printf "\n[ Basic ]\n"
run_cmp "no args"
run_cmp "dir"                 $N
for o in -a -A -1 -l -F -p -i -s -S -t -u -c -U -v -X -r -R -d -m -x -C -h --si -k -n -g -o -G -q -b -N -Q -f -B -H -L -Z --author --file-type --group-directories-first --zero -T4 --full-time; do
    run_cmp "$o"              $o $N
    run_cmp "$o -l"           $o -l $N
done
run_cmp "missing"             nosuch
run_cmp "missing and dir"     nosuch $N/a
run_cmp "file arg"            $N/f1
run_cmp "files and dir"       $N/f1 $N/a $N/f.txt
run_cmp "file+dir -l"         -l $N/f1 $N/a $N/f.txt
run_cmp "dir arg -d"          -d $N $N/a
run_cmp "dir arg -ld"         -ld $N $N/a $N/f1
run_cmp "dot"                 -a .
run_cmp "dotdot"              -a ..
run_cmp "dot trailing slash"  $N/
run_cmp "dot double slash"    $N//a
run_cmp "empty name"          ""
run_cmp "dash dash"           -- $N/f1
run_cmp "dash name"           -- -x
run_cmp "slash"               -d /
run_cmp "dev null"            -l /dev/null /dev/zero /dev/tty
run_cmp "proc self"           -d /proc/self
run_cmp "-l /dev"             -l /dev/null /dev/full /dev/random /dev/urandom /dev/console

printf "\n[ Sorting ]\n"
for o in "" -r -t -tr -S -Sr -X -Xr -v -vr -U -c -ct -ctr -u -ut -utr -lt -ltr -lc -lu -lct -lut --sort=name --sort=size --sort=time --sort=version --sort=extension --sort=width --sort=none "-r --sort=width" --sort=n --sort=s --sort=t --sort=v --sort=e --sort=w --time=atime --time=ctime --time=mtime --time=birth "-t --time=birth" "-lt --time=atime" "-lt --time=ctime" --time=use --time=status --time=access --time=modification --time=creation --group-directories-first "-r --group-directories-first" "-t --group-directories-first" "-S --group-directories-first" "-v --group-directories-first" "-X --group-directories-first"; do
    # Reading a symlink changes its access time here, so atime sorts use a
    # copy of the tree without symlinks.
    case "$o" in *u*|*atime*|*access*|*use*) D=plain ;; *) D=$N ;; esac
    run_cmp "sort $o"         $o -1 $D
    run_cmp "sort $o -l"      $o -l $D
done
run_cmp "sort bad"            --sort=bogus $N
run_cmp "sort empty"          --sort= $N
run_cmp "sort amb"            --sort=n $N
run_cmp "time bad"            --time=bogus $N
run_cmp "time amb"            --time=a $N

printf "\n[ Format ]\n"
for w in 0 1 5 10 20 33 40 60 80 100 200; do
    for o in -C -x -m -1 -l; do
        run_cmp "$o -w $w"    $o -w $w $N
        run_cmp "$o -w $w -F" $o -w $w -F $N
        run_cmp "$o -w $w -is" $o -w $w -is $N
    done
done
run_cmp "--format=across"     --format=across -w 50 $N
run_cmp "--format=horizontal" --format=horizontal -w 50 $N
run_cmp "--format=vertical"   --format=vertical -w 50 $N
run_cmp "--format=commas"     --format=commas -w 50 $N
run_cmp "--format=long"       --format=long $N
run_cmp "--format=verbose"    --format=verbose $N
run_cmp "--format=single"     --format=single-column $N
run_cmp "--format=bad"        --format=bogus $N
run_cmp "--format amb"        --format=v $N
run_cmp "-w bad"              -w abc $N
run_cmp "-w neg"              -w -1 $N
run_cmp "-w huge"             -w 99999999999999999999999 -C $N
run_cmp "-w hex"              -w 0x28 -C $N
run_cmp "-w oct"              -w 050 -C $N
run_cmp "-w space"            -w ' 40' -C $N
run_cmp "-w empty"            -w '' $N
run_cmp "-T bad"              -T abc -C $N
run_cmp "-T neg"              -T -1 -C $N
run_cmp "-T huge"             -T 99999999999999999999999 -C $N
run_cmp "-T 0"                -T 0 -C -w 50 $N
run_cmp "-T 3"                -T 3 -C -w 50 $N
run_cmp "-T 16"               -T 16 -x -w 80 $N
run_cmp "-T suffix"           -T 1k -C $N
COLUMNS=30 run_cmp "COLUMNS=30 -C"    -C $N
COLUMNS=junk run_cmp "COLUMNS junk"   -C $N
COLUMNS=0 run_cmp "COLUMNS=0"         -C $N
COLUMNS=50 run_cmp "COLUMNS=50 -x"    -x $N
COLUMNS=50 run_cmp "COLUMNS=50 -m"    -m $N
COLUMNS=50 run_cmp "-w beats COLUMNS" -w 20 -C $N
TABSIZE=4 run_cmp "TABSIZE=4"         -C -w 50 $N
TABSIZE=junk run_cmp "TABSIZE junk"   -C -w 50 $N
TABSIZE=0 run_cmp "TABSIZE=0"         -C -w 50 $N
run_cmp "-1l"                 -1 -l $N
run_cmp "-l1"                 -l -1 $N
run_cmp "-C then -1"          -C -1 $N
run_cmp "-m -1"               -m -1 $N
run_cmp "-x -l"               -x -l $N

printf "\n[ Long format fields ]\n"
for o in -l -lh "-l --si" -lk -ln -lg -lo -lG -lgo -lgG -loG -li -ls -lis -lsh "-l --author" -lZ "-l --block-size=K" "-l --block-size=M" "-l --block-size=1" "-l --block-size=1000" "-l --block-size=KB" "-l --block-size=KiB" "-l --block-size=3" "-l --block-size=0x10" "-l --block-size='1" "-l --block-size=human-readable" "-l --block-size=si" "-l --block-size=s" "-ls --block-size=1K" -lsk "-ls -k --si" "-ls --block-size=2K" "-lsh --block-size=1M"; do
    run_cmp "$o"              $o $N
    run_cmp "$o /dev"         $o /dev/null /dev/zero $N/f1 $N/lnk $N/dangling
done
for e in LS_BLOCK_SIZE BLOCK_SIZE BLOCKSIZE; do
    for v in 1 1K 1M 4096 human-readable si 1KB zz 0 ''; do
        eval "$e='$v' run_cmp '$e=$v -ls' -ls $N"
    done
done
POSIXLY_CORRECT=1 run_cmp "POSIXLY_CORRECT -s"  -s $N
POSIXLY_CORRECT=1 run_cmp "POSIXLY_CORRECT -ls" -ls $N
run_cmp "-lh sizes"           -lh $N/big $N/huge $N/zero $N/f1
run_cmp "-l --si sizes"       -l --si $N/big $N/huge $N/zero $N/f1
run_cmp "-l blocksize bad"    -l --block-size=zz $N
run_cmp "-l blocksize bad2"   -l --block-size=1x $N
run_cmp "-l blocksize empty"  -l --block-size= $N
run_cmp "-l blocksize neg"    -l --block-size=-5 $N
run_cmp "-l blocksize zero"   -l --block-size=0 $N
run_cmp "-l blocksize big"    -l --block-size=99999999999999999999999 $N
run_cmp "-l blocksize 1Y"     -l --block-size=1Y $N
run_cmp "-l blocksize 1E"     -ls --block-size=1E $N
run_cmp "-l blocksize amb"    -l --block-size=h $N
run_cmp "-l blocksize G"      -ls --block-size=G $N
run_cmp "-l blocksize T"      -ls --block-size=T $N
run_cmp "-lk bs"              -ls -k $N

printf "\n[ Times ]\n"
for s in full-iso long-iso iso locale posix-iso posix-full-iso posix-long-iso posix-locale '+%Y' '+%H:%M:%S.%N' '+%a %A %b %B %c' '+recent
old' '+%s' '+' '+%%' '+%5Y' '+%-d' '+%Ez' '+%:z' 'bogus' 'lo' 'l' 'f' 'i' '' 'posix-' 'posix-bogus' 'iso
bad'; do
    run_cmp "time-style '$s'"   -l --time-style="$s" $N
    run_cmp "time-style '$s' -t" -lt --time-style="$s" $N/f1 $N/h.c $N/zero $N/huge
done
for t in mtime atime ctime birth; do
    # Symlinks are left out: reading them updates their access time here.
    run_cmp "--time=$t"       -l --time=$t $N/f1 $N/f.txt $N/h.* $N/zero $N/big $N/huge $N/a $N/fifo
    run_cmp "--time=$t full"  -l --time=$t --full-time $N/f1 $N/f.txt $N/h.* $N/zero $N/big $N/huge $N/a $N/fifo
done
run_cmp "--full-time"         --full-time $N
run_cmp "--full-time -1"      --full-time -1 $N
run_cmp "--full-time -C"      --full-time -C $N
TIME_STYLE=long-iso run_cmp "TIME_STYLE env"        -l $N
TIME_STYLE=iso run_cmp "TIME_STYLE=iso"             -l $N
TIME_STYLE=full-iso run_cmp "TIME_STYLE full"       -l $N
TIME_STYLE=bogus run_cmp "TIME_STYLE bogus"         -l $N
TIME_STYLE=bogus run_cmp "TIME_STYLE bogus no -l"   $N
TIME_STYLE=iso run_cmp "style option beats env"     -l --time-style=long-iso $N
TIME_STYLE=iso run_cmp "-l --full-time beats env"   -l --full-time $N
for z in UTC Europe/London Asia/Kolkata Australia/Lord_Howe America/St_Johns Pacific/Kiritimati; do
    TZ=$z run_cmp "TZ=$z"                 -l $N/f1 $N/h.c $N/f.txt $N/noext
    TZ=$z run_cmp "TZ=$z full"            --full-time $N/f1 $N/h.c $N/f.txt $N/huge $N/zero
done
TZ=EST5EDT run_cmp "TZ posix"             -l $N/f1 $N/h.c
TZ=bogus run_cmp "TZ bogus"               -l $N/f1 $N/h.c
TZ= run_cmp "TZ empty"                    -l $N/f1 $N/h.c

printf "\n[ Quoting ]\n"
for q in literal shell shell-always shell-escape shell-escape-always c c-maybe escape locale clocale; do
    run_cmp "--quoting-style=$q"         --quoting-style=$q $N
    run_cmp "--quoting-style=$q -l"      --quoting-style=$q -l $N
    run_cmp "--quoting-style=$q -C"      --quoting-style=$q -C -w 70 $N
    run_cmp "--quoting-style=$q -x"      --quoting-style=$q -x -w 70 $N
    run_cmp "--quoting-style=$q -m"      --quoting-style=$q -m -w 70 $N
    run_cmp "--quoting-style=$q -F"      --quoting-style=$q -F -C -w 70 $N
    run_cmp "--quoting-style=$q -R"      --quoting-style=$q -R $N/a
    QUOTING_STYLE=$q run_cmp "QUOTING_STYLE=$q"   $N
    QUOTING_STYLE=$q run_cmp "QUOTING_STYLE=$q -C" -C -w 70 $N
done
run_cmp "--quoting-style bad"  --quoting-style=bogus $N
run_cmp "--quoting-style amb"  --quoting-style=c- $N
run_cmp "--quoting-style abbrev" --quoting-style=shell-e $N
run_cmp "--quoting-style sh"   --quoting-style=sh $N
run_cmp "--quoting-style loc"  --quoting-style=loc $N
QUOTING_STYLE=bogus run_cmp "QUOTING_STYLE bogus" $N
QUOTING_STYLE=c run_cmp "env c, -N wins"     -N $N
QUOTING_STYLE=c run_cmp "env c, opt wins"    --quoting-style=shell $N
run_cmp "-Q -N"               -Q -N $N
run_cmp "-N -Q"               -N -Q $N
run_cmp "-b -Q"               -b -Q $N
run_cmp "-q"                  -q $N
run_cmp "-q -Q"               -q -Q $N
run_cmp "-q --quoting-style=shell" -q --quoting-style=shell $N
run_cmp "-q --quoting-style=shell-always" -q --quoting-style=shell-always $N
run_cmp "-q --quoting-style=c" -q --quoting-style=c $N
run_cmp "-q -b"               -q -b $N
run_cmp "--show-control-chars" --show-control-chars $N
run_cmp "-q --show-control-chars" -q --show-control-chars $N
run_cmp "--show-control-chars -q" --show-control-chars -q $N
run_cmp "--hide-control-chars" --hide-control-chars $N
run_cmp "-q -l"               -q -l $N
run_cmp "-q -C"               -q -C -w 60 $N
run_cmp "-l symlink quoting"  -l --quoting-style=shell-escape $N/lsp $N/chain $N/lnk
run_cmp "-lF symlink"         -lF $N/lsp $N/chain $N/lnk $N/dlnk $N/dangling $N/abs
run_cmp "-l -Q symlink"       -lQ $N/lsp $N/chain $N/lnk
run_cmp "dir headers quoted"  -R $N
run_cmp "dir headers -Q"      -RQ $N
run_cmp "dir headers shell"   -R --quoting-style=shell $N
run_cmp "colon dir"           -R 'co:lon' 'sp ace'
run_cmp "colon dir -Q"        -RQ 'co:lon' 'sp ace'
run_cmp "colon dir -b"        -Rb 'co:lon' 'sp ace'
run_cmp "colon dir shell"     -R --quoting-style=shell 'co:lon' 'sp ace'

printf "\n[ Indicators ]\n"
for s in none slash file-type classify; do
    run_cmp "--indicator-style=$s"       --indicator-style=$s $N
    run_cmp "--indicator-style=$s -l"    --indicator-style=$s -l $N
    run_cmp "--indicator-style=$s -C"    --indicator-style=$s -C -w 60 $N
    run_cmp "--indicator-style=$s -Q"    --indicator-style=$s -Q $N
    run_cmp "--indicator-style=$s -b"    --indicator-style=$s -b $N
    run_cmp "--indicator-style=$s -m"    --indicator-style=$s -m $N
done
run_cmp "--indicator-style bad"  --indicator-style=bogus $N
run_cmp "--indicator-style amb"  --indicator-style=s $N
run_cmp "--indicator-style f"    --indicator-style=f $N
for w in always yes force never no none auto tty if-tty; do
    run_cmp "--classify=$w"      --classify=$w $N
    run_cmp "--color=$w"         --color=$w $N
    run_cmp "--hyperlink=$w"     --hyperlink=$w $N/f1
done
run_cmp "--classify"          --classify $N
run_cmp "--classify=bad"      --classify=bogus $N
run_cmp "--color=bad"         --color=bogus $N
run_cmp "--hyperlink=bad"     --hyperlink=bogus $N
run_cmp "--color=a"           --color=a $N
run_cmp "-F -p"               -F -p $N
run_cmp "-p -F"               -p -F $N
run_cmp "-pF -d"              -pFd $N $N/f1 $N/lnk $N/dlnk

printf "\n[ Ignore, hide, recursion ]\n"
for o in "--ignore=*.txt" "-I *.o" "-I *.o -I *.c" "--hide=*.txt" "--hide=*.txt -a" "--hide=*.txt -A" "-I .* -a" "-I .* -A" "-B" "-aB" "-AB" "-I *" "-I [a-c]*" "-I [!a-c]*" "-I ?" "-I a?" "-I \\*" "-I [[:upper:]]*" "-I [[:digit:]]" "-I *[[:punct:]]*" "-I ." "-I .." "-a -I ." "-a -I .." "-A -I ." "--hide=. -a" "--hide=.* -A" "--ignore=" "--hide=" "--ignore=a --ignore=b -a" "-a -I .?*" "-I [" "-I [a" "-I a[" "-I []" "-I [!]" "-I [a-]" "-I [z-a]*"; do
    run_cmp "$o"  $o -1 $N
done
run_cmp "-R"                  -R $N
run_cmp "-Ra"                 -Ra $N
run_cmp "-RA"                 -RA $N
run_cmp "-Rl"                 -Rl $N
run_cmp "-Rd"                 -Rd $N
run_cmp "-R file arg"         -R $N/f1 $N/a
run_cmp "-R multiple"         -R $N/a $N/c
run_cmp "-R -t"               -Rt $N
run_cmp "-R -S"               -RS $N
run_cmp "-R -r"               -Rr $N
run_cmp "-R -F"               -RF $N
run_cmp "-R -i"               -Ri $N
run_cmp "-R -s"               -Rs $N
run_cmp "-R symlink dir"      -R $N/dlnk
run_cmp "-RL"                 -RL $N/a
run_cmp "-RH"                 -RH $N/dlnk
run_cmp "-R dot"              -R .
run_cmp "-R -C"               -RC -w 40 $N
run_cmp "-R empty dir"        -R $N/empty
run_cmp "-Ra empty dir"       -Ra $N/empty
run_cmp "-RL loop"            -RL loop
run_cmp "-RL loop -l"         -RLl loop

printf "\n[ Dereference ]\n"
for o in -l -H -L -d -ld -Hl -Ll -HL -LH -F -lF -Fd --dereference-command-line --dereference-command-line-symlink-to-dir "-ld --dereference-command-line-symlink-to-dir" "-l --dereference-command-line-symlink-to-dir" "-d --dereference-command-line-symlink-to-dir" --dereference -lL -Lt -LS -LF -LC -li -Li; do
    run_cmp "$o links"        $o $N/lnk $N/dlnk $N/dangling $N/chain $N/abs
    run_cmp "$o dir"          $o $N/dlnk/
done
run_cmp "-L dir"              -L $N
run_cmp "-H dir"              -H $N
run_cmp "-lL dir"             -lL $N
run_cmp "-lL dir sizes"       -lLh $N

printf "\n[ Errors and options ]\n"
run_cmp "bad option"          -z
run_cmp "bad long option"     --bogus
run_cmp "amb long option"     --co
run_cmp "amb long option2"    --h
run_cmp "long opt arg"        --all=1
run_cmp "missing arg"         -w
run_cmp "missing long arg"    --width
run_cmp "-I missing"          -I
run_cmp "--dired --zero"      --dired --zero $N
run_cmp "--zero --dired"      --zero --dired $N
run_cmp "unreadable dir"      /root
run_cmp "unreadable file"     /root/x
run_cmp "perm denied"         -l /proc/1/fd
run_cmp "name too long"       "$(printf 'a%.0s' $(seq 5000))"
run_cmp "not dir"             $N/f1/x
run_cmp "loop symlink"        loop/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/sub/back/x
run_cmp "--author"            -l --author $N
run_cmp "--context"           --context $N
run_cmp "-Z -l"               -Zl $N
run_cmp "-Z"                  -Z $N

printf "\n[ Dired, zero, hyperlink, colors ]\n"
run_cmp "--dired"             --dired $N
run_cmp "-D"                  -D $N
run_cmp "-D -R"               -DR $N
run_cmp "-D dirs"             -D $N/a $N/c
run_cmp "-D file"             -D $N/f1
run_cmp "-D quoted"           -D -Q $N
run_cmp "-D escape"           -D -b $N
run_cmp "-D shell"            -D --quoting-style=shell $N
run_cmp "-D -N"               -D -N $N
run_cmp "-D hyperlink"        -D --hyperlink=always $N
run_cmp "--zero"              --zero $N
run_cmp "--zero -l"           --zero -l $N
run_cmp "--zero -C"           --zero -C $N
run_cmp "--zero -m"           --zero -m $N
run_cmp "--zero -x"           --zero -x $N
run_cmp "--zero -R"           --zero -R $N
run_cmp "--zero --color"      --zero --color=always $N
run_cmp "--zero -Q"           --zero -Q $N
run_cmp "--hyperlink f"       --hyperlink=always $N/f1 $N/lnk "$N/with space"
run_cmp "--hyperlink -l"      --hyperlink=always -l $N
run_cmp "--hyperlink -C"      --hyperlink=always -C -w 60 $N
run_cmp "--hyperlink -R"      --hyperlink=always -R $N/a
run_cmp "--hyperlink -Q"      --hyperlink=always -Q $N
run_cmp "--hyperlink --quoting-style=shell" --hyperlink=always --quoting-style=shell $N
run_cmp "--hyperlink -l shell" --hyperlink=always -l --quoting-style=shell $N
run_cmp "--hyperlink rel"     --hyperlink=always $N/../tree/f1

run_cmp "--color=always"      --color=always $N
run_cmp "--color=always -l"   --color=always -l $N
run_cmp "--color=always -C"   --color=always -C -w 60 $N
run_cmp "--color=always -x"   --color=always -x -w 60 $N
run_cmp "--color=always -m"   --color=always -m -w 60 $N
run_cmp "--color=always -F"   --color=always -F $N
run_cmp "--color=always -lF"  --color=always -lF $N
run_cmp "--color=always -R"   --color=always -R $N
run_cmp "--color=always -Q"   --color=always -Q $N
run_cmp "--color=always -i"   --color=always -is $N
run_cmp "--color=always -lL"  --color=always -lL $N
run_cmp "--color=always -d"   --color=always -d $N $N/lnk
run_cmp "--color=always file" --color=always $N/f1 $N/exec $N/lnk $N/dangling $N/g.tar.gz $N/sock
run_cmp "--color=always -t"   --color=always -t $N
run_cmp "--color=always -C 1" --color=always -C -w 1 $N
run_cmp "--color=always -C 7" --color=always -C -w 7 $N
run_cmp "--color=always --group-dirs" --color=always --group-directories-first $N
LS_COLORS= run_cmp "LS_COLORS empty"    --color=always $N
for lsc in 'di=01;31' 'di=' 'no=7' 'fi=1;32' 'ln=target' 'ln=target:or=1;31' 'or=40;31;01' 'mi=01;05;37;41' 'ex=1;32:*.txt=4' '*.txt=4:*.TXT=5' '*.txt=4:*.txt=5' '*.txt=4:*.TXT=4' '*.gz=1;31:*.tar.gz=1;32' '*.c=7:*.o=8:*.TAR=9' 'su=37;41:sg=30;43:tw=30;42:ow=34;42:st=37;44' 'ow=:tw=:st=' 'pi=33:so=01;35:bd=01;33:cd=01;33' 'rs=0' 'rs=1' 'lc=\e[:rc=m' 'lc=<:rc=>' 'ec=\e[0m' 'ec=' 'lc=:rc=' 'cl=\e[K' 'cl=' 'mh=44' 'ca=1' 'fi=\x41\102\n' 'di=^A^?^[' 'di=\_\a\b\e\f\n\r\t\v\?\\\^\=\:' 'junk' 'di' 'di=1:zz=3' 'di=1:' ':di=1' '::' '*' '*=' '*.c' '*.c:' 'di=01;34:*.c=\' 'di=\x' 'di=\400' 'di=^' 'di=^a' 'di=^~' '*.c=1:di=^!'; do
    LS_COLORS="$lsc" run_cmp "LS_COLORS='$lsc'"     --color=always $N
    LS_COLORS="$lsc" run_cmp "LS_COLORS='$lsc' -lF" --color=always -lF $N
done
unset LS_COLORS
LS_COLORS='' COLORTERM=1 run_cmp "COLORTERM"     --color=always $N
LS_COLORS='' TERM=dumb COLORTERM= run_cmp "TERM=dumb" --color=always $N
for t in xterm xterm-256color linux vt100 vt220 screen tmux-256color rxvt-unicode Eterm ansi dumb unknown st st-256color con80x25 cons25 foocolorbar '' none; do
    LS_COLORS='' COLORTERM= TERM="$t" run_cmp "TERM=$t"    --color=always $N
    LS_COLORS='' COLORTERM= TERM="$t" run_cmp "TERM=$t auto" --color=auto $N
done
LS_COLORS='' COLORTERM= TERM= run_cmp "TERM unset" --color=always $N
LS_COLORS='*.c=7:di=1' run_cmp "ext + color -l -T"  --color=always -l -T 8 $N
NO_COLOR=1 run_cmp "NO_COLOR ignored"       --color=always $N

printf "\n[ Misc options ]\n"
run_cmp "-a -A"               -a -A $N
run_cmp "-A -a"               -A -a $N
run_cmp "-f"                  -f $N/a
run_cmp "-f -l"               -fl $N/a
run_cmp "-fl order"           -lf $N/a
run_cmp "-U -S"               -U -S $N
run_cmp "-S -U"               -S -U $N
run_cmp "-t -S"               -t -S $N
run_cmp "-c -u"               -lcu $N
run_cmp "-u -c"               -luc $N
run_cmp "-ct"                 -ct $N
run_cmp "-ut"                 -ut $N
run_cmp "-c -l -t"            -clt $N
run_cmp "-h -k"               -lhk $N
run_cmp "-k -h"               -lkh $N
run_cmp "-k --si"             -lk --si $N
run_cmp "--si -k"             -l --si -k $N
run_cmp "-s -h"               -sh $N
run_cmp "-s total"            -s $N/a
run_cmp "-s files"            -s $N/f1 $N/big $N/huge
run_cmp "-i files"            -i $N/f1 $N/hard $N/lnk
run_cmp "-L -i"               -iL $N/f1 $N/lnk
run_cmp "-d"                  -d
run_cmp "-d *"                -d $N/*
run_cmp "-ld *"               -ld $N/*
run_cmp "-l *"                -l $N/a $N/c $N/f*
run_cmp "-R on files only"    -R $N/f1 $N/f.txt
run_cmp "1 arg dir no header" $N/a
run_cmp "2 args header"       $N/a $N/c
run_cmp "1 arg file + dir"    $N/f1 $N/a
run_cmp "dup args"            $N/f1 $N/f1
run_cmp "dup dirs"            $N/a $N/a
run_cmp "dup dirs -R"         -R $N/a $N/a
run_cmp "empty dir"           $N/empty
run_cmp "empty dir -l"        -l $N/empty
run_cmp "empty dir -a"        -a $N/empty
run_cmp "empty dir -s"        -s $N/empty
run_cmp "-U many"             -U $N
run_cmp "-U -1 -s"            -U1s $N
run_cmp "-U -1 -R"            -U1R $N/a
run_cmp "-U -1"               -U1 $N
run_cmp "-f -1"               -f1 $N
run_cmp "-w 0 -m"             -m -w 0 $N
run_cmp "-m width tiny"       -m -w 1 $N
run_cmp "-m -s"               -ms $N
run_cmp "-m -i"               -mi $N
run_cmp "-m -F"               -mF $N
run_cmp "-x -s"               -xs -w 50 $N
run_cmp "-C -i -s"            -Cis -w 50 $N
run_cmp "-C -s -h"            -Csh -w 50 $N

printf "\n[ Terminal output (script) ]\n"
if command -v script >/dev/null 2>&1; then
    run_tty() {
        desc="$1"; shift
        exp=$(script -qec "stty cols ${TTY_COLS:-70}; LC_ALL=C /usr/bin/ls $*" /dev/null 2>&1)
        act=$(script -qec "stty cols ${TTY_COLS:-70}; LC_ALL=C $BIN_DIR/ls $*" /dev/null 2>&1)
        if [ "$exp" = "$act" ]; then PASS=$((PASS+1)); printf "PASS tty %s\n" "$desc"; else FAIL=$((FAIL+1)); printf "FAIL tty %s\n" "$desc"; fi
    }
    for cols in 20 40 70 120; do
        TTY_COLS=$cols
        run_tty "default $cols" $N
        run_tty "-a $cols" -a $N
        run_tty "-F $cols" -F $N
        run_tty "--color=auto $cols" --color=auto $N
        run_tty "--color=always $cols" --color=always $N
        run_tty "-x $cols" -x $N
        run_tty "-m $cols" -m $N
        run_tty "-l $cols" -l $N
        run_tty "-1 $cols" -1 $N
        run_tty "-Q $cols" -Q $N
        run_tty "-N $cols" -N $N
        run_tty "-b $cols" -b $N
        run_tty "--show-control-chars $cols" --show-control-chars $N
        run_tty "-q $cols" -q $N
        run_tty "-R $cols" -R $N/a
        run_tty "-s $cols" -s $N
        run_tty "-w 30 $cols" -w 30 $N
        run_tty "file args $cols" $N/f1 $N/with\\ space $N/lnk
        run_tty "--classify=auto $cols" --classify=auto $N
        run_tty "--hyperlink=auto $cols" --hyperlink=auto $N/f1
    done
    unset TTY_COLS
fi

for d in dir vdir; do
    for o in "" -a -l -1 -C -R -F -s -b -Q -N --quoting-style=shell -m -x --color=always "-w 30"; do
        exp=$(LC_ALL=C /usr/bin/$d $o $N 2>&1 | sed "s#^[^ ]*/$d: #$d: #"); act=$("$BIN_DIR/$d" $o $N 2>&1 | sed "s#^[^ ]*/$d: #$d: #")
        if [ "$exp" = "$act" ]; then PASS=$((PASS+1)); printf "PASS %s %s\n" "$d" "$o"; else FAIL=$((FAIL+1)); printf "FAIL %s %s\n" "$d" "$o"; fi
    done
done

cd /; print_summary
