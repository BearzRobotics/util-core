# Intro

The purpose of this repository is **not** to reimplement the entirety of GNU
coreutils. At minimum, our goal is to achieve **POSIX compatibility** for each
tool included in this package. That said, we welcome pull requests that add
**GNU-specific compatibility** where appropriate.

While the aim is for these tools to be **drop-in replacements**, that should not
limit us to only POSIX/GNU features. Where it makes sense, tools may be extended
with optional enhancements, for example:

- `cp` / `mv` / `dd` -- `--progress` to display a progress bar
  (e.g. `[********        24%]`)
- `cat` -- optional colorful output / pager-style view inspired by `bat`
- `du` -- optional graphical output inspired by `dust`

Because these tools are intended to be drop-in replacements, defaults must not
break long-established scripts. However, enhanced behavior may be enabled via
opt-in flags or shell aliases, as many distros already do (e.g.
`ls --color=auto`).

Where this project intentionally diverges from existing conventions is in how
tools are grouped. GNU separates utilities into `coreutils`, `findutils`, `sed`,
`grep`, etc., while also including tools such as `chown` and `chmod` that only
make sense in a Unix/Linux context.

This project aims to separate Unix-specific tools into a dedicated `unix-utils`
package, while incorporating the remaining utilities alongside a
POSIX-compliant `sh`.

# Documentation

All documentation lives in the `docs/` folder in Markdown format. All pull
requests must indicate whether they introduce changes that require
documentation.

Use the following tag in your pull request description:

`Documentation Needed: [yes/no]`

If documentation is needed, it must be included in the same pull request.

We recommend using Glow as the terminal Markdown viewer for this project. It
renders Markdown beautifully in the terminal, preserving bold text, tables,
code blocks, and syntax highlighting -- making it easy to read documentation
files for each utility.

See the official repository:
https://github.com/charmbracelet/glow

## Usage Example

To view the documentation for a single utility:

glow docs/cp.md

# Tests

All utilities and shell scripts should be accompanied by tests located in the
`tests/` folder. Pull requests must indicate whether they introduce changes
that require new or updated tests.

Use the following tag in your pull request description:

`Tests Needed: [yes/no]`

If tests are needed, they must be included in the same pull request and should:

- Verify correct behavior of the utility or shell script
- Use exit codes to signal success/failure (0 = success, non-zero = failure)
- Be runnable in a cross-shell or cross-system environment where applicable
- Optionally include expected output comparisons or checks against POSIX
  behavior

## Example workflow

# Run all shell test scripts
for script in tests/*.sh; do
    sh "$script"
done



# Building & Installing

Get the Zig compiler either from the official site:
https://ziglang.org/download/

or using a package manager like zvm:
https://github.com/tristanisham/zvm

**Zig version required:** TBD

git clone <repository-url>
cd coreutils-utils
zig build

To install, copy the programs in `zig-out/bin/` to your desired location. It is
not recommended to replace the system versions in `/usr/bin` at this time.

# install
It is not recommend to install these utilites in your global path as they're 
not quite ready yet for production.

zig-out/bin/main is a fat binary that has all of the current utilies backed in
eg. 

Run the ls command from the fat binary
```sh
    ./zig-out/bin/main ls 
```

Run the ls command directly 
```sh
    ./zig-out/bin/ls
```

install system wide (not recommend)
```sh
    sudo cp -avr zig-out/bin/* /usr/bin/*
````



# Projects That Inspired This

- https://github.com/chimera-linux/chimerautils
- https://busybox.net/
- https://www.gnu.org/software/coreutils/
- https://www.gnu.org/software/findutils/
- https://www.gnu.org/software/sed/
- https://www.gnu.org/software/grep/
- https://landley.net/toybox/

We take inspiration from these projects. However, default behavior must match
the tools being replaced so they can function as drop-in replacements.
Enhancements should be opt-in, and alternative defaults can be enabled via shell
aliases (as many distros already do with `ls --color`).

Additional inspiration:

- https://github.com/sharkdp/bat
- https://github.com/bootandy/dust
- https://github.com/Genivia/ugrep
