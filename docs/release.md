# Cutting a release

Releases are built by `.github/workflows/release.yml` when a tag `v*` is pushed. The
workflow installs Zig 0.17.1 (pinned), calls `scripts/package.sh` for each target, writes
`SHA256SUMS`, takes the release notes from the `CHANGELOG.md` section of the version and
creates the GitHub release. Running the workflow by hand (workflow_dispatch) is a dry run:
it builds the archives as workflow artifacts and publishes nothing.

## Assets

| File | Target |
|---|---|
| `util-core-VERSION-linux-x86_64.tar.gz` | x86_64-linux-musl (static) |
| `util-core-VERSION-linux-aarch64.tar.gz` | aarch64-linux-musl (static) |
| `util-core-VERSION-windows-x86_64.zip` | x86_64-windows |
| `util-core-VERSION-windows-aarch64.zip` | aarch64-windows |
| `SHA256SUMS` | checksums of the above |

Each archive holds one directory with `bin/` (all standalone commands and the `util-core`
multicall binary), `share/man/man1/` (the manual pages), `LICENSE`, `README.md` and
`CHANGELOG.md`. Built with `-Doptimize=ReleaseSafe -Dstrip=true`.

macOS: no prebuilt binaries are published, because no maintainer owns a Mac. macOS builds
from source and `ci.yml` compile-checks x86_64-macos and aarch64-macos (nothing is run).
Prebuilt macOS binaries will be offered once a volunteer with a Mac steps up to test and
maintain that platform.

## Checklist

1. `main` is green in CI (`zig build`, `zig build test`, all three modes, all cross targets).
2. Run the full differential suites locally (`sh test/run_all_tests.sh` after
   `zig build -Doptimize=ReleaseSafe`). Do not run the `sync` global-flush cases.
3. **Windows recheck on the real VM (manual, maintainer):** build
   `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe`, copy `zig-out/bin` to the
   Windows 11 VM and run the Windows suite there (`test/test_windows_wine.sh` lists the 79
   cases; run them in cmd.exe and PowerShell): `--version`, text commands, file commands,
   `ls`, `find`, `cp`/`mv`/`rm`, `date`, long paths, CRLF handling, Ctrl-C. Record the result and
   any new difference in `docs/portability.md`. Do not tag if a regression is found.
4. Bump the version in `build.zig.zon` **and** `pub const version` in `src/cli.zig`; update
   the version in the manual pages (`This manual describes util-core X.Y.Z.`).
5. Add a `## X.Y.Z` section to `CHANGELOG.md`; check it renders as release notes:
   `scripts/release-notes.sh X.Y.Z`.
6. Update README, `docs/status.md` and `docs/portability.md` if platform status changed.
7. Test packaging locally: `scripts/package.sh x86_64-linux-musl linux-x86_64 dist` (runs the
   binary), then unpack and try it. Cross targets: `scripts/package.sh x86_64-windows windows-x86_64 dist`
   (runs under wine when installed).
8. Commit, merge to `main`, then tag and push: `git tag -a vX.Y.Z -m "util-core X.Y.Z"` and
   `git push origin main vX.Y.Z`. The workflow refuses a tag that differs from `build.zig.zon`.
9. Watch the workflow; check the release page, `SHA256SUMS`, and download one Linux archive
   and run `bin/util-core echo --version`.
10. Optional dry run before tagging: Actions, release, "Run workflow".
