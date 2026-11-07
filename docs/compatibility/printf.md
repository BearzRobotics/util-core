# printf: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU printf 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/printf --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "printf invocation" (`info '(coreutils) printf invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/printf-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), printf, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/printf.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_printf.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options


- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Conversions `d i u o x X c s b q e E f F g G a A %` with flags, width, precision and `*`; length modifiers are skipped; `%N$` is accepted and ignored as glibc does. The format is reused while arguments remain.
- Floating point uses x87 `f80` (src/fmt_float.zig formats it exactly), so `%.30f` of 0.1 shows the long-double expansion and `%a` shows `0x8p-3` for 1 and `0xc.ccccccccccccccdp-7` for 0.1 like GNU on x86-64.
- Escapes: `\\ \" \a \b \e \f \n \r \t \v \c \NNN \xHH \uHHHH \UHHHHHHHH`; in the C locale a valid `\u` name is written back as typed (upper-case hex), `\U` below 0x80 prints the byte. `%b` interprets escapes in the argument (octal as `\0NNN`), `%q` quotes for the shell.
- Numeric arguments: `0x`/octal prefixes, `'c` character constants (extra characters warn), and GNU's diagnostics (`expected a numeric value`, `value not completely converted`, `Numerical result out of range`); status 1 after any of them.
- Flag and conversion combinations GNU rejects (`%#d`, `%0s`, `%5%`, `%10b`...) fail with `invalid conversion specification`.

## Known deviations and gaps

- `--help`/`--version` print util-core text (GNU prints its argv[0] path).
- Multibyte characters are bytes (C locale).
- `1e400` and other values beyond x87 range are `inf` only past f80, as in GNU.

## Tests

test/test_printf.sh (2100 cases: escapes, strings, integers across 50 awkward values, floating point across 50 values and many precisions, %a, argument reuse, error paths, and 1800 seeded random specifications) compared with GNU printf 9.7 under LC_ALL=C.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
