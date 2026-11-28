# SPDX-License-Identifier: GPL-2.0-or-later
# Fixture and cases shared by test_windows_wine.sh and test_windows_vm.sh.
# The caller sets TMP; `t NAME LINE` adds a case. Lines run unchanged by sh on
# Linux and by cmd.exe on Windows, so they use only double quotes, && chaining,
# | and >; no ', %VAR%, ^ outside quotes or backslashes in paths.

mkfixture() {
    rm -rf "$1"
    mkdir -p "$1/dir/sub"
    printf 'banana\napple\ncherry\napple\n10\n9\n' > "$1/a.txt"
    printf 'one two three\nfour five\n\nsix\n' > "$1/b.txt"
    printf 'x,y,z\n1,2,3\n4,5,6\n' > "$1/c.csv"
    printf 'nested\n' > "$1/dir/sub/n.txt"
    printf 'top\n' > "$1/dir/t.txt"
}

# Test lines run unchanged by sh on Linux and by cmd.exe on Windows, so they use
# only double quotes, && chaining and |.
: > "$TMP/tests"
: > "$TMP/names"
NTESTS=0
t() {
    NTESTS=$((NTESTS + 1))
    printf '%s\n' "$1" >> "$TMP/names"
    printf '%s\n' "$2" >> "$TMP/tests"
}

t "cat file" 'cat a.txt'
t "cat -n two files" 'cat -n a.txt b.txt'
t "cat -A" 'cat -A b.txt'
t "cat missing" 'cat nosuchfile'
t "wc" 'wc a.txt'
t "wc -l -w -c" 'wc -l -w -c b.txt'
t "wc -L" 'wc -L b.txt'
t "sort" 'sort a.txt'
t "sort -n" 'sort -n a.txt'
t "sort -ru" 'sort -ru a.txt'
t "sort -t, -k2n" 'sort -t, -k2n c.csv'
t "ls -1" 'ls -1'
t "ls -1a dir" 'ls -1a dir'
t "ls -R" 'ls -R dir'
t "ls -1S files" 'ls -1S a.txt b.txt c.csv'
t "ls missing" 'ls nosuchfile'
t "cp file" 'cp a.txt copy.txt && cat copy.txt'
t "cp -r tree" 'cp -r dir dir2 && find dir2 -type f | sort'
t "cp into dir" 'cp a.txt dir && ls -1 dir'
t "cp missing" 'cp nosuchfile x'
t "rm file" 'rm a.txt && ls -1'
t "rm -r dir" 'rm -r dir && ls -1'
t "rm -f missing" 'rm -f nosuchfile'
t "rm missing" 'rm nosuchfile'
t "mkdir -p" 'mkdir -p x/y/z && find x | sort'
t "mkdir" 'mkdir newdir && ls -1'
t "mkdir existing" 'mkdir dir'
t "date @0" 'date -u -d @0 "+%Y-%m-%dT%H:%M:%S %A %j"'
t "date text" 'date -u -d "2024-02-29 12:34:56" "+%s %a %b %e %U"'
t "date iso" 'date -u -d @86400 --iso-8601=seconds'
t "find -name" 'find . -name "*.txt" -print | sort'
t "find -type d" 'find . -type d | sort'
t "find -maxdepth" 'find . -maxdepth 1 -type f -print | sort'
t "find -size" 'find . -type f -size -2c'
t "grep" 'grep apple a.txt'
t "grep -c" 'grep -c a a.txt'
t "grep -n -i" 'grep -n -i APPLE a.txt'
t "grep -r" 'grep -r nested .'
t "grep -E" 'grep -E "^(a|b)" a.txt'
t "grep no match" 'grep zzz a.txt'
t "sed s///" 'sed "s/apple/APPLE/" a.txt'
t "sed -n p" 'sed -n "2,3p" a.txt'
t "sed -E" 'sed -E "s/([a-z]+) ([a-z]+)/\2 \1/" b.txt'
t "sed -i" 'sed -i "s/a/A/g" a.txt && cat a.txt'
t "sed d" 'sed "/apple/d" a.txt'
t "printf" 'printf "%s %d %5.2f|%-5s|%x\n" hello 42 3.14159 ab 255'
t "printf escapes" 'printf "a\tb\101\n"'
t "test -f" 'test -f a.txt'
t "test -d" 'test -d dir'
t "test -e missing" 'test -e nosuch'
t "test -s" 'test -s a.txt'
t "test strings" 'test abc = abc -a 3 -lt 5'
t "test -w" 'test -w a.txt'
t "env -i" 'env -i FOO=bar BAZ=qux'
t "env -i two" 'env -i FOO=1 BAR=2'
t "seq" 'seq 5'
t "seq range" 'seq 2 3 14'
t "seq -s" 'seq -s, 1 5'
t "seq -w float" 'seq -w 0.5 0.5 3'
t "md5sum" 'md5sum a.txt b.txt'
t "md5sum -c" 'md5sum a.txt > sums.txt && md5sum -c sums.txt'
t "tr" 'cat a.txt | tr a-z A-Z'
t "tr -d" 'cat a.txt | tr -d a'
t "cut -d -f" 'cut -d, -f1,3 c.csv'
t "cut -c" 'cut -c1-3 a.txt'
t "uniq" 'uniq a.txt'
t "uniq -c" 'sort a.txt | uniq -c'
t "uniq -d" 'sort a.txt | uniq -d'
t "tee" 'cat a.txt | tee out.txt && cat out.txt'
t "tee -a" 'cat a.txt | tee -a b.txt > nul && cat b.txt'
t "head -n" 'head -n 2 a.txt'
t "head -c" 'head -c 7 a.txt'
t "tail -n" 'tail -n 2 a.txt'
t "tail -c" 'tail -c 5 a.txt'
t "du -b files" 'du -b a.txt b.txt'
t "stat -c" 'stat -c "%s %F %n" a.txt'
t "stat dir" 'stat -c "%F" dir'
t "basename" 'basename dir/sub/n.txt .txt'
t "readlink non-link" 'readlink a.txt'

