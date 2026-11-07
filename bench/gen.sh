#!/bin/sh
# gen.sh DIR - write the benchmark input files into DIR (deterministic seeds).
dir=$1; mkdir -p "$dir"; cd "$dir" || exit 1
export LC_ALL=C
[ -s text.txt ] || awk 'BEGIN { srand(1); split("apple Banana cherry date Elder fig", w, " ")
    for (i = 0; i < 300000; i++)
        printf "%s%d %d %.4f the quick brown fox\n", w[1 + int(rand() * 6)], int(rand() * 99999), int(rand() * 2000001) - 1000000, rand() }' > text.txt
[ -s sorted.txt ] || sort text.txt > sorted.txt
[ -s sorted2.txt ] || awk 'NR % 3 != 0' sorted.txt > sorted2.txt
[ -s csv.txt ] || awk 'BEGIN { srand(2)
    for (i = 0; i < 300000; i++) printf "id%d,%s,%d,%.3f,field%d\n", i, (rand() < 0.5 ? "alpha" : "beta"), int(rand() * 100000), rand() * 1000, int(rand() * 50) }' > csv.txt
[ -s tabs.txt ] || awk 'BEGIN { srand(3)
    for (i = 0; i < 300000; i++) printf "\tcol%d\t\tvalue %d\t  trailing  spaces   here\n", i, int(rand() * 1000) }' > tabs.txt
[ -s wide.txt ] || awk 'BEGIN { srand(4)
    for (i = 0; i < 40000; i++) { s = ""; n = 20 + int(rand() * 40); for (j = 0; j < n; j++) s = s sprintf("w%d ", int(rand() * 99999)); print s } }' > wide.txt
[ -s graph.txt ] || awk 'BEGIN { srand(5)
    for (i = 0; i < 200000; i++) { a = int(rand() * 100000); b = a + 1 + int(rand() * 50); printf "n%d n%d\n", a, b } }' > graph.txt
