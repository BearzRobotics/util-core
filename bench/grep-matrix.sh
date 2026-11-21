#!/bin/sh
# grep benchmark matrix: GNU grep, ours, ripgrep and ugrep over generated data.
#
#   sh bench/grep-matrix.sh [-o OURS_GREP] [-r RUNS] [-d DATADIR] [-t "tool tool"] [row-name-pattern]
#
# Environment: OURS (our grep binary), BASE (an older build; add `base` to TOOLS), RUNS (default 5; the fastest run is
# reported), DATA (default /stuff/tmp/gb/data), TOOLS (default "gnu ours rg ugrep").
# Output: a markdown table, one row per case, one "wall ms / cpu ms / RSS MB"
# cell per tool. Standard output of every command goes to a pipe that is read
# and discarded (GNU grep and ours stop at the first match when stdout is
# /dev/null, which would hide the real cost).
#
# `crap` is the preferred measuring tool (it adds cycles and instructions) but
# it needs perf events (kernel.perf_event_paranoid <= 2). When it cannot open
# them, bench/grep-time.py (wait4 rusage) is used instead; set USE_CRAP=1 to
# force crap, which then prints its own comparison for each row after the
# table cell.
set -f
here=$(cd "$(dirname "$0")" && pwd)
OURS=${OURS:-/stuff/tmp/gb/base/bin/grep}
RUNS=${RUNS:-5}
DATA=${DATA:-/stuff/tmp/gb/data}
TOOLS=${TOOLS:-gnu ours rg ugrep}
while getopts o:r:d:t: o; do
	case $o in
	o) OURS=$OPTARG ;;
	r) RUNS=$OPTARG ;;
	d) DATA=$OPTARG ;;
	t) TOOLS=$OPTARG ;;
	*) exit 2 ;;
	esac
done
shift $((OPTIND - 1))
ONLY=${1:-}

[ -f "$DATA/big.txt" ] || python3 -I "$here/grep-gen.py" "$DATA" || exit 1

BIG=$DATA/big.txt MID=$DATA/mid.txt U8=$DATA/utf8.txt TREE=$DATA/tree
W3=$DATA/words3000.txt W1=$DATA/words1000.txt W10=$DATA/words10.txt

# A case: name | locale | GNU-style arguments | ripgrep arguments (optional,
# default: same). Arguments are split on spaces; globbing is off.
cases() {
	cat <<EOF
lit-rare|C|zqxjv $BIG|
lit-common -c|C|-c the $BIG|
lit-common out|C|the $MID|
lit-nohit|C|-c qqqqqq $BIG|
lit -c two|C|-c two $MID|
-i rare|C|-i ZQXJV $BIG|
-i common -c|C|-ci THE $BIG|
-w -c|C|-cw the $BIG|
-x -c|C|-cx and $BIG|
-v -c|C|-vc the $BIG|
-v out|C|-v the $MID|
-o rare|C|-o zqxjv $BIG|
-o common|C|-o two $MID|
-n rare|C|-n zqxjv $BIG|
-n common|C|-n the $MID|
-b -o common|C|-bo two $MID|
-F 1 pattern|C|-Fc zqxjv $BIG|
-F 10 patterns|C|-Fc -f $W10 $BIG|
-F 1000 patterns|C|-Fc -f $W1 $MID|
-E alt 3 lits|C|-cE zqxjv|qqqqq|wwwww $BIG|
-E alt common|C|-cE (two|the)s? $MID|
-f 3000 words|C|-c -f $W3 $MID|
-f 3000 words -F|C|-Fc -f $W3 $MID|
-f 3000 words -w|C|-cw -f $W3 $MID|
-F 10 patterns -i|C|-Fci -f $W10 $BIG|
-E alt 4 lits -x|C|-cxE (two|the)s?|and|zqxjv $MID|
anchored ^|C|-c ^the $BIG|
anchored \$|C|-c e\$ $BIG|
-x regex|C|-cxE [a-z]+[[:space:]][a-z]+[[:space:]][a-z]+[[:space:]][a-z]+ $MID|
backref|C|-cE ([a-y])\1\1 $MID|-cP ([a-y])\1\1 $MID
classes|C|-cE [a-c]+\.[a-z]-[a-z]_d[0-9]+ $BIG|
classes line|C|-cE ^[a-m]+[[:space:]][n-z]+ $BIG|
-r tree rare|C|-r zqxjv $TREE|
-r tree -c|C|-rc the $TREE|
-r --include|C|-r --include=*.c zqxjv $TREE|-g *.c zqxjv $TREE
-r -l|C|-rl zqxjv $TREE|
utf8 -c lit|C.UTF-8|-c é $U8|
utf8 -ci lit|C.UTF-8|-ci É $U8|
utf8 . regex|C.UTF-8|-c t.e $U8|
utf8 -w -c|C.UTF-8|-cw the $U8|
EOF
}

bin() {
	case $1 in
	gnu) echo /usr/bin/grep ;;
	ours) echo "$OURS" ;;
	base) echo "$BASE" ;; # an older build of ours, for before/after tables
	rg) echo /usr/bin/rg ;;
	ugrep) echo /usr/bin/ugrep ;;
	esac
}

measure() { # tool locale args...
	t=$1
	loc=$2
	shift 2
	b=$(bin "$t")
	case $t in
	rg)
		# ripgrep: -E is an encoding flag there, regex is already extended;
		# no ignore files / hidden-file filtering, no filenames unless asked.
		set -- --no-ignore --hidden --no-config "$@"
		args=""
		for a in "$@"; do
			case $a in
			-[a-zA-Z]*)
				a=$(printf %s "$a" | sed 's/[Er]//g')
				[ "$a" = - ] && continue
				;;
			esac
			args="$args $a"
		done
		set -- $args
		;;
	ugrep) set -- --no-config "$@" ;;
	esac
	LC_ALL=$loc python3 -I "$here/grep-time.py" "$RUNS" "$b" "$@"
}

printf '| case |'
for t in $TOOLS; do printf ' %s wall / cpu ms / MB |' "$t"; done
printf '\n|---|'
for t in $TOOLS; do printf -- '---|'; done
printf '\n'
cases | while IFS= read -r line; do
	name=${line%%|*}
	rest=${line#*|}
	loc=${rest%%|*}
	rest=${rest#*|}
	# GNU args end at the last '|' (the rg override follows it)
	gargs=${rest%|*}
	rgargs=${rest##*|}
	case $ONLY in
	'') ;;
	*) case $name in *"$ONLY"*) ;; *) continue ;; esac ;;
	esac
	printf '| %s |' "$name"
	for t in $TOOLS; do
		if [ -n "$rgargs" ] && { [ "$t" = rg ] || case $rgargs in "-g "*) false ;; *) [ "$t" = ugrep ] ;; esac; }; then
			set -- $rgargs
		else
			set -- $gargs
		fi
		out=$(measure "$t" "$loc" "$@")
		set -- $out
		# wall user sys rss outbytes status
		mark=""
		[ "$6" -ge 2 ] && mark=" ERR"
		printf ' %.0f / %.0f / %d%s |' "$1" "$(echo "$2 $3" | awk '{print $1+$2}')" "$(($4 / 1024))" "$mark"
	done
	printf '\n'
done
