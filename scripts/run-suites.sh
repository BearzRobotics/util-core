#!/bin/sh
# Run the differential suites that are safe to run unattended, against
# zig-out/bin. Needs the GNU tools; see scripts/suites-container.sh.
#
# Every test/test_*.sh must be named below, in RUN or in SKIP, so that a new
# suite is neither forgotten nor run before someone has looked at it.
cd "$(dirname "$0")/.." || exit 2

RUN="arch b2sum base32 base64 basename basenc cat chroot cksum cmp cmp_json comm cp
csplit cut date date_json dd df_json diff diff3 diff3_json diff_json dir dircolors dirname du
du_json echo env expand expr factor false find find_json fmt fold grep grep_ext
grep_scan hashsum_json head hostid install join less link ln locate logname ls
ls_extras ls_json md5sum mkdir mkfifo mknod mktemp mv nice nl nohup nproc numfmt od
paste pathchk pr printenv printenv_json printf ptx pwd readlink realpath rmdir sdiff
sdiff_json sed seq sha1sum sha224sum sha256sum sha384sum sha512sum shred shuf sigpipe
sleep sort split stat stat_json stdbuf sum tac tail tee test time timeout touch tr
tree true truncate tsort unexpand uniq unlink updatedb users vdir wc wc_json whoami
xargs yes"

# sync and df call sync on the whole system. rm runs `rm -rf /` forms and needs a
# read-only root. The windows suites need a Windows build and wine or a machine.
SKIP="sync df rm windows_vm windows_wine"

for f in test/test_*.sh; do
    n=${f#test/test_}; n=${n%.sh}
    case " $(echo $RUN $SKIP) " in
    *" $n "*) ;;
    *) echo "run-suites: $f is in neither RUN nor SKIP" >&2; exit 2 ;;
    esac
done

[ -x zig-out/bin/ls ] || { echo "run-suites: build first (zig build -Doptimize=ReleaseSafe)" >&2; exit 2; }

log=$(mktemp) || exit 2
trap 'rm -f "$log"' EXIT
failed=
for n in ${*:-$RUN}; do
    # The memory cap: a tool that holds endless input must not take the machine down.
    (ulimit -v 4000000; timeout 900 sh "test/test_$n.sh") >"$log" 2>&1 </dev/null
    status=$?
    if [ "$status" -eq 0 ]; then
        echo "ok   $n"
    else
        echo "FAIL $n (status $status)"
        grep -A 2 'FAIL' "$log" | head -n 60
        tail -n 5 "$log"
        failed="$failed $n"
    fi
done

if [ -n "$failed" ]; then
    echo "run-suites: failed:$failed"
    exit 1
fi
echo "run-suites: all passed"
