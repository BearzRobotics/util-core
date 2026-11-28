#!/bin/sh
# md5sum: differential tests against GNU md5sum 9.7 (C locale); see hashtests.sh.
UTIL="md5sum"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/hashtests.sh"
# Input is worked through as it arrives, in little memory.
n=$(yes 'd41d8cd98f00b204e9800998ecf8427e  /dev/null' | (ulimit -v 200000; timeout 60 "$BIN_DIR/md5sum" -c 2>&1) | head -n 200000 | cksum)
g=$(yes 'd41d8cd98f00b204e9800998ecf8427e  /dev/null' | LC_ALL=C timeout 60 "${GNU_BIN:-/usr/bin}/md5sum" -c 2>&1 | head -n 200000 | cksum)
if [ "$n" = "$g" ]; then PASS=$((PASS + 1)); echo "PASS endless input"; else FAIL=$((FAIL + 1)); echo "FAIL endless input: GNU $g, ours $n"; fi
first=$( (echo 'd41d8cd98f00b204e9800998ecf8427e  /dev/null'; sleep 3) | timeout 2 "$BIN_DIR/md5sum" -c 2>/dev/null | head -n 1)
if [ -n "$first" ]; then PASS=$((PASS + 1)); echo "PASS a line is answered before the input ends"; else FAIL=$((FAIL + 1)); echo "FAIL no output before the end of input"; fi
# A list on standard input cannot name it.
list='d41d8cd98f00b204e9800998ecf8427e  -'
g=$(echo "$list" | LC_ALL=C "${GNU_BIN:-/usr/bin}/md5sum" -c -w 2>&1; echo "status $?")
n=$(echo "$list" | LC_ALL=C "$BIN_DIR/md5sum" -c -w 2>&1; echo "status $?")
if [ "$g" = "$n" ]; then PASS=$((PASS + 1)); echo "PASS - in a list on stdin"; else FAIL=$((FAIL + 1)); printf 'FAIL - in a list on stdin\n%s\n---\n%s\n' "$g" "$n"; fi
# A list with CR LF line ends, as written on Windows.
echo hi > "$TEST_TMP/good"
(cd "$TEST_TMP" && printf '%s  good\r\n# c\r\n\r\n%s *good\r\nMD5 (good) = %s\r\n' \
    $(for i in 1 2 3; do md5sum good | cut -d' ' -f1; done) > crlf)
g=$(cd "$TEST_TMP" && LC_ALL=C "${GNU_BIN:-/usr/bin}/md5sum" -c -w crlf 2>&1; echo "status $?")
n=$(cd "$TEST_TMP" && LC_ALL=C "$BIN_DIR/md5sum" -c -w crlf 2>&1; echo "status $?")
if [ "$g" = "$n" ]; then PASS=$((PASS + 1)); echo "PASS CR LF list"; else FAIL=$((FAIL + 1)); printf 'FAIL CR LF list\n%s\n---\n%s\n' "$g" "$n"; fi
# Leading blanks, and tagged lines written as OpenSSL does (MISC-029).
printf 'b\n' > "$TEST_TMP/tagged"
sum=$(/usr/bin/md5sum < "$TEST_TMP/tagged" | cut -d' ' -f1)
for form in '   %s  tagged' '\t%s  tagged' 'MD5(tagged)= %s' 'MD5(tagged)=%s' 'MD5 (tagged)\t=  %s' \
    '  MD5 (tagged) = %s' 'MD5  (tagged) = %s' 'MD5 (tagged) = %s ' 'MD5 (tagged) %s'; do
    # shellcheck disable=SC2059
    printf "$form\n" "$sum" > "$TEST_TMP/tagged.sums"
    g=$(cd "$TEST_TMP" && LC_ALL=C /usr/bin/md5sum -c tagged.sums 2>/dev/null; echo $?)
    n=$(cd "$TEST_TMP" && LC_ALL=C "$BIN_DIR/md5sum" -c tagged.sums 2>/dev/null; echo $?)
    if [ "$g" = "$n" ]; then PASS=$((PASS + 1)); echo "PASS check line '$form'"
    else FAIL=$((FAIL + 1)); printf 'FAIL check line %s\n%s\n---\n%s\n' "$form" "$g" "$n"; fi
done

print_summary
