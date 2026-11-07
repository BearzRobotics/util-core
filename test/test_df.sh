#!/bin/sh
# df: differential tests against GNU df 9.7 (C locale). References: GNU
# manual "df invocation", POSIX df. Usage numbers of live file systems change
# between the two runs, so each comparison is retried a few times and the
# stable columns (--output=...) are used where the numbers are not the point.
UTIL="df"
. "$(dirname "$0")/testlib.sh"
help_cmp

# retry_cmp DESC ARG...: like run_cmp, but a mismatch is retried (live data).
retry_cmp() {
    description="$1"; shift
    n=0
    while :; do
        LC_ALL=C gnu "$@" < /dev/null > "$TMPDIR_CMP.go" 2> "$TMPDIR_CMP.ge"; gx=$?
        ours "$@" < /dev/null > "$TMPDIR_CMP.oo" 2> "$TMPDIR_CMP.oe"; ox=$?
        norm_err < "$TMPDIR_CMP.ge" > "$TMPDIR_CMP.ge2"; norm_err < "$TMPDIR_CMP.oe" > "$TMPDIR_CMP.oe2"
        if cmp -s "$TMPDIR_CMP.go" "$TMPDIR_CMP.oo" && cmp -s "$TMPDIR_CMP.ge2" "$TMPDIR_CMP.oe2" && [ "$gx" = "$ox" ]; then
            PASS=$((PASS + 1)); printf "PASS %s\n" "$description"; return
        fi
        n=$((n + 1))
        [ "$n" -ge 8 ] && break
        sleep 0.2
    done
    FAIL=$((FAIL + 1)); printf "FAIL %s\n" "$description"
    printf "     GNU  (rc=%s) out: %s err: %s\n" "$gx" "$(cat -A "$TMPDIR_CMP.go" | head -30)" "$(cat -A "$TMPDIR_CMP.ge2")"
    printf "     OURS (rc=%s) out: %s err: %s\n" "$ox" "$(cat -A "$TMPDIR_CMP.oo" | head -30)" "$(cat -A "$TMPDIR_CMP.oe2")"
}

W="$(mktemp -d)"; cd "$W"
mkdir sub; : > file; ln -s file lnk; ln -s sub dlnk; ln -s /nonexistent dang
STABLE="--output=source,fstype,itotal,size,target"

printf "\n[ Listing ]\n"
retry_cmp "default"
for o in -a -h -H -i -T -P -k -m "-B 1M" "-B 1000" "-B 4096" "-B K" "-B KB" "-B human-readable" "-B si" --total "-l" "-t tmpfs" "-t ext4" "-t tmpfs -t ext4" "-x tmpfs" "-x tmpfs -x ext4" "-a -T" "-ahT" "-aiT" "-hT --total" "-iT --total" "-l -T" "-P -T" "-P -k" "-P -m" "-i -h" "-i -k" "-i -P" "-hi" "-Hi" "--sync" "--no-sync" -v "-t nosuchfs" "-a -t proc" "-a -x proc" "-a -l" "-a --total" "-aP" "-aH" "--output" "--output=source" "--output=source,target" "--output=file" "--output=pcent,ipcent,avail,iavail,used,iused,size,itotal,fstype,source,target,file" "--output=size,used,avail --total" "--output -h" "--output=size -h" "--output=size -H" "--output=size -k" "--output=size -m" "--output=size -B 1M" "--output=size -B 1000" "--output=size -B 4096" "--output=size -BKB" "--output=size,used -P" "--output=source -a" "--output=target -a" "--output=itotal -i" "--output=fstype -T"; do
    retry_cmp "$o"          $o
done
for e in DF_BLOCK_SIZE BLOCK_SIZE BLOCKSIZE; do
    for v in 1 1K 1M 4096 human-readable si 1KB zz 0 ''; do
        eval "$e='$v' retry_cmp '$e=$v' ''" 2>/dev/null
    done
done
POSIXLY_CORRECT=1 retry_cmp "POSIXLY_CORRECT -P" -P
POSIXLY_CORRECT=1 retry_cmp "POSIXLY_CORRECT" -P -k
DF_BLOCK_SIZE=1M retry_cmp "DF_BLOCK_SIZE -P" -P

printf "\n[ Arguments ]\n"
for f in / /tmp /proc /dev /dev/shm /sys . .. sub file lnk dlnk dang /dev/null /dev/sdd /dev/zero /mnt/c /usr /usr/bin /etc/passwd "$W" "$W/sub" /proc/self /proc/self/fd /nonexistent ""; do
    retry_cmp "arg $f"        "$f"
    retry_cmp "arg -h $f"     -h "$f"
    retry_cmp "arg -T $f"     -T "$f"
    case "$f" in "$W"*|/tmp*|.|..|sub|file|lnk|dlnk) ;; *) retry_cmp "arg -i $f"     -i "$f" ;; esac
    retry_cmp "arg -a $f"     -a "$f"
    retry_cmp "arg --output $f" $STABLE "$f"
done
retry_cmp "several args"     / /tmp /proc /dev/null
retry_cmp "several args -T"  -T / /tmp /proc /dev/null nosuch
retry_cmp "args --total"     --total / /tmp /usr
retry_cmp "args --total -h"  --total -h / /tmp /usr
retry_cmp "args -t"          -t tmpfs / /tmp /proc
retry_cmp "args -t ext4"     -t ext4 / /tmp
retry_cmp "args -x"          -x tmpfs / /tmp
retry_cmp "args -l"          -l / /tmp /mnt/c
retry_cmp "args dup"         / /
retry_cmp "args missing + ok" nosuch /
retry_cmp "args -P"          -P / /tmp
retry_cmp "args --output"    $STABLE / /tmp /proc /dev
retry_cmp "args --output file" --output=file,target / /tmp .
retry_cmp "-t and -x same"   -t ext4 -x ext4
retry_cmp "-t and -x same /" -t ext4 -x ext4 /
retry_cmp "-F"               -F ext4
retry_cmp "-- args"          -- /

printf "\n[ Usage ]\n"
retry_cmp "bad option"       -z
retry_cmp "bad long option"  --bogus
retry_cmp "amb option"       --s
retry_cmp "-B bad"           -B zz
retry_cmp "-B 1x"            -B 1x
retry_cmp "-B empty"         -B ''
retry_cmp "-B 0"             -B 0
retry_cmp "-B big"           -B 99999999999999999999999
retry_cmp "--block-size bad" --block-size=zz
retry_cmp "-B missing"       -B
retry_cmp "--output bad"     --output=bogus
retry_cmp "--output dup"     --output=source,source
retry_cmp "--output empty"   --output=
retry_cmp "--output ,"       --output=,
retry_cmp "--output trailing" --output=source,
retry_cmp "-i --output"      -i --output
retry_cmp "--output -i"      --output -i
retry_cmp "-T --output"      -T --output
retry_cmp "--output -T"      --output -T
retry_cmp "-P --output"      -P --output
retry_cmp "--output -P"      --output -P
retry_cmp "-P -i --output"   -P -i --output
retry_cmp "--output -P -i"   --output -P -i
retry_cmp "-t missing arg"   -t
retry_cmp "-x missing arg"   -x

cd /; print_summary
