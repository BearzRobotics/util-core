#!/bin/sh
# cksum: differential tests against GNU cksum 9.7 (C locale). References: GNU
# manual "cksum invocation" and "cksum output modes"; POSIX.1-2024 cksum.
UTIL="cksum"
. "$(dirname "$0")/testlib.sh"
H="$(mktemp -d)"; cd "$H"
printf 'hello\n' > a
printf 'world' > 'b c'
printf '' > empty
printf 'x' > 'we\ird'
mkdir -p dir
head -c 1000000 /dev/urandom > rnd
for n in 1 3 4 5 55 56 63 64 65 127 128 129 255 1023 65535 65536 65537; do head -c $n /dev/urandom > "len$n"; done
ALGOS="sysv bsd crc crc32b md5 sha1 sha224 sha256 sha384 sha512 blake2b sm3"

printf "\n[ Default (crc) ]\n"
run_cmp "one file"               a
run_cmp "two files"              a 'b c'
run_cmp "empty"                  empty
run_cmp "missing"                nonexistent
run_cmp "directory"              dir
run_cmp "name with backslash"    'we\ird'
CMP_STDIN=a run_cmp "stdin (no name)"
CMP_STDIN=a run_cmp "stdin explicit -"      -
CMP_STDIN=a run_cmp "stdin and file"        - a
run_cmp "1 MB"                   rnd
for f in len1 len3 len4 len5 len55 len56 len63 len64 len65 len127 len128 len129 len255 len1023 len65535 len65536 len65537; do
    run_cmp "crc $f"             $f
done

printf "\n[ Algorithms ]\n"
for al in $ALGOS; do
    for f in a empty 'b c' len1 len63 len64 len65 len127 len128 len129 len65537 rnd; do
        run_cmp "-a $al $f"                -a $al "$f"
    done
    run_cmp "-a $al two files"             -a $al a 'b c'
    run_cmp "-a $al --untagged"            -a $al --untagged a 'b c'
    run_cmp "-a $al --tag"                 -a $al --tag a
    run_cmp "-a $al -z"                    -a $al -z a 'b c'
    run_cmp "-a $al --base64"              -a $al --base64 a
    run_cmp "-a $al --base64 --untagged"   -a $al --base64 --untagged a empty
    run_cmp "-a $al --raw"                 -a $al --raw a
    run_cmp "-a $al --raw empty"           -a $al --raw empty
    run_cmp "-a $al --raw two files"       -a $al --raw a 'b c'
    run_cmp "-a$al attached"               -a$al a
    run_cmp "--algorithm=$al"              --algorithm=$al a
    CMP_STDIN=a run_cmp "-a $al stdin"     -a $al
    CMP_STDIN=a run_cmp "-a $al stdin -"   -a $al -
    run_cmp "-a $al name escaped"          -a $al 'we\ird'
done
run_cmp "-a bogus"                -a bogus a
run_cmp "-a missing arg"          -a
run_cmp "-a prefix abbreviation"  -a sha a
run_cmp "-a upper case"           -a MD5 a

printf "\n[ blake2b length ]\n"
for l in 0 8 16 128 256 384 504 512 520 1024; do
    run_cmp "-a blake2b -l $l"          -a blake2b -l $l a
    run_cmp "-a blake2b -l $l untagged" -a blake2b -l $l --untagged a
done
run_cmp "-l 7"                    -a blake2b -l 7 a
run_cmp "-l abc"                  -a blake2b -l abc a
run_cmp "-l -8"                   -a blake2b -l -8 a
run_cmp "--length=64"             -a blake2b --length=64 a
run_cmp "-l with md5 is an error" -a md5 -l 128 a
run_cmp "-l with default crc"     -l 128 a

printf "\n[ Option combinations ]\n"
run_cmp "--tag --untagged"        --tag --untagged -a md5 a
run_cmp "--untagged crc"          --untagged a
run_cmp "--tag crc"               --tag a
run_cmp "--raw crc"               --raw a
run_cmp "--raw crc32b"            -a crc32b --raw a
run_cmp "--raw bsd"               -a bsd --raw a
run_cmp "--raw sysv"              -a sysv --raw a
run_cmp "--raw two files"         --raw a 'b c'
run_cmp "-b ignored?"             -b a
run_cmp "-t ignored?"             -t a
run_cmp "-z crc"                  -z a 'b c'
run_cmp "--base64 crc"            --base64 a
# --debug prints CPU-feature notes that depend on the machine; not compared.
run_cmp "unknown option"          --bogus a
run_cmp "--quiet without -c"      --quiet a
run_cmp "--status without -c"     --status a
run_cmp "--zero with -c"          -z -c a

printf "\n[ Checking ]\n"
for al in md5 sha1 sha224 sha256 sha384 sha512 blake2b sm3; do
    cksum_out() { "/usr/bin/cksum" "$@"; }
    cksum_out -a $al a 'b c' > t_$al                    # tagged (default)
    cksum_out -a $al --untagged a 'b c' > u_$al         # untagged
    cksum_out -a $al --base64 a 'b c' > b_$al           # tagged base64
    cksum_out -a $al --base64 --untagged a 'b c' > ub_$al
    run_cmp "-c tagged $al"                 -c t_$al
    run_cmp "-c untagged $al with -a"       -c -a $al u_$al
    run_cmp "-c untagged $al without -a"    -c u_$al
    run_cmp "-c base64 tagged $al"          -c b_$al
    run_cmp "-c base64 untagged $al with -a" -c -a $al ub_$al
    run_cmp "-c tagged $al --quiet"         -c --quiet t_$al
    run_cmp "-c tagged $al --status"        -c --status t_$al
done
cat t_md5 t_sha1 t_sha256 t_sha512 t_blake2b t_sm3 > t_mixed
run_cmp "-c mixed algorithms"        -c t_mixed
cp a a_mod; printf X >> a_mod
cksum_out -a sha256 a_mod | sed 's/a_mod/a/' > t_bad
run_cmp "-c tagged mismatch"         -c t_bad
run_cmp "-c tagged mismatch --quiet" -c --quiet t_bad
run_cmp "-c tagged mismatch --status" -c --status t_bad
printf 'junk\n' > junk
run_cmp "-c junk"                    -c junk
run_cmp "-c junk -w"                 -c -w junk
cat t_md5 junk > t_junk
run_cmp "-c good plus junk"          -c t_junk
run_cmp "-c good plus junk --strict" -c --strict t_junk
run_cmp "-c good plus junk -w"       -c -w t_junk
run_cmp "-c legacy crc is an error"  -c -a crc t_md5
run_cmp "-c legacy sysv is an error" -c -a sysv t_md5
run_cmp "-c legacy bsd is an error"  -c -a bsd t_md5
run_cmp "-c crc32b is an error"      -c -a crc32b t_md5
cksum_out -a sha256 nonexistent_2 2>/dev/null; printf 'SHA256 (nonexistent_2) = %s\n' "$(cksum_out -a sha256 empty | sed 's/.* = //')" > t_miss
run_cmp "-c missing file"            -c t_miss
run_cmp "-c --ignore-missing"        -c --ignore-missing t_miss
run_cmp "-c listing missing"         -c nonexistent_list
CMP_STDIN=t_sha256 run_cmp "-c stdin" -c
CMP_STDIN=t_sha256 run_cmp "-c stdin -" -c -
cksum_out -a sha256 'we\ird' > t_esc
run_cmp "-c escaped name"            -c t_esc

printf "\n[ Large and boundary inputs ]\n"
for al in md5 sha1 sha256 sha512 blake2b sm3 crc crc32b; do
    for f in len1 len55 len56 len64 len65 len127 len128 len129 len255 len65535 len65536 len65537; do
        [ -f "$f" ] || head -c ${f#len} /dev/urandom > "$f"
        run_cmp "$al $f"             -a $al "$f"
    done
done
print_summary
