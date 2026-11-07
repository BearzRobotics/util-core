#!/bin/sh
# stdin.sh BIN FILE [ARGS...] - run BIN ARGS with FILE as standard input.
# poop cannot redirect, and it re-runs commands, so this wrapper does it.
bin=$1; file=$2; shift 2
exec "$bin" "$@" < "$file"
