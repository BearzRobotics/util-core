#!/bin/sh
# find: differential tests against GNU findutils 4.10 (C locale unless noted).
UTIL="find"
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
export TZ=UTC LC_ALL=C
mkdir t && cd t
mkdir -p a/b/c "a/sp ace" empty_dir e2 d3/x/y/z
printf 'hello\n' > a/f1.txt; printf 'x' > a/b/f2.c; : > a/b/c/empty.dat; head -c 5000 /dev/zero > a/big.bin
printf 'z\n' > "a/sp ace/file with space"; printf 'q\n' > a/.hidden
ln -s f1.txt a/link; ln -s nowhere a/dangling; ln -s b a/dirlink; ln -s .. a/b/up; mkfifo a/fifo
chmod 755 a/b; chmod 600 a/f1.txt; chmod 4755 a/b/f2.c; chmod 644 a/big.bin
touch -d '2020-01-02 03:04:05' a/f1.txt; touch -d '2000-01-01' a/b/f2.c a/big.bin; touch -d '1999-12-31 23:59:59' a/.hidden
touch -d '2010-06-15 12:00:00' a/b/c/empty.dat "a/sp ace/file with space"
ln a/f1.txt a/hard; printf 'nl\n' > "$(printf 'a/new\nline')"
printf 'x\n' > d3/x/y/z/deep.txt; printf 'y\n' > d3/x/top.txt; printf 'q' > e2/only.txt
printf 'u\n' > "a/UPPER.TXT"; printf 'm\n' > 'a/we*ird[name]?'
mkdir -p a/perm_d && chmod 000 a/perm_d
printf 'ref\n' > ref; touch -d '2015-05-05 05:05:05' ref
cd "$W/t"
# restore permissions at exit so the temp tree can be removed
trap 'chmod -R u+rwx "$W" 2>/dev/null; chmod -R u+rwx "$TEST_TMP" 2>/dev/null; rm -rf "$TEST_TMP"' EXIT

fd() { d="$1"; shift; CMP_STDIN=/dev/null run_cmp "$d" "$@"; }

# ---- simple traversals and tests
for st in . a "a b" a/ a// ./a a/f1.txt a/link a/dirlink a/dangling a/b/up nosuch empty_dir e2 d3; do
    for opts in "" "-H" "-L" "-P" "-H -L" "-L -P"; do
        fd "$opts '$st'" $opts "$st"
        fd "$opts '$st' -type f" $opts "$st" -type f
        fd "$opts '$st' -type d" $opts "$st" -type d
        fd "$opts '$st' -type l" $opts "$st" -type l
        fd "$opts '$st' -printf" $opts "$st" -printf '%p|%y|%Y|%s|%d|%P|%h|%f|%H\n'
    done
done
fd 'no args' 
fd 'multi start' a e2 d3
fd 'multi start dup' a a
fd 'multi start missing' a nosuch e2
fd 'multi start -type f' a e2 -type f
fd 'start with -' ./-x
fd 'start .' . -maxdepth 1
fd 'start ..' .. -maxdepth 0
fd 'start /' / -maxdepth 0
fd 'start / mindepth' / -maxdepth 1 -mindepth 1 -name 'bi*'
fd 'start //' // -maxdepth 0
fd 'start ///' /// -maxdepth 0 -printf '%p|%f|%h\n'
fd 'start a//b' a//b
fd 'start a/./b' a/./b
fd 'start a/../a' a/../a -maxdepth 1

for n in 0 1 2 3 4; do
    fd "-maxdepth $n" a -maxdepth $n
    fd "-mindepth $n" a -mindepth $n
    fd "-mindepth $n -maxdepth $n" a -mindepth $n -maxdepth $n
    fd "-depth -maxdepth $n" a -depth -maxdepth $n
    fd "-L -maxdepth $n" -L a -maxdepth $n
done
fd '-mindepth > maxdepth' a -mindepth 3 -maxdepth 1
fd '-maxdepth after test' a -type f -maxdepth 1
fd '-maxdepth missing' a -maxdepth
fd '-maxdepth x' a -maxdepth x
fd '-maxdepth -1' a -maxdepth -1
fd '-maxdepth 1x' a -maxdepth 1x
fd '-mindepth missing' a -mindepth
fd '-depth' a -depth
fd '-d' a -d
fd '-depth -print' a -depth -print
fd '-depth -name' a -depth -name '*.txt'
fd '-depth -prune' a -depth -prune
fd '-mount' a -mount
fd '-xdev' a -xdev
fd '-xdev /' / -xdev -maxdepth 1 -name 'p*'
fd '-noleaf' a -noleaf
fd '-ignore_readdir_race' a -ignore_readdir_race
fd '-noignore_readdir_race' a -noignore_readdir_race
fd '-follow' a -follow -maxdepth 2
fd '-follow -type l' a -follow -type l
fd '-daystart' a -daystart -maxdepth 1
fd '-warn' a -warn -maxdepth 1
fd '-nowarn' a -nowarn -maxdepth 1

# ---- tests
for pat in '*' '*.txt' '*.TXT' 'f*' 'F*' '.*' '?' '??' 'a' 'b' 'c' 'sp*' '*ace' '*e*' '[a-c]' '[!a-c]*' '[[:upper:]]*' '*[[:digit:]]*' 'f1.txt' 'we\*ird*' 'we*' '*\[*' '*?' 'x\' '' '*/*' 'a/*' '\*'; do
    fd "-name '$pat'" a -name "$pat"
    fd "-iname '$pat'" a -iname "$pat"
    fd "-path '$pat'" a -path "$pat"
    fd "-ipath '$pat'" a -ipath "$pat"
    fd "-wholename '$pat'" a -wholename "$pat"
    fd "-lname '$pat'" a -lname "$pat"
    fd "-ilname '$pat'" a -ilname "$pat"
    fd "! -name '$pat'" a ! -name "$pat"
done
fd '-name .' . -name .
fd '-name ..' .. -maxdepth 0 -name ..
fd '-name a/' a/ -name a
fd '-name a on start' a -name a
fd '-name a on a/' a/ -maxdepth 0 -name a
fd '-name / start' / -maxdepth 0 -name '/'
fd '-name slash warn' a -name 'b/c'
fd '-iname slash warn' a -iname 'B/C'
fd '-path start' a -path a
fd '-path ./a' ./a -path './a/*'
fd '-name missing' a -name
fd '-path missing' a -path
fd '-lname missing' a -lname

for ty in f d l b c p s D f,d d,l f,d,l,p fd 'f,' ',f' 'f,,d' x '' F 'f d'; do
    fd "-type '$ty'" a -type "$ty"
    fd "-xtype '$ty'" a -xtype "$ty"
    fd "-L -type '$ty'" -L a -type "$ty"
    fd "-L -xtype '$ty'" -L a -xtype "$ty"
done
fd '-type missing' a -type
fd '-xtype missing' a -xtype

for sz in 0 1 2 5 +0 -1 +1 1c 5000c +4999c -5001c 1k +1k -1k 4k 5k +4k 1M 1G 1b 10b +9b 1w 2w +5000c +1b 0c +0c -0 1T 1P 1x x -x +x '' 5kk k 1.5k -; do
    fd "-size '$sz'" a -size "$sz"
    fd "-type f -size '$sz'" a -type f -size "$sz"
done
fd '-size missing' a -size

for pm in 600 644 755 4755 0 7777 1777 000 u+x u=rw u=r,g=r,o=r a+r go-w u+s g+s +t o+t -u+x -g=r -o+r -a+r -4000 -2000 -1000 -600 -644 -000 /u+x /600 /111 /000 /4000 /u=w,g=w /xyz xyz 999 8 -999 /999 +644 +u+x 07777 010000 u= =w 'u+x,g+x' 'g=u' 'o=g' u+X a+X go= '' - /; do
    fd "-perm '$pm'" a -perm "$pm"
done
fd '-perm missing' a -perm

for u in dakota root 1000 0 nosuchuser 99999 '' ' ' -1 +1 1x; do
    fd "-user '$u'" a -user "$u"
done
for g in dakota root 1000 0 nosuchgroup 99999 '' -1; do
    fd "-group '$g'" a -group "$g"
done
for n in 1000 0 +999 -1001 +0 -0 x 1x '' +x; do
    fd "-uid '$n'" a -uid "$n"
    fd "-gid '$n'" a -gid "$n"
    fd "-links '$n'" a -links "$n"
    fd "-inum '$n'" a -inum "$n"
done
fd '-nouser' a -nouser
fd '-nogroup' a -nogroup
fd '-user missing' a -user
fd '-uid missing' a -uid
fd '-links missing' a -links
fd '-inum same' a -inum "$(stat -c %i a/f1.txt)"
fd '-samefile' a -samefile a/f1.txt
fd '-samefile link' a -samefile a/link
fd '-samefile dir' a -samefile a
fd '-samefile missing file' a -samefile nosuch
fd '-samefile missing' a -samefile
fd '-L -samefile link' -L a -samefile a/link
fd '-empty' a -empty
fd '-empty -type f' a -empty -type f
fd '-empty -type d' a -empty -type d
fd '-empty e2' e2 -empty
fd '-empty empty_dir' empty_dir -empty
fd '-readable' a -readable
fd '-writable' a -writable
fd '-executable' a -executable
fd '-executable -type f' a -executable -type f
fd '-fstype ext4' a -fstype ext4 -maxdepth 1
fd '-fstype overlay' a -fstype overlay -maxdepth 1
fd '-fstype bogus' a -fstype bogus -maxdepth 1
fd '-fstype missing' a -fstype
fd '-true' a -true
fd '-false' a -false
fd '-true -false' a -true -false
fd '-false -o -true' a -false -o -true
fd '-context' a -context x

for t in a m c; do
  for v in 0 1 2 +0 -1 +1 -2 +5000 -5000 x 1x '' +; do
    fd "-${t}time '$v'" a -${t}time "$v"
    fd "-${t}min '$v'" a -${t}min "$v"
  done
done
fd '-mtime missing' a -mtime
fd '-mmin missing' a -mmin
fd '-daystart -mtime 0' a -daystart -mtime 0 -maxdepth 1
fd '-daystart -mtime +0' a -daystart -mtime +0 -maxdepth 1 -type f
fd '-daystart -mtime 1' a -daystart -mtime 1 -type f
fd '-daystart -mmin' a -daystart -mmin -100000 -type f
fd '-mtime -daystart' a -mtime +1 -daystart -type f
for ref in ref a/f1.txt a/b/f2.c a nosuch ''; do
    fd "-newer '$ref'" a -newer "$ref"
    fd "-anewer '$ref'" a -anewer "$ref"
    fd "-cnewer '$ref'" a -cnewer "$ref"
    fd "-newerma '$ref'" a -newerma "$ref"
    fd "-newermc '$ref'" a -newermc "$ref"
    fd "-newerac '$ref'" a -newerac "$ref"
    fd "-newercm '$ref'" a -newercm "$ref"
    fd "-newermm '$ref'" a -newermm "$ref"
done
for ts in '2005-01-01' '2010-06-15 12:00:00' '2010-06-15' '@1000000000' '2030-01-01' 'yesterday' 'garbage' '' '1970-01-01' '2000-01-01 00:00:00 UTC'; do
    fd "-newermt '$ts'" a -newermt "$ts"
    fd "-newerat '$ts'" a -newerat "$ts"
    fd "-newerct '$ts'" a -newerct "$ts"
    fd "-newertm '$ts'" a -newertm "$ts"
done
fd '-newerBm' a -newerBm ref
fd '-newermB' a -newermB ref
fd '-newerBt' a -newerBt '2005-01-01'
fd '-newerXY bad' a -newerzm ref
fd '-newerXY bad2' a -newermz ref
fd '-newerXY bad3' a -newertm ref
fd '-newer missing' a -newer
fd '-used' a -used 0
fd '-used +0' a -used +0
fd '-used -1' a -used -1
fd '-used x' a -used x
fd '-used missing' a -used

# ---- regex
for re in '.*' 'a/b.*' 'a/.*c' '.*\.txt' '.*\.TXT' 'a' 'a/f1\.txt' 'a/(f1|f2).*' 'a/\(f1\|f2\).*' '.*[0-9].*' '.*[[:upper:]].*' 'a/[a-f]*' '.*' 'a/b/.\{1,4\}' 'a/b/.{1,4}' 'a/b/.+' 'a/b/.*?' '.*\(' '.*(' '[' '\' '*a' 'a**' ''; do
    for rt in default posix-basic posix-extended emacs grep egrep sed ed awk posix-awk gnu-awk posix-egrep posix-minimal-basic findutils-default; do
        fd "-regextype $rt -regex '$re'" a -regextype $rt -regex "$re"
    done
    fd "-regex '$re'" a -regex "$re"
    fd "-iregex '$re'" a -iregex "$re"
done
fd '-regextype bogus' a -regextype bogus -regex x
fd '-regextype missing' a -regextype
fd '-regex missing' a -regex
fd '-regextype after' a -regex 'a/f.*' -regextype posix-extended

# ---- operators
fd 'and' a -name '*.txt' -a -type f
fd 'and2' a -name '*.txt' -and -type f
fd 'or' a -name '*.txt' -o -name '*.c'
fd 'or2' a -name '*.txt' -or -name '*.c'
fd 'not' a -not -name '*.txt' -maxdepth 1
fd 'bang' a ! -name '*.txt' -maxdepth 1
fd 'bang bang' a ! ! -name '*.txt'
fd 'not not' a -not -not -name '*.txt'
fd 'parens' a '(' -name '*.txt' -o -name '*.c' ')' -type f
fd 'parens nested' a '(' '(' -name '*.txt' ')' -o '(' -name '*.c' ')' ')' -print
fd 'parens not' a '!' '(' -name '*.txt' -o -name '*.c' ')' -maxdepth 1
fd 'comma' a -maxdepth 1 -name '*.txt' , -name '*.c' -print
fd 'comma2' a -maxdepth 1 -type d , -type f
fd 'comma print' a -maxdepth 1 -name 'f*' -print , -name 'b*' -print
fd 'precedence' a -name f1.txt -o -name f2.c -a -type f
fd 'precedence2' a -type d -o -name f1.txt -a -type f -maxdepth 2
fd 'print twice' a -maxdepth 1 -print -print
fd 'print and print0' a -maxdepth 1 -print -print0
fd 'print -o print' a -maxdepth 1 -name 'f*' -print -o -print
fd 'implicit print with or' a -maxdepth 1 -name 'f*' -o -name 'b*'
fd 'implicit print with prune' a -name b -prune
fd 'implicit print with quit' a -quit
fd 'no implicit print with delete -false' a -maxdepth 1 -false -delete
fd 'unclosed paren' a '(' -name x
fd 'unclosed paren 2' a '(' -name x -o
fd 'extra close paren' a -name x ')'
fd 'extra close paren 2' a ')' -name x
fd 'empty parens' a '(' ')'
fd 'paren only' a '('
fd 'close only' a ')'
fd 'bang only' a '!'
fd 'bang before close' a '(' ! ')'
fd 'and end' a -name x -a
fd 'or end' a -name x -o
fd 'comma end' a -name x ,
fd 'and start' a -a -name x
fd 'or start' a -o -name x
fd 'comma start' a , -name x
fd 'double and' a -name x -a -a -name y
fd 'double or' a -name x -o -o -name y
fd 'not end' a -not
fd 'not not end' a -not -not
fd 'or before close' a '(' -name x -o ')'
fd 'and before close' a '(' -name x -a ')'
fd 'unknown pred' a -bogus
fd 'unknown pred 2' a -name x -bogus
fd 'unknown pred 3' a -Name x
fd 'dash only' a -
fd 'dashdash' -- a -maxdepth 0
fd 'path after expr' a -type f b
fd 'path after expr name' a -name x b
fd 'path after maxdepth' a -maxdepth 1 b
fd 'path after paren' a '(' -name x ')' b
fd 'path after print' a -print b
fd 'path after type' -type f a
fd 'expr only' -name '*.txt'
fd 'expr only !' ! -name '*.txt'
fd 'expr only (' '(' -name x ')'
fd 'expr only -true' -true
fd 'expr only -maxdepth' -maxdepth 1
fd 'expr only -L' -L
fd '-L after path' a -L
fd '-H after path' a -H
fd '-P after path' a -P
fd '-H -L -P' -H -L -P a -maxdepth 0
fd '-D help' -D help
fd '-D bogus' -D bogus a -maxdepth 0
fd '-D missing' -D
fd '-O' -O a -maxdepth 0
fd '-O0' -O0 a -maxdepth 0
fd '-O1' -O1 a -maxdepth 0
fd '-O3' -O3 a -maxdepth 0
fd '-O9' -O9 a -maxdepth 0
fd '-Ox' -Ox a -maxdepth 0
fd '-X' -X a
fd '--' -- -maxdepth 0
fd '-- start' -- a -maxdepth 0
fd '--version' --version
fd '-version' -version
fd '--version extra' --version a
fd '--bogus' --bogus

# ---- actions
fd '-print0' a -print0
fd '-print0 -type f' a -type f -print0
fd '-ls' a -ls
fd '-ls -type l' a -type l -ls
fd '-ls -L' -L a -ls
fd '-ls spaces' a -name 'sp*' -ls
fd '-prune' a -name b -prune -o -print
fd '-prune dir' a -type d -name b -prune -o -type f -print
fd '-prune start' a -prune
fd '-prune print' a -prune -print
fd '-prune -depth' a -depth -name b -prune -o -print
fd '-prune maxdepth' a -maxdepth 1 -name b -prune -o -print
fd '-quit' a -quit
fd '-quit print' a -print -quit
fd '-quit name' a -name 'f2.c' -print -quit
fd '-quit exec' a -type f -exec echo {} ';' -quit
fd '-quit exec plus' a -type f -exec echo {} + -quit
fd '-quit 2 starts' a e2 -print -quit
fd '-quit depth' a -depth -print -quit
for fmt in '%p\n' '%f\n' '%h\n' '%H\n' '%P\n' '%d\n' '%y\n' '%Y\n' '%m\n' '%M\n' '%s\n' '%S\n' '%b\n' '%k\n' '%n\n' '%i\n' '%D\n' '%l\n' '%u\n' '%g\n' '%U\n' '%G\n' '%F\n' '%Z\n' '%%\n' '%\n' '%z\n' 'x' '' '\n' '\\\n' '\a\b\f\n\r\t\v\n' '\101\n' '\0\n' '\1\n' '\777\n' '\q\n' '\' '%c\n' '%a\n' '%t\n' '%A@\n' '%C@\n' '%T@\n' '%A+\n' '%T+\n' '%C+\n' '%AY\n' '%Aa %Ab %Ad\n' '%AH:%AM:%AS\n' '%TD\n' '%Tj\n' '%TZ\n' '%Tz\n' '%Tp %Tr %TR\n' '%Tu %Tw %TU %TW %TV\n' '%Ty %Tg %TG %Tk %Tl\n' '%Tn%Tt|\n' '%Th %Te %Tm %Td\n' '%TA %TB\n' '%TC\n' '%Ts\n' '%TE\n' '%Tq\n' '%T\n' '%A\n' '%C\n' '%5s|\n' '%-5s|\n' '%05s|\n' '%.2s|\n' '%5.2f|\n' '%-8f|\n' '%8h|\n' '%05d|\n' '%5d|\n' '%-5d|\n' '%5m|\n' '%05m|\n' '%#m|\n' '%#5m|\n' '%+m|\n' '% m|\n' '%5y|\n' '%-5y|\n' '%5M|\n' '%.5M|\n' '%10u|\n' '%-10u|\n' '%5U|\n' '%05U|\n' '%15F|\n' '%5k|\n' '%5b|\n' '%5n|\n' '%8i|\n' '%5S|\n' '%10P|\n' '%.1P|\n' '%1p\n' '%*s\n' '%1$s\n' '%ls\n' '%hs\n' '%%%p%%\n' '%p%\n' '%5%\n' '%-%\n'; do
    fd "-printf '$fmt'" a -maxdepth 2 -type f -printf "$fmt"
done
fd '-printf dirs' a -maxdepth 1 -printf '%p %y %m %n %s\n'
fd '-printf missing' a -printf
fd '-printf link' a -type l -printf '%p -> %l|%y|%Y\n'
fd '-L -printf link' -L a -printf '%p|%l|%y|%Y\n'
fd '-printf H' a e2 -printf '%H %P|%p\n'
fd '-printf P start' a/ -printf '%H|%P|%p\n'
fd '-printf f start' a/ -maxdepth 0 -printf '%f|%h\n'
fd '-printf f //' // -maxdepth 0 -printf '%f|%h|%p\n'
fd '-printf f /' / -maxdepth 0 -printf '%f|%h|%p\n'
fd '-printf f .' . -maxdepth 0 -printf '%f|%h|%p|%P\n'
fd '-printf f ..' .. -maxdepth 0 -printf '%f|%h|%p|%P\n'
fd '-printf f a//b' a//b -maxdepth 0 -printf '%f|%h|%p|%P\n'
fd '-printf depth' a -printf '%d %p\n'
fd '-printf newline name' a -name 'new*' -printf '[%f]\n'
fd '-printf star name' a -name 'we*' -printf '[%f]\n'
fd '-fprint' a -maxdepth 1 -fprint out.txt
fd '-fprint stdout' a -maxdepth 1 -fprint /dev/stdout
fd '-fprint stderr' a -maxdepth 1 -fprint /dev/stderr
fd '-fprint missing' a -fprint
fd '-fprint dir' a -fprint /nonexistent/dir/file
fd '-fprint0' a -maxdepth 1 -fprint0 /dev/stdout
fd '-fprintf' a -maxdepth 1 -fprintf /dev/stdout '%p|%s\n'
fd '-fprintf missing fmt' a -fprintf /dev/stdout
fd '-fls' a -maxdepth 1 -fls /dev/stdout
fd '-print then fprint same' a -maxdepth 1 -print -fprint /dev/stdout
fd '-fprint same file twice' a -maxdepth 1 -fprint same.txt -fprint same.txt

# ---- exec
fd '-exec echo' a -type f -exec echo {} ';'
fd '-exec echo \;' a -type f -exec echo {} \;
fd '-exec echo +' a -type f -exec echo {} +
fd '-exec echo + dirs' a -exec echo {} +
fd '-exec prefix' a -type f -exec echo 'file:' {} ';'
fd '-exec embedded' a -type f -exec echo 'x{}y' ';'
fd '-exec embedded +' a -type f -exec echo 'x{}y' +
fd '-exec double' a -type f -exec echo {} {} ';'
fd '-exec double +' a -type f -exec echo {} {} +
fd '-exec no brace' a -maxdepth 1 -type f -exec echo hi ';'
fd '-exec no brace +' a -maxdepth 1 -type f -exec echo hi +
fd '-exec brace not last +' a -type f -exec echo {} x +
fd '-exec false' a -type f -exec false ';'
fd '-exec false print' a -type f -exec false ';' -print
fd '-exec true print' a -type f -exec true ';' -print
fd '-exec false -o' a -type f -exec false ';' -o -print
fd '-exec exit 3' a -type f -exec sh -c 'exit 3' ';'
fd '-exec exit 3 +' a -type f -exec sh -c 'exit 3' sh {} +
fd '-exec nosuch' a -type f -exec nosuchcmd ';'
fd '-exec nosuch +' a -type f -exec nosuchcmd {} +
fd '-exec dir' a -type f -exec ls -d {} ';'
fd '-exec missing term' a -exec echo
fd '-exec missing term brace' a -exec echo {}
fd '-exec only' a -exec
fd '-exec ;' a -exec ';'
fd '-exec +' a -exec +
fd '-exec {} +' a -exec {} +
fd '-exec sh -c' a -type f -name 'f1*' -exec sh -c 'echo "$0 $1"' x {} ';'
fd '-exec args' a -type f -name 'f1*' -exec printf '[%s]\n' {} ';'
fd '-exec space name' a -name 'sp*' -type f -exec printf '[%s]\n' {} ';'
fd '-exec newline name' a -name 'new*' -exec printf '[%s]\n' {} ';'
fd '-exec plus many' a -type f -exec printf '[%s]\n' {} +
fd '-exec plus with print' a -type f -exec echo {} + -print
fd '-exec plus -o' a -type f -exec echo {} + -o -print
fd '-exec plus depth' a -depth -type f -exec echo {} +
fd '-exec plus two' a -type f -name '*.txt' -exec echo A {} + -exec echo B {} +
fd '-exec output order' a -maxdepth 1 -print -exec echo X ';'
fd '-exec stdin' a -maxdepth 1 -type f -exec cat {} ';'
fd '-exec in subdir' a -execdir pwd ';'
fd '-execdir' a -type f -execdir echo {} ';'
fd '-execdir +' a -type f -execdir echo {} +
fd '-execdir pwd' a -type f -execdir sh -c 'echo $PWD | sed "s#.*/##"' ';'
fd '-execdir start' a -maxdepth 0 -execdir echo {} ';'
fd '-execdir start +' a -maxdepth 0 -execdir echo {} +
fd '-execdir start slash' a/ -maxdepth 0 -execdir echo {} ';'
fd '-execdir path' a/b -maxdepth 0 -execdir echo {} ';'
fd '-execdir embedded' a -type f -execdir echo 'x{}y' ';'
fd '-execdir false' a -type f -execdir false ';'
fd '-execdir missing' a -execdir
fd '-ok' a -type f -ok echo {} ';'
fd '-okdir' a -type f -okdir echo {} ';'
fd '-ok +' a -type f -ok echo {} +
fd '-ok missing' a -ok
run_ok() { d="$1"; ans="$2"; shift 2; CMP_STDIN="$ans" run_cmp "$d" "$@"; }
printf 'y\nn\ny\nyes\nno\nY\nx\n\n' > answers.txt
printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' > yes.txt
run_ok '-ok answers' answers.txt a -type f -ok echo {} ';'
run_ok '-ok yes' yes.txt a -type f -ok echo {} ';'
run_ok '-okdir yes' yes.txt a -type f -okdir echo {} ';'
run_ok '-ok eof' /dev/null a -type f -ok echo {} ';'
run_ok '-ok print' answers.txt a -maxdepth 1 -type f -ok echo {} ';' -print
run_ok '-ok multi args' yes.txt a -maxdepth 1 -name f1.txt -ok echo a b {} c ';'

# ---- file system changes
SET='mkdir -p a/b/c a/d e; printf x > a/f1; printf y > a/b/f2; : > a/b/c/f3; printf z > e/f4; ln -s a/f1 lnk; mkdir empty; ln -s ../e a/d/up; chmod 400 e/f4'
run_tree_t() { d="$1"; s="$2"; shift 2; TREE_CONTENT=1 run_tree "$d" "$s" "$@"; }
run_tree_t '-delete files' "$SET" a -type f -delete
run_tree_t '-delete all' "$SET" a -delete
run_tree_t '-delete depth implied' "$SET" a -delete -print
run_tree_t '-delete name' "$SET" . -name 'f*' -delete
run_tree_t '-delete empty' "$SET" . -empty -delete
run_tree_t '-delete . ' "$SET" . -delete
run_tree_t '-delete nonempty dir only' "$SET" a/b -type d -delete
run_tree_t '-delete symlink' "$SET" . -type l -delete
run_tree_t '-delete dangling' "$SET; ln -s nowhere dang" . -name dang -delete
run_tree_t '-delete -L symlink' "$SET" -L . -name lnk -delete
run_tree_t '-delete mindepth' "$SET" a -mindepth 1 -delete
run_tree_t '-delete maxdepth' "$SET" a -maxdepth 1 -delete
run_tree_t '-delete unreadable' "$SET; chmod 000 a/b" a -delete
run_tree_t '-delete ro dir' "$SET; chmod 555 a/b" a -delete
run_tree_t '-delete ro file in dir' "$SET" e -delete
run_tree_t '-delete prune' "$SET" a -name b -prune -o -delete
run_tree_t '-delete multi' "$SET" a e -delete
run_tree_t '-delete missing' "$SET" nosuch -delete
run_tree_t '-delete print order' "$SET" a e -type f -print -delete
run_tree_t '-exec rm' "$SET" a -type f -exec rm {} ';'
run_tree_t '-exec rm +' "$SET" a -type f -exec rm {} +
run_tree_t '-execdir rm' "$SET" a -type f -execdir rm {} ';'
run_tree_t '-exec mv' "$SET" a -name f1 -exec mv {} {}.bak ';'
run_tree_t '-execdir mv' "$SET" a -name f1 -execdir mv {} {}.bak ';'
run_tree_t '-fprint file' "$SET" a -fprint out.txt
run_tree_t '-fprint file twice' "$SET" a -type f -fprint o1 -fprint o2
run_tree_t '-fprint0 file' "$SET" a -fprint0 out.txt
run_tree_t '-fprintf file' "$SET" a -fprintf out.txt '%p %s\n'
run_tree_t '-fprint existing' "$SET; echo old > out.txt" a -fprint out.txt
run_tree_t '-fprint in tree' "$SET" . -fprint out.txt
run_tree_t '-fprint missing dir' "$SET" a -fprint nodir/out.txt
run_tree_t 'unreadable dir' "$SET; chmod 000 a/b" a
run_tree_t 'unreadable dir -type f' "$SET; chmod 000 a/b" a -type f
run_tree_t 'unreadable dir -depth' "$SET; chmod 000 a/b" a -depth
run_tree_t 'unreadable dir -prune' "$SET; chmod 000 a/b" a -name b -prune -o -print
run_tree_t 'unreadable start' "$SET; chmod 000 a" a
run_tree_t 'unreadable dir -empty' "$SET; chmod 000 a/b" a -empty
run_tree_t 'unreadable dir maxdepth' "$SET; chmod 000 a/b" a -maxdepth 1
run_tree_t 'noexec dir' "$SET; chmod 444 a/b" a
run_tree_t 'noexec dir -type f' "$SET; chmod 444 a/b" a -type f
run_tree_t 'loop -L' "$SET; ln -s .. a/b/c/loop" -L a
run_tree_t 'loop -P' "$SET; ln -s .. a/b/c/loop" -P a
run_tree_t 'loop -L -type l' "$SET; ln -s .. a/b/c/loop" -L a -type l
run_tree_t 'loop -H' "$SET; ln -s .. a/b/c/loop" -H a
run_tree_t 'loop -L depth' "$SET; ln -s .. a/b/c/loop" -L a -depth
run_tree_t 'loop -L start' "$SET; ln -s . a/self" -L a
run_tree_t 'loop -L mutual' "$SET; ln -s ../d a/b/toD; ln -s ../b a/d/toB" -L a
run_tree_t 'dangling -L' "$SET; ln -s nowhere a/dang" -L a
run_tree_t 'dangling -L -type l' "$SET; ln -s nowhere a/dang" -L a -type l
run_tree_t 'dangling -L -xtype l' "$SET; ln -s nowhere a/dang" -L a -xtype l
run_tree_t 'dangling -P -xtype l' "$SET; ln -s nowhere a/dang" -P a -xtype l
run_tree_t 'start dangling -H' "$SET; ln -s nowhere dang" -H dang
run_tree_t 'start dangling -L' "$SET; ln -s nowhere dang" -L dang
run_tree_t 'start dangling -P' "$SET; ln -s nowhere dang" -P dang
run_tree_t 'start link to dir -H' "$SET" -H lnk
run_tree_t 'start link to dir' "$SET; ln -s a adir" adir
run_tree_t 'start link to dir -H' "$SET; ln -s a adir" -H adir
run_tree_t 'start link to dir -L' "$SET; ln -s a adir" -L adir
run_tree_t 'start link to dir slash' "$SET; ln -s a adir" adir/
run_tree_t 'start link to dir slash -P' "$SET; ln -s a adir" -P adir/
run_tree_t 'start link to dir -type l' "$SET; ln -s a adir" adir -type l
run_tree_t 'start link to dir -H -type l' "$SET; ln -s a adir" -H adir -type l
run_tree_t 'special names' "$SET; mkdir -p '-dash' '(paren' '!bang' ',comma'; : > '-dash/x'; : > '!bang/y'" -- . -maxdepth 2 -name '[-!(,]*' -print
run_tree_t 'path named -x' "$SET; mkdir ./-x; : > ./-x/f" ./-x
run_tree_t 'long path' "$SET; mkdir -p $(printf 'dddddddddd/%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)" . -type d -name 'd*' -newer a
run_tree_t 'many files' "$SET; mkdir many; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do : > many/f\$i; done" many -type f
run_tree_t 'sorted many' "$SET; mkdir many; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do : > many/f\$i; done" many -type f -name 'f1*'

help_cmp_find() {
    exp=$(LC_ALL=C /usr/bin/find --help | sed 's#/usr/bin/find#find#')
    act=$(ours --help | sed 's#^Usage: [^ ]*#Usage: find#')
    if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); printf "PASS --help text\n"
    else FAIL=$((FAIL + 1)); printf "FAIL --help text\n"; fi
}
help_cmp_find
cd /; print_summary
