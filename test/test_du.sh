#!/bin/sh
# du: differential tests against GNU du 9.7 (C locale). References: GNU
# manual "du invocation", POSIX du. Both programs measure the same fixture.
UTIL="du"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
export TZ=America/New_York
mkdir -p t/a/b/c t/d t/empty "t/with space" t/.hid
printf 'one\n' > t/f1; head -c 100000 /dev/zero > t/a/big; head -c 5000 /dev/urandom > t/a/b/rnd; : > t/zero
printf x > t/a/b/c/deep; printf x > "t/with space/f g"; printf x > t/.hid/h; printf x > t/d/e.log; printf x > t/d/e.txt
ln t/f1 t/hard1; ln t/f1 t/a/hard2; ln -s f1 t/lnk; ln -s a t/dlnk; ln -s nowhere t/dang; ln -s .. t/a/b/up
truncate -s 10M t/sparse; printf data >> t/sparse
mkdir t/noperm; printf x > t/noperm/x; chmod 000 t/noperm
touch -d '2001-02-03 04:05:06' t/f1 t/a; touch -d '2020-06-07 08:09:10.5' t/a/big t/d; touch -d '2030-01-01' t/zero
N=t

printf "\n[ Basic ]\n"
run_cmp "no args"
run_cmp "dir"               $N
for o in -a -s -h --si -b -k -m -c -l -S -x -L -P -H -D -0 --apparent-size --inodes -ah -sh -ch -cs -ab -bh -hS -aS "-d 0" "-d 1" "-d 2" "-d 10" -d1a --max-depth=1 --max-depth=0 --summarize --all --total --human-readable --bytes --count-links --separate-dirs --one-file-system --dereference --no-dereference --dereference-args --null "-B 1K" "-B 1M" "-B 1000" "-B KB" "-B KiB" "-B human-readable" "-B si" "-B 4096" "-B 3" --block-size=K --block-size=G "-t 1K" "-t 100K" "-t -1K" "-t 5000" "-t -5000" --threshold=1 --threshold=-1 "-t 0" "-t 1M" "-t 1T" "-t 1Q"; do
    run_cmp "$o"            $o $N
    run_cmp "$o files"      $o $N/f1 $N/a $N/hard1 $N/lnk $N/zero
done

printf "\n[ Links and arguments ]\n"
run_cmp "hard links"        $N/f1 $N/hard1 $N/a/hard2
run_cmp "hard links -l"     -l $N/f1 $N/hard1 $N/a/hard2
run_cmp "hard links -c"     -c $N/f1 $N/hard1
run_cmp "hard links -a"     -a $N
run_cmp "hard links -al"    -al $N
run_cmp "same arg twice"    $N $N
run_cmp "overlap args"      $N $N/a $N/a/b
run_cmp "overlap args rev"  $N/a/b $N/a $N
run_cmp "overlap args -c"   -c $N/a $N
run_cmp "overlap args -l"   -l $N $N/a
run_cmp "symlink arg"       $N/lnk
run_cmp "symlink arg -L"    -L $N/lnk
run_cmp "symlink arg -H"    -H $N/lnk $N/dlnk
run_cmp "symlink arg -D"    -D $N/lnk $N/dlnk
run_cmp "symlink dir arg"   $N/dlnk
run_cmp "symlink dir arg/"  $N/dlnk/
run_cmp "symlink dir -L"    -L $N/dlnk
run_cmp "dangling"          $N/dang
run_cmp "dangling -L"       -L $N/dang
run_cmp "dangling -H"       -H $N/dang
run_cmp "-L cycle"          -L $N/a
run_cmp "-L tree"           -L $N
run_cmp "-LS tree"          -LS $N
run_cmp "-P cycle"          -P $N/a
run_cmp "missing"           nosuch
run_cmp "missing and ok"    nosuch $N/f1
run_cmp "unreadable"        $N/noperm
run_cmp "unreadable tree"   $N
run_cmp "unreadable -s"     -s $N
run_cmp "unreadable -a"     -a $N/noperm
run_cmp "empty name"        ""
run_cmp "empty and ok"      "" $N/f1
run_cmp "dash"              -- $N/f1
run_cmp "trailing slash"    $N/
run_cmp "double slash"      $N//a
run_cmp "dot"               $N/./a
run_cmp "dotdot"            $N/a/..
run_cmp "root only"         -sx /proc/self
run_cmp "sparse"            -a $N/sparse
run_cmp "sparse apparent"   -a --apparent-size $N/sparse
run_cmp "sparse -b"         -ab $N/sparse
run_cmp "sparse inodes"     --inodes $N/sparse

printf "\n[ Depth, summarize, threshold ]\n"
run_cmp "-d x"              -d x $N
run_cmp "-d empty"          -d '' $N
run_cmp "-d -1"             -d -1 $N
run_cmp "-d 1 -a"           -d 1 -a $N
run_cmp "-d huge"           -d 99999999999999999999 $N
run_cmp "-s -d 0"           -s -d 0 $N
run_cmp "-s -d 1"           -s -d 1 $N
run_cmp "-s -a"             -s -a $N
run_cmp "-sc"               -sc $N $N/a
run_cmp "-sd-1"             -sd-1 $N
run_cmp "-t bad"            -t zz $N
run_cmp "-t -0"             -t -0 $N
run_cmp "-t huge"           -t 99999999999999999999999 $N
run_cmp "-t 1x"             -t 1x $N
run_cmp "-t empty"          -t '' $N
run_cmp "-B bad"            -B zz $N
run_cmp "-B 1x"             -B 1x $N
run_cmp "-B empty"          -B '' $N
run_cmp "-B 0"              -B 0 $N
run_cmp "--block-size bad"  --block-size=zz $N
run_cmp "--threshold bad"   --threshold=zz $N
DU_BLOCK_SIZE=1M run_cmp "DU_BLOCK_SIZE=1M" $N
DU_BLOCK_SIZE=human-readable run_cmp "DU_BLOCK_SIZE=hr" $N
DU_BLOCK_SIZE=zz run_cmp "DU_BLOCK_SIZE=zz" $N
BLOCK_SIZE=1M run_cmp "BLOCK_SIZE=1M" $N
BLOCKSIZE=1M run_cmp "BLOCKSIZE=1M" $N
BLOCK_SIZE=1M DU_BLOCK_SIZE=1K run_cmp "DU wins" $N
POSIXLY_CORRECT=1 run_cmp "POSIXLY_CORRECT" $N
POSIXLY_CORRECT=1 run_cmp "POSIXLY_CORRECT -s" -s $N
run_cmp "-k -h"             -k -h $N
run_cmp "-h -k"             -h -k $N
run_cmp "-m -b"             -m -b $N
run_cmp "-b -m"             -b -m $N
run_cmp "-b -h"             -b -h $N
run_cmp "--si -h"           --si -h $N
run_cmp "-h --si"           -h --si $N
run_cmp "--inodes -h"       --inodes -h $N
run_cmp "--inodes -b"       --inodes -b $N
run_cmp "--inodes -d1 -a"   --inodes -d1 -a $N
run_cmp "--inodes -t 3"     --inodes -t 3 $N
run_cmp "--inodes -c"       --inodes -c $N $N/a

printf "\n[ Time ]\n"
for t in "" =atime =access =use =ctime =status =bogus =a =c =mtime; do
    run_cmp "--time$t files"      --time$t -a $N/f1 $N/a/big $N/zero $N/hard1
    run_cmp "--time$t dir"        --time$t -d1 $N/d
done
for st in full-iso long-iso iso '+%Y' '+%s' '+%H:%M:%S.%N' '+%a %b' '+' '+%%' bogus posix-iso posix-long-iso posix-full-iso 'locale' 'iso
x' '+a
b'; do
    run_cmp "--time-style '$st'"  --time --time-style="$st" -a $N/f1 $N/a/big $N/zero
done
TIME_STYLE=iso run_cmp "TIME_STYLE=iso"        --time -a $N/f1 $N/a/big
TIME_STYLE=full-iso run_cmp "TIME_STYLE=full"  --time -a $N/f1 $N/a/big
TIME_STYLE=locale run_cmp "TIME_STYLE=locale"  --time -a $N/f1 $N/a/big
TIME_STYLE=posix-long-iso run_cmp "TIME_STYLE=posix-long-iso" --time -a $N/f1
TIME_STYLE=bogus run_cmp "TIME_STYLE=bogus"    --time -a $N/f1
TIME_STYLE='+%Y
junk' run_cmp "TIME_STYLE=+fmt\\nrest"         --time -a $N/f1
TIME_STYLE=iso run_cmp "TIME_STYLE no --time"  -a $N/f1
TIME_STYLE=iso run_cmp "--time-style wins"     --time --time-style=full-iso -a $N/f1
run_cmp "--time-style alone"  --time-style=iso -a $N/f1
for z in UTC Asia/Kolkata Europe/London; do
    TZ=$z run_cmp "TZ=$z" --time --time-style=full-iso -a $N/f1 $N/a/big $N/zero
done
run_cmp "--time -0"           --time -0 -a $N/f1
run_cmp "--time -c"           --time -c $N/a $N/d
run_cmp "--time --inodes"     --time --inodes $N/d
run_cmp "--time -S"           --time -S $N/a

printf "\n[ Exclude and one-file-system ]\n"
run_cmp "--exclude=*.log"     -a --exclude='*.log' $N/d
run_cmp "--exclude=e.txt"     -a --exclude=e.txt $N/d
run_cmp "--exclude=d"         -a --exclude=d $N
run_cmp "--exclude=t/d"       -a --exclude=t/d $N
run_cmp "--exclude=a/b"       -a --exclude=a/b $N
run_cmp "--exclude=*"         -a --exclude='*' $N
run_cmp "--exclude='*' arg"   --exclude='*' $N/f1
run_cmp "--exclude=t"         -a --exclude=t $N
run_cmp "--exclude=a?"        -a --exclude='[ab]' $N
run_cmp "--exclude multi"     -a --exclude='*.log' --exclude='*.txt' --exclude=zero $N
run_cmp "--exclude escaped"   -a --exclude='e\.log' $N/d
run_cmp "--exclude wildcard slash" -a --exclude='a/*' $N
run_cmp "--exclude trailing /" -a --exclude='d/' $N
run_cmp "--exclude '*'  -c"   -c --exclude='*' $N $N
printf '*.log\n\nzero  \n' > ex1; printf 'a\n' > ex2; : > ex3
run_cmp "-X file"             -a -X ex1 $N
run_cmp "-X file2"            -a -X ex2 $N
run_cmp "-X empty"            -a -X ex3 $N
run_cmp "-X missing"          -a -X nosuch $N
run_cmp "--exclude-from"      -a --exclude-from=ex1 $N
run_cmp "-X and --exclude"    -a -X ex1 --exclude=a $N
run_cmp "-x"                  -x $N
run_cmp "-x /proc"            -x /proc/self/fdinfo
run_cmp "-x dev"              -sx /dev/shm

printf "\n[ files0-from and usage ]\n"
printf '%s\0%s\0' "$N/f1" "$N/a" > f0; printf '%s\0' "$N/f1" > f0b; printf '%s' "$N/f1" > f0c; : > f0e; printf '\0' > f0z; printf 'a\0\0b\0' > f0m; printf '%s\0nosuch\0%s\0' "$N/f1" "$N/d" > f0n; printf -- '-\0' > f0dash
run_cmp "--files0-from"       --files0-from=f0
run_cmp "--files0-from one"   --files0-from=f0b
run_cmp "--files0-from no NUL" --files0-from=f0c
run_cmp "--files0-from empty" --files0-from=f0e
run_cmp "--files0-from zero"  --files0-from=f0z
run_cmp "--files0-from mixed" --files0-from=f0m
run_cmp "--files0-from missing name" --files0-from=f0n
run_cmp "--files0-from missing" --files0-from=nosuch
run_cmp "--files0-from + arg" --files0-from=f0 $N
CMP_STDIN=f0 run_cmp "--files0-from -" --files0-from=-
CMP_STDIN=f0dash run_cmp "--files0-from - dash" --files0-from=-
run_cmp "--files0-from -c"    -c --files0-from=f0
run_cmp "--files0-from -s"    -s --files0-from=f0
run_cmp "no such option"      -z
run_cmp "no such long"        --bogus
run_cmp "amb option"          --s $N
run_cmp "amb option2"         --b $N
run_cmp "-- only"             --
run_cmp "bad arg"             --all=1 $N
run_cmp "missing arg"         -d

cd /; print_summary
