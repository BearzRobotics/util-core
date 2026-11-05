#!/bin/sh
# paste: differential tests against GNU paste. References: GNU manual "paste
# invocation"; POSIX.1-2024 paste.
UTIL="paste"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"
printf '1\n2\n' > num2
printf 'a\nb\nc\n' > let3
printf 'x\ny\nz\nw\nv\n' > five
: > empty
printf 'no newline' > nonl
printf 'a\0b\0c\0' > nul
printf '1\n2\n3\n4\n5\n6\n' > six

printf "\n[ Parallel ]\n"
run_cmp "two files"               num2 let3
run_cmp "three files"             num2 let3 five
run_cmp "same file twice"         let3 let3
run_cmp "longer first"            let3 num2
run_cmp "empty file"              empty let3
run_cmp "empty both"              empty empty
run_cmp "no trailing newline"     nonl let3
run_cmp "no trailing newline last" let3 nonl
run_cmp "single file"             let3
run_cmp "-d ,"                    -d, num2 let3
run_cmp "-d list cycles"          -d '%_' num2 let3 num2
run_cmp "-d list three files"     -d ',;' let3 let3 let3 let3
run_cmp "-d with \\n"             -d '\n' num2 let3
run_cmp "-d with \\t"             -d '\t:' num2 let3 num2
run_cmp "-d \\\\"                 -d '\\' num2 let3
run_cmp "-d \\0 is empty"         -d '\0' num2 let3
run_cmp "-d '\\0,'"               -d '\0,' num2 let3 num2
run_cmp "-d ' '"                  -d ' ' num2 let3
run_cmp "--delimiters=:"          --delimiters=: num2 let3
run_cmp "-d empty list"           -d '' num2 let3
run_cmp "-z"                      -z nul nul
run_cmp "--zero-terminated"       --zero-terminated nul nul

printf "\n[ Serial ]\n"
run_cmp "-s"                      -s num2 let3
run_cmp "--serial"                --serial num2 let3
run_cmp "-s empty file"           -s empty let3
run_cmp "-s empty only"           -s empty
run_cmp "-s -d"                   -s -d ',' let3
run_cmp "-s -d cycle"             -s -d ',;' five
run_cmp "-s -d resets per file"   -s -d ',;' five let3
run_cmp "-s no trailing newline"  -s nonl
run_cmp "-sd"                     -sd: let3
run_cmp "-s -z"                   -s -z nul
run_cmp "-s \\n delimiter"        -s -d '\n' let3

printf "\n[ stdin ]\n"
CMP_STDIN="$W/six"
run_cmp "no operands (stdin)"
run_cmp "- alone"                 -
run_cmp "- -"                     - -
run_cmp "- - -"                   - - -
run_cmp "paste - file -"          - let3 -
run_cmp "file - file"             num2 - let3
run_cmp "-s -"                    -s -
run_cmp "-s - -"                  -s - -
run_cmp "-d ' ' - -"              -d ' ' - -
run_cmp "-d ',;' - - -"           -d ',;' - - -

printf "\n[ Errors ]\n"
run_cmp "missing file"            nope
run_cmp "missing among files"     num2 nope let3
run_cmp "trailing backslash"      -d 'a\' num2 let3
run_cmp "invalid option"          -x num2
run_cmp "unrecognized long"       --nope num2
run_cmp "-d missing arg"          -d
run_cmp "-- then file"            -- num2

cd /; rm -rf "$W"
print_summary
