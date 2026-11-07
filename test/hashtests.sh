# hashtests.sh - differential cases shared by md5sum, sha1sum, sha224sum,
# sha256sum, sha384sum, sha512sum and b2sum. Sourced after testlib.sh with
# UTIL set. References: GNU manual "md5sum invocation", "sha2 utilities",
# "b2sum invocation", "cksum output modes".
H="$(mktemp -d)"; cd "$H"
printf 'hello\n' > a
printf 'world' > 'b c'
printf '' > empty
printf 'x' > 'we\ird'
mkdir -p dir
printf 'q' > "$(printf 'nl\nname')"
printf 'q' > "$(printf 'cr\rname')"
head -c 1000000 /dev/urandom > rnd
# Sizes around the block boundaries of every algorithm (64 and 128 bytes).
for n in 1 55 56 57 63 64 65 111 112 113 119 120 127 128 129 255 256 257 1023 65535 65536 65537; do
    head -c $n /dev/urandom > "len$n"
done

printf "\n[ Generating ]\n"
run_cmp "one file"                    a
run_cmp "two files"                   a 'b c'
run_cmp "empty file"                  empty
run_cmp "name with space"             'b c'
run_cmp "name with backslash"         'we\ird'
run_cmp "name with newline"           "$(printf 'nl\nname')"
run_cmp "name with CR"                "$(printf 'cr\rname')"
run_cmp "missing file"                nonexistent
run_cmp "missing among good"          a nonexistent 'b c'
run_cmp "directory"                   dir
run_cmp "-b"                          -b a
run_cmp "--binary"                    --binary a
run_cmp "-t"                          -t a
run_cmp "--text"                      --text a
run_cmp "--tag"                       --tag a
run_cmp "--tag two files"             --tag a 'b c'
run_cmp "--tag with escaped name"     --tag 'we\ird'
run_cmp "--tag -b"                    --tag -b a
run_cmp "--tag -t is an error"        --tag -t a
run_cmp "-z"                          -z a 'b c'
run_cmp "-z with escaped name"        -z 'we\ird'
run_cmp "-z --tag"                    -z --tag a
run_cmp "-- operands"                 -- a
run_cmp "-- then dash name"           -- -
for n in 1 55 56 57 63 64 65 111 112 113 119 120 127 128 129 255 256 257 1023 65535 65536 65537; do
    run_cmp "length $n"               "len$n"
done
run_cmp "1 MB random"                 rnd
CMP_STDIN=rnd run_cmp "stdin"
CMP_STDIN=rnd run_cmp "stdin explicit -"       -
CMP_STDIN=a run_cmp "stdin and file"           - a
CMP_STDIN=a run_cmp "stdin --tag"              --tag
CMP_STDIN=empty run_cmp "empty stdin"

printf "\n[ Option errors ]\n"
run_cmp "unknown option"              --bogus a
run_cmp "unknown short"               -x a
run_cmp "--quiet without -c"          --quiet a
run_cmp "--status without -c"         --status a
run_cmp "--warn without -c"           -w a
run_cmp "--strict without -c"         --strict a
run_cmp "--ignore-missing without -c" --ignore-missing a
run_cmp "-z with -c"                  -z -c a
run_cmp "--tag with -c"               --tag -c a
run_cmp "--algorithm is not ours"     -a md5 a
run_cmp "--raw is not ours"           --raw a
run_cmp "--untagged is not ours"      --untagged a
run_cmp "-c no file, empty stdin"     -c

printf "\n[ Checking ]\n"
"/usr/bin/$UTIL" a 'b c' > sums
"/usr/bin/$UTIL" --tag a 'b c' > tsums
"/usr/bin/$UTIL" -b a 'b c' > bsums
"/usr/bin/$UTIL" 'we\ird' "$(printf 'nl\nname')" "$(printf 'cr\rname')" > esums
"/usr/bin/$UTIL" --tag 'we\ird' "$(printf 'nl\nname')" > tesums
"/usr/bin/$UTIL" a empty > sums2
run_cmp "-c good"                     -c sums
run_cmp "-c tag"                      -c tsums
run_cmp "-c binary"                   -c bsums
run_cmp "-c escaped names"            -c esums
run_cmp "-c tag escaped names"        -c tesums
run_cmp "--check"                     --check sums
run_cmp "-c twice"                    -c sums sums2
run_cmp "-c --quiet good"             -c --quiet sums
run_cmp "-c --status good"            -c --status sums
run_cmp "-c --strict good"            -c --strict sums
run_cmp "-c -w good"                  -c -w sums
# Corrupt a file and a digest.
cp a a_mod; printf 'X' >> a_mod
"/usr/bin/$UTIL" a_mod > modsums
sed 's/a_mod/a/' modsums > badsums
run_cmp "-c mismatch"                 -c badsums
run_cmp "-c mismatch --quiet"         -c --quiet badsums
run_cmp "-c mismatch --status"        -c --status badsums
run_cmp "-c mismatch two"             -c badsums badsums
{ cat sums; cat badsums; } > mixsums
run_cmp "-c good and bad"             -c mixsums
run_cmp "-c good and bad --quiet"     -c --quiet mixsums
run_cmp "-c good and bad --status"    -c --status mixsums
printf 'garbage line\n' > junk
{ cat sums; cat junk; } > withjunk
run_cmp "-c only junk"                -c junk
run_cmp "-c junk --strict"            -c --strict junk
run_cmp "-c junk --warn"              -c -w junk
run_cmp "-c good plus junk"           -c withjunk
run_cmp "-c good plus junk --strict"  -c --strict withjunk
run_cmp "-c good plus junk --warn"    -c -w withjunk
run_cmp "-c good plus junk --status"  -c --status withjunk
run_cmp "-c good plus junk --quiet"   -c --quiet withjunk
printf '\n\n# comment\n' > blanks
run_cmp "-c blank and comment lines"  -c blanks
{ cat sums; printf '\n'; cat tsums; } > blend
run_cmp "-c blank line and mixed formats" -c blend
# Missing files.
"/usr/bin/$UTIL" a nonexistent_2 > misssums 2>/dev/null; printf '%s  nonexistent_2\n' "$("/usr/bin/$UTIL" empty | cut -d' ' -f1)" > misssums2
{ cat sums; cat misssums2; } > misssums
run_cmp "-c missing file"             -c misssums2
run_cmp "-c missing file and good"    -c misssums
run_cmp "-c missing --quiet"          -c --quiet misssums
run_cmp "-c missing --status"         -c --status misssums
run_cmp "-c --ignore-missing"         -c --ignore-missing misssums
run_cmp "-c --ignore-missing all missing" -c --ignore-missing misssums2
run_cmp "-c --ignore-missing none missing" -c --ignore-missing sums
run_cmp "-c listing file missing"     -c nonexistent_list
run_cmp "-c a directory as list"      -c dir
printf '%s  dir\n' "$("/usr/bin/$UTIL" empty | cut -d' ' -f1)" > dirsums
run_cmp "-c entry is a directory"     -c dirsums
# Format variants.
awk '{ printf "%s %s\n", $1, $2 }' sums | sed 's/  / /' > one_space
run_cmp "-c reversed (one space)"     -c one_space
sed 's/^\([0-9a-f]*\)/\U\1/' sums > upper
run_cmp "-c uppercase hex"            -c upper
sed 's/^\([0-9a-f]\{4\}\)/\1 /' sums > short1
run_cmp "-c digest with a space inside" -c short1
cut -c3- sums > shortdigest
run_cmp "-c short digest"             -c shortdigest
sed 's/^/0/' sums > longdigest
run_cmp "-c long digest"              -c longdigest
printf '\\%s  we\\\\ird\n' "$("/usr/bin/$UTIL" 'we\ird' | sed 's/^\\//; s/ .*//')" > esc_one
run_cmp "-c backslash escaped name"   -c esc_one
printf '\\%s  bad\\xescape\n' "$("/usr/bin/$UTIL" a | cut -d' ' -f1)" > esc_bad
run_cmp "-c bad escape"               -c esc_bad
printf '%s' "$(cat sums)" > nonl_sums
run_cmp "-c last line without newline" -c nonl_sums
CMP_STDIN=sums run_cmp "-c stdin"     -c
CMP_STDIN=sums run_cmp "-c - "        -c -
CMP_STDIN=badsums run_cmp "-c stdin mismatch" -c
CMP_STDIN=junk run_cmp "-c stdin junk" -c
# Tagged lines with a different algorithm's tag are not ours.
sed 's/^[A-Za-z0-9-]* (/FOO (/' tsums > badtag
run_cmp "-c wrong tag"                -c badtag
rm -rf "$H"
