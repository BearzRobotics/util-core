# basetests.sh - differential cases for base64, base32 and basenc. Sourced
# after testlib.sh with UTIL set and ENC_OPT set to the basenc option (or
# empty for base64/base32). References: GNU manual "base64 invocation",
# "base32 invocation", "basenc invocation"; RFC 4648.
B="$(mktemp -d)"; cd "$B"
printf '' > empty
printf 'hello world, this is a test\n' > a
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 31 32 33 56 57 58 75 76 77 100 1000 4095 4096 4097 65535 65536 65537; do
    head -c $n /dev/urandom > "r$n"
done
printf '\0\0\0\0' > zeros4
printf '\377\377\377\377\377' > ff5
# $ENC is the option selecting the encoding; "$ENC" may be empty.
ENC="$ENC_OPT"

enc() { # description, args...
    d=$1; shift
    run_cmp "$d" $ENC "$@"
}

printf "\n[ Encoding ]\n"
enc "empty"                      empty
enc "text"                       a
enc "zeros"                      zeros4
enc "0xff"                       ff5
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 31 32 33 56 57 58 75 76 77 100 1000 4095 4096 4097 65535 65536 65537; do
    enc "random $n bytes"        "r$n"
done
for w in 0 1 2 3 4 5 7 8 10 16 76 77 1000; do
    enc "-w $w text"             -w $w a
    enc "-w $w 1000 bytes"       -w $w r1000
    enc "--wrap=$w"              --wrap=$w r33
done
enc "-w 0 empty"                 -w 0 empty
enc "-w abc"                     -w abc a
enc "-w -5"                      -w -5 a
enc "-w missing arg"             -w
enc "--wrap missing arg"         --wrap
enc "-w5 attached"               -w5 a
enc "stdin"
CMP_STDIN=r1000 enc "stdin 1000"
CMP_STDIN=r1000 enc "stdin explicit -" -
enc "missing file"               nonexistent
enc "directory"                  .
enc "two files"                  a r1
enc "unknown option"             --bogus a
enc "-x"                         -x a
enc "-- operand"                 -- a

printf "\n[ Decoding round trips ]\n"
for f in empty a zeros4 ff5 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 r13 r14 r15 r16 r17 r31 r32 r33 r57 r75 r76 r77 r100 r1000 r4095 r4096 r4097 r65535 r65536 r65537; do
    $ENC_BIN $ENC "$f" > "enc_$f" 2>/dev/null || /usr/bin/$UTIL $ENC "$f" > "enc_$f"
    run_cmp "decode $f"          $ENC -d "enc_$f"
    run_cmp "decode -i $f"       $ENC -d -i "enc_$f"
    run_cmp "decode -w0 form $f" $ENC -d "enc_$f"
done
/usr/bin/$UTIL $ENC -w 0 r1000 > enc_nowrap
run_cmp "decode unwrapped"       $ENC -d enc_nowrap
/usr/bin/$UTIL $ENC -w 7 r1000 > enc_w7
run_cmp "decode wrapped at 7"    $ENC -d enc_w7
CMP_STDIN=enc_r1000 run_cmp "decode stdin"        $ENC -d
CMP_STDIN=enc_r1000 run_cmp "decode stdin -"      $ENC -d -
run_cmp "--decode"               $ENC --decode enc_r33
run_cmp "--ignore-garbage"       $ENC --decode --ignore-garbage enc_r33
run_cmp "decode missing file"    $ENC -d nonexistent
run_cmp "decode directory"       $ENC -d .
run_cmp "decode two files"       $ENC -d enc_r1 enc_r2

printf "\n[ Decoding malformed input ]\n"
# Hand-picked and generated inputs, written to files so that NULs and odd
# bytes survive. Stdout (partial output before the error), stderr and the
# exit status all have to match GNU.
n=0
try() { # printf-format string
    n=$((n + 1))
    printf "$1" > "bad$n"
    run_cmp "malformed #$n: $(printf '%s' "$1" | cut -c1-30)"   $ENC -d "bad$n"
    run_cmp "malformed -i #$n"                                   $ENC -d -i "bad$n"
}
for s in 'Y' 'YQ' 'YQ=' 'YQ==' 'YQ===' 'YWJj' 'YWJjZ' 'YWJjZA' 'YWJjZA=' 'YWJjZA==' 'YWJj\nZA==' '====' 'YQ==YQ==' 'YQ==YQ' 'Y=' 'YQ=Q' 'YW=j' 'YWJ=' 'YWJ=Z' '!!!!' 'YW!j' 'YWJj!' '=' 'YWJj==' 'YR==' 'YWK=' ' YWJj' 'YWJj ' 'YW Jj' 'YWJj\r\n' '\n\n\nYWJj\n\n' 'YWJj\0' '\0' '-_-_' '+/+/' 'a' 'ab' 'abc' 'abcd' 'abcde' '12345678' \
         'ME======' 'ME=====' 'MFRA====' 'MFRGG===' 'MFRGGZA=' 'MFRGGZDF' 'M' 'MFRGGZDFMY======' 'MFRGGZDFMY' 'ME======ME======' 'me======' 'M1======' 'MF======' 'MFRGGZ==' 'MFRGGZDFM' 'MFRGGZDFMYT=' 'ME=====A' '========' 'MFRA=A==' \
         '00' '0' '0g' 'ff' 'FF' 'Ff' 'abc' '0A1B2C' '4142' '41424' \
         '01000001' '0100000' '010000011' '0100000a' '01000001\n01000010' '' '\n' \
         '0123456789' 'hello' '!!!!!' '00000' 'HelloWorld' 'ooooo' 'ooooooooooo' '%%%%%'; do
    try "$s"
done
print_garbage() { # seed count alphabet-extra -> lines
    awk -v seed="$1" -v n="$2" -v extra="$3" 'BEGIN {
        srand(seed)
        al = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-_" extra
        for (i = 0; i < n; i++) {
            len = int(rand() * 30); s = ""
            for (j = 0; j < len; j++) {
                r = rand()
                if (r < 0.06) s = s "\\n"
                else if (r < 0.10) s = s "="
                else s = s substr(al, 1 + int(rand() * length(al)), 1)
            }
            print s
        } }'
}
g=0
for seed in 1 2 3 4; do
    for line in $(print_garbage $seed 60 '!'); do
        g=$((g + 1))
        printf "$line" > "gar$g"
        run_cmp "garbage seed $seed #$g"      $ENC -d "gar$g"
        run_cmp "garbage -i seed $seed #$g"   $ENC -d -i "gar$g"
    done
done
rm -rf "$B"
