#!/bin/sh
# env: differential tests against GNU env 9.7 (C locale). References: GNU
# manual "env invocation"; POSIX.1-2024 env. Known gap: NAME=VALUE with an
# empty NAME is ignored. The "--help" text is compared via the table below.
UTIL="env"
. "$(dirname "$0")/testlib.sh"
P=/usr/bin/printenv

printf "\n[ Printing and modifying the environment ]\n"
run_cmp "print env minus _"        -u _ -u LC_ALL
run_cmp "-i alone"                 -i
run_cmp "- alone"                  -
run_cmp "-i set"                   -i A=1 B=2
run_cmp "-i set -0"                -i -0 A=1 B=2
run_cmp "--null"                   --null -i A=1
run_cmp "set value with ="         -i A=b=c
run_cmp "set empty"                -i A=
run_cmp "override"                 -i A=1 A=2
run_cmp "-u removes"               -i A=1 B=2 -u A
run_cmp "-u before set"            -u A -i B=2
run_cmp "-u missing"               -i -u NOPE
run_cmp "-u bad name"              -u A=B
run_cmp "-u empty"                 -u ''
run_cmp "-u attached"              -i -uA
run_cmp "--unset="                 -i --unset=A
run_cmp "-iu"                      -iuA
run_cmp "- then vars"              - A=2 B=3
run_cmp "-0 with command"          -0 true
run_cmp "-u missing arg"           -u
run_cmp "bad option"               -x
run_cmp "bad long"                 --nope
run_cmp "abbrev long"               -u _ -u LC_ALL --null
run_cmp "long abbrev"              --ignore -
run_cmp "-- ends options"          -i -- A=1
run_cmp "operand then option"      -i A=1 -u A

printf "\n[ Running commands ]\n"
run_cmp "run printenv"             -i A=1 $P A
run_cmp "run printenv all"         -i A=1 B=2 $P
run_cmp "run true"                 true
run_cmp "run false"                false
run_cmp "exit status"              sh -c 'exit 7'
run_cmp "not found"                nonexistent-cmd
run_cmp "not found with args"      -i A=1 nonexistent-cmd x
run_cmp "directory"                /etc
run_cmp "not executable"           /etc/passwd
run_cmp "PATH from -i"             -i PATH=/usr/bin printenv PATH
run_cmp "PATH search in new env"   PATH=/usr/bin printenv HOME
run_cmp "PATH unset fallback"      -i printenv X
run_cmp "-a argv0"                 -a foo sh -c 'echo $0'
run_cmp "--argv0="                 --argv0=bar sh -c 'echo $0'
run_cmp "-a no command"            -a foo
run_cmp "blank in name"            'a b'
run_cmp "-C dir"                   -C / pwd
run_cmp "--chdir="                 --chdir=/usr pwd
run_cmp "-C missing"               -C /nonexistent pwd
run_cmp "-C twice relative"        -C / -C usr pwd
run_cmp "-C no command"            -C /
run_cmp "args with spaces"         -i printf '[%s]' 'a b' 'c  d'

printf "\n[ Debug output ]\n"
run_cmp "-v"                       -i -v A=1 true
run_cmp "-v unset"                 -v -u HOME true
run_cmp "-v chdir argv0"           -v -C / -a zz pwd
run_cmp "-v not found"             -i -v B nothere
run_cmp "-vi"                      -vi A=1 true

printf "\n[ -S split strings ]\n"
for s in 'printf [%s] a b' 'printf [%s] "a  b" c' "printf [%s] 'a  b' c" 'printf [%s] a\_b' 'printf [%s] a\cb' 'printf [%s] a#b' 'printf [%s] a #b' '#x' ''  '   ' 'printf x\ty' 'printf [%s] "a\tb"' "printf [%s] 'a\\tb'" 'printf [%s] \"q\"' 'printf [%s] "\$"' 'printf [%s] ${HOME}' 'printf [%s] "${HOME}x"' 'printf [%s] ${NOPE}x' 'printf [%s] ${' 'printf [%s] $HOME' 'printf [%s] ${1}' "printf [%s] 'abc" 'printf [%s] "abc' 'printf [%s] a\xb' 'printf [%s] a\' "printf [%s] 'a\\'b'" 'printf [%s] "a\_b"' 'A=1 printenv A' '-i A=1 printenv A' '-u HOME printenv HOME' 'printf [%s] a\
b'; do
    run_cmp "-S [$s]" -u LC_ALL -u _ -S "$s"
done
run_cmp "-S missing arg"           -S
run_cmp "--split-string="          --split-string='printf [%s] a b'
run_cmp "-S with -v"               -v -S 'printf [%s] a b'
run_cmp "-vS"                      -vS 'A=1 printf x'
run_cmp "-S then more args"        -S'printf [%s]' x y
run_cmp "-S options inside"        -S'-i A=1' printenv
run_cmp "-iS"                      -iS'A=1 printenv'

printf "\n[ Signals ]\n"
run_cmp "ignore INT list"          --ignore-signal=INT --list-signal-handling true
run_cmp "block INT list"           --block-signal=INT --list-signal-handling true
run_cmp "ignore+block"             --ignore-signal=INT,TERM --block-signal=TERM --list-signal-handling true
run_cmp "ignore all"               --ignore-signal --list-signal-handling true
run_cmp "default after ignore"     --ignore-signal=INT --default-signal=INT --list-signal-handling true
run_cmp "numeric signal"           --ignore-signal=2 --list-signal-handling true
run_cmp "SIGINT name"              --ignore-signal=SIGINT --list-signal-handling true
run_cmp "lower name"               --ignore-signal=int --list-signal-handling true
run_cmp "empty SIG"                --ignore-signal= --list-signal-handling true
run_cmp "bad signal"               --ignore-signal=FOO true
run_cmp "KILL ignore"              --ignore-signal=KILL true
run_cmp "default KILL"             --default-signal=KILL true
run_cmp "ignored seen by child"    --ignore-signal=INT sh -c 'trap'
run_cmp "list nothing"             --list-signal-handling true

print_summary
[ "$FAIL" -eq 0 ]
