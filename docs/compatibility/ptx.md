# ptx: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU ptx 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/ptx --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "ptx invocation" (`info '(coreutils) ptx invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/ptx-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), ptx, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ptx.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_ptx.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-A, -R, -r`: Auto, right-side or input references.
- `-w, -g, -F, -M, -O, -T, -G, -f`: Width, gap, truncation flag, macro name, roff, TeX, traditional, ignore case.
- `-i, -o, -b`: Ignore, only and break files.
- `-S, -W`: End-of-sentence and word regular expressions.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Field layout, truncation and wrap-around follow GNU ptx.c. The default sentence pattern is matched by hand.

## Known deviations and gaps

- `-S`/`-W` expressions are translated from GNU's Emacs-style syntax to extended syntax and use the project's regex engine; POSIX character classes such as `[[:alpha:]]` behave differently from glibc in this syntax and are not tested.
- With `-W` patterns that can match the empty string GNU loops forever; so do we.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_ptx.sh`: 523 differential cases against GNU ptx 9.7 in the C locale. 

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
