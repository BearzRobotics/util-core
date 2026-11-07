#!/bin/sh
# rm: differential tests against GNU rm 9.7 (C locale) using run_tree. Answers
# for prompts come from TREE_STDIN; without it standard input is /dev/null.
UTIL="rm"
. "$(dirname "$0")/testlib.sh"
S='echo x > a; : > empty; echo y > b; mkdir d; echo z > d/f; mkdir d/sub; echo w > d/sub/g; mkdir e; ln -s a sl; ln -s d sd; ln -s nowhere dang; mkfifo ff; echo r > ro; chmod 444 ro; mkdir full; touch full/1 full/2 full/3; mkdir ro_dir; touch ro_dir/f; chmod 555 ro_dir; touch "sp ace"'
yes_all="$(mktemp)"; yes y | head -50 > "$yes_all"
no_all="$(mktemp)"; yes n | head -50 > "$no_all"
mixed="$(mktemp)"; printf 'y\nn\ny\nn\ny\nn\ny\nn\n' > "$mixed"

printf "\n[ Plain removal ]\n"
for f in a empty sl sd dang ff ro "sp ace" nofile e d d/f d/sub; do
    run_tree "rm $f"               "$S" "$f"
    run_tree "rm -f $f"            "$S" -f "$f"
    run_tree "rm -r $f"            "$S" -r "$f"
    run_tree "rm -rf $f"           "$S" -rf "$f"
    run_tree "rm -d $f"            "$S" -d "$f"
    run_tree "rm -v $f"            "$S" -v "$f"
    run_tree "rm -rv $f"           "$S" -rv "$f"
done
run_tree "several"                 "$S" a b empty
run_tree "several with missing"    "$S" a nofile b
run_tree "several -f missing"      "$S" -f a nofile b
run_tree "-R"                      "$S" -R d
run_tree "--recursive"             "$S" --recursive d
run_tree "--force"                 "$S" --force nofile
run_tree "--dir"                   "$S" --dir e
run_tree "--verbose"               "$S" --verbose a
run_tree "-rf on missing"          "$S" -rf nofile
run_tree "-rd"                     "$S" -rd d
run_tree "-r on file"              "$S" -r a
run_tree "-r symlink to dir"       "$S" -r sd
run_tree "-r symlink to dir slash" "$S" -r sd/
run_tree "rm sd/ (no -r)"          "$S" sd/
run_tree "trailing slash on file"  "$S" a/
run_tree "trailing slash on dir"   "$S" -r d/
run_tree "double slash"            "$S" -r d//
run_tree "path with dots"          "$S" ./a
run_tree "dir/sub with dots"       "$S" -r ./d/./sub
run_tree "read-only dir contents"  "$S" -r ro_dir
run_tree "-rf read-only dir"       "$S" -rf ro_dir
run_tree "file in read-only dir"   "$S" ro_dir/f
run_tree "deep tree"               'mkdir -p t/a/b/c t/d; touch t/a/b/c/f t/a/x t/d/y t/z' -r t
run_tree "deep tree -v"            'mkdir -p t/a/b/c t/d; touch t/a/b/c/f t/a/x t/d/y t/z' -rv t
run_tree "empty dir -r"            "$S" -r e
run_tree "many files"              'mkdir t; i=0; while [ $i -lt 50 ]; do : > t/f$i; i=$((i+1)); done' -rv t

printf "\n[ Protected names and root ]\n"
for f in . .. ./ ../ d/. d/.. ./. d/./ /; do
    run_tree "rm -r $f"            "$S" -r "$f"
    run_tree "rm -rf $f"           "$S" -rf "$f"
    run_tree "rm -d $f"            "$S" -d "$f"
done
run_tree "rm -r /."                "$S" -r /.
run_tree "rm -r //"                "$S" -r //
run_tree "rm -r /../"              "$S" -r /../
run_tree "--no-preserve-root dot"  "$S" -r --no-preserve-root .
run_tree "--preserve-root /"       "$S" -r --preserve-root /
run_tree "--preserve-root=all /"   "$S" -r --preserve-root=all /
run_tree "--preserve-root=bad"     "$S" -r --preserve-root=bad /
run_tree "preserve-root, no -r"    "$S" /
run_tree "rm /etc (no -r)"         "$S" /etc

printf "\n[ Interactive ]\n"
for f in a empty sl ff ro d dang; do
    TREE_STDIN="$yes_all" run_tree "-i yes $f"     "$S" -i "$f"
    TREE_STDIN="$no_all"  run_tree "-i no $f"      "$S" -i "$f"
    TREE_STDIN="$yes_all" run_tree "-ri yes $f"    "$S" -ri "$f"
    TREE_STDIN="$no_all"  run_tree "-ri no $f"     "$S" -ri "$f"
    TREE_STDIN="$mixed"   run_tree "-ri mixed $f"  "$S" -ri "$f"
    TREE_STDIN="$mixed"   run_tree "-rvi mixed $f" "$S" -rvi "$f"
done
TREE_STDIN="$yes_all" run_tree "-i several"        "$S" -i a b empty
TREE_STDIN="$mixed"   run_tree "-i several mixed"  "$S" -i a b empty nofile
TREE_STDIN="$yes_all" run_tree "-i nonexistent"    "$S" -i nofile
TREE_STDIN="$yes_all" run_tree "-if (force wins)"  "$S" -if a
TREE_STDIN="$yes_all" run_tree "-fi (interactive wins)" "$S" -fi a
TREE_STDIN="$yes_all" run_tree "--interactive"     "$S" --interactive a
TREE_STDIN="$yes_all" run_tree "--interactive=always" "$S" --interactive=always a
TREE_STDIN="$no_all"  run_tree "--interactive=never" "$S" --interactive=never a
TREE_STDIN="$yes_all" run_tree "--interactive=bogus" "$S" --interactive=bogus a
TREE_STDIN="$yes_all" run_tree "--interactive=n"   "$S" --interactive=n a
TREE_STDIN="$yes_all" run_tree "-i answer Y"       "$S" -i a
printf 'Y\n' > ansY; TREE_STDIN="$PWD/ansY" run_tree "-i capital Y" "$S" -i a
printf 'yes\n' > ansyes; TREE_STDIN="$PWD/ansyes" run_tree "-i word yes" "$S" -i a
printf 'nope\n' > ansnope; TREE_STDIN="$PWD/ansnope" run_tree "-i word nope" "$S" -i a
printf '\n' > ansnl; TREE_STDIN="$PWD/ansnl" run_tree "-i empty answer" "$S" -i a
printf 'y' > ansnonl; TREE_STDIN="$PWD/ansnonl" run_tree "-i y without newline" "$S" -i a

printf "\n[ -I and --interactive=once ]\n"
for n in 1 2 3 4 5; do
    files="f1"; i=2; while [ $i -le $n ]; do files="$files f$i"; i=$((i+1)); done
    setup='for x in f1 f2 f3 f4 f5; do echo $x > $x; done; mkdir dd; touch dd/x'
    TREE_STDIN="$yes_all" run_tree "-I $n files yes"      "$setup" -I $files
    TREE_STDIN="$no_all"  run_tree "-I $n files no"       "$setup" -I $files
    TREE_STDIN="$yes_all" run_tree "-Ir $n files yes"     "$setup" -Ir $files
    TREE_STDIN="$no_all"  run_tree "-Ir $n files no"      "$setup" -Ir $files
    TREE_STDIN="$yes_all" run_tree "--interactive=once $n" "$setup" --interactive=once $files
done
TREE_STDIN="$yes_all" run_tree "-I dir without -r"  'mkdir dd; touch dd/x' -I dd dd dd dd
TREE_STDIN="$yes_all" run_tree "-Ir dir"            'mkdir dd; touch dd/x' -Ir dd
TREE_STDIN="$no_all"  run_tree "-Ir dir no"         'mkdir dd; touch dd/x' -Ir dd
TREE_STDIN="$yes_all" run_tree "-I then -i"         "$S" -I -i a
TREE_STDIN="$yes_all" run_tree "-i then -I"         "$S" -i -I a b
TREE_STDIN="$yes_all" run_tree "-If"                "$S" -If a b empty ro

printf "\n[ Option forms and errors ]\n"
run_tree "no operand"              "$S"
run_tree "-f no operand"           "$S" -f
run_tree "-x"                      "$S" -x a
run_tree "--bogus"                 "$S" --bogus a
run_tree "--"                      'echo x > ./-a' -- -a
run_tree "-a (not an option)"      'echo x > ./-a' -a
run_tree "--force=x"               "$S" --force=x a
run_tree "empty name"              "$S" ''
run_tree "empty name -f"           "$S" -f ''
run_tree "name with newline"       'touch "a
b"' "a
b"
run_tree "name with quote"         "touch \"it's\"" "it's"
run_tree "unreadable dir -r"       'mkdir -p t/u; touch t/u/f; chmod 000 t/u' -r t
run_tree "unreadable dir -rf"      'mkdir -p t/u; touch t/u/f; chmod 000 t/u' -rf t
run_tree "dir without exec -r"     'mkdir -p t/u; touch t/u/f; chmod 600 t/u' -r t
run_tree "file in unwritable dir"  'mkdir t; touch t/f; chmod 555 t' t/f
run_tree "file in unwritable dir -f" 'mkdir t; touch t/f; chmod 555 t' -f t/f
run_tree "-v several types"        "$S" -v a empty sl dang ff
run_tree "-v dangling and dir"     "$S" -rv dang d sd
run_tree "twice the same file"     "$S" a a
run_tree "-f twice"                "$S" -f a a
run_tree "dir that is a symlink loop" 'ln -s l l' l
rm -f "$yes_all" "$no_all" "$mixed"
print_summary
