# Built-in syntax grammars for cat

Status: 40 grammars, original work; unverified against any reference highlighter. Date: 2026-11-21

## Provenance

Every file in `src/syntax/builtin/` was written for util-core from knowledge of each language's syntax. No text was copied or adapted from bat, Sublime Text packages, TextMate bundles, syntect, GitHub linguist or any other grammar, so no license audit is needed (decision 0001). Each file carries the header `# Original grammar written for util-core (GPL-2.0-or-later).` The files use the Sublime syntax format only; they run on our own engine (`src/syntax/`, sublime-syntax.md), so features the engine lacks (embedding, backreferences into pushed contexts, `extends`) are not used. The grammars are embedded at build time (`src/syntax/builtin.zig`) and loaded after the user's grammars.

## Languages and detection

| Grammar | Extensions (and names) | First line |
|---|---|---|
| asm | asm s S nasm inc | .file/.text/.section/... or NASM `bits`/`section`/`global` |
| batch | bat cmd btm | |
| c | c h | modeline |
| cpp | cpp cc cxx c++ hpp hh hxx h++ ipp tpp inl | modeline |
| css | css pcss | `@charset` |
| diff | diff patch rej | `diff `, `Index:`, `--- `, mail `From <sha>` |
| go | go | `Code generated ... DO NOT EDIT.` |
| html | html htm xhtml shtml xht | doctype, `<html` |
| ini | ini desktop service socket timer mount target path gitconfig editorconfig properties repo inf reg theme directory | |
| java | java jsh | |
| javascript | js mjs cjs jsx es6 | node/deno/bun shebang |
| json | json jsonc json5 geojson webmanifest har ipynb babelrc eslintrc code-workspace | |
| makefile | mk mak make Makefile makefile GNUmakefile BSDmakefile Makefile.am Makefile.in Makefile.inc | |
| markdown | md markdown mkd mkdn mdown mdwn mdx | |
| nim | nim nims nimble | `nim` shebang |
| odin | odin | |
| powershell | ps1 psm1 psd1 ps1xml pssc psrc cdxml | `pwsh` shebang |
| python | py pyw pyi pyx pxd gyp gypi SConstruct SConscript wscript tac | `python` shebang |
| ruby | rb rake gemspec ru rbw builder thor podspec jbuilder; Rakefile Gemfile Guardfile Capfile Vagrantfile Podfile Brewfile Berksfile | `ruby` shebang |
| rust | rs | `rust-script` shebang |
| shell | sh bash zsh ksh dash ash bashrc bash_profile profile zshrc zshenv ... PKGBUILD APKBUILD ebuild | `sh`/`bash`/`zsh`/... shebang |
| sql | sql ddl dml psql pgsql mysql sqlite hql | |
| toml | toml Cargo.lock Pipfile poetry.lock | |
| typescript | ts tsx mts cts | ts-node/deno/bun shebang |
| yaml | yaml yml clang-format clang-tidy yamllint | `%YAML` |
| zig | zig zon | `zig` shebang |
| conf | conf cfg sshd_config ssh_config sysctl fstab crontab hosts resolv exports limits nanorc htaccess wgetrc curlrc inputrc gemrc npmrc netrc pam rc rules motd | |
| cmake | cmake CMakeLists.txt CMakeCache.txt ctest cpack | |
| csharp | cs csx cake | |
| dockerfile | Dockerfile dockerfile Containerfile containerfile | `# syntax=docker` |
| dotenv | env .env envrc env.example env.local env.development env.production env.test env.sample | |
| gitignore | gitignore gitattributes gitmodules dockerignore npmignore ignore mailmap git-blame-ignore-revs | |
| haskell | hs hsc lhs hs-boot purs | `runhaskell` shebang |
| kotlin | kt kts | |
| lua | lua rockspec luacheckrc | `lua`/`luajit` shebang |
| perl | pl pm pod t psgi cgi perl ph | `perl` shebang |
| php | php phtml php3 php4 php5 phps phpt inc | `<?php`, `php` shebang |
| swift | swift | `swift` shebang |
| vim | vim vimrc gvimrc nvimrc exrc | `" vim:` |
| xml | xml svg xsd xsl xslt xaml axaml csproj vbproj fsproj vcxproj props targets plist rss atom wsdl resx nuspec kml gpx xliff glade ui manifest appxmanifest mobileconfig storyboard xib config | `<?xml` |

`cat --list-languages` prints what is loaded.

## Known limitations (all grammars)

- No embedding: no JavaScript or CSS inside HTML, no code inside Markdown fences, no SQL in strings.
- The engine cannot refer back to what opened a context, so closers that must match their opener are approximated: shell heredocs recognise about 25 common delimiter words (EOF, END, EOT, SQL, USAGE, ...) by name and otherwise end at any bare word line; Ruby heredocs end at an upper-case word line; C++ raw strings end at the first `)delim"`; YAML block scalars use one context per indent level (generated, 0 to 17 spaces).
- Highlighting is a heuristic: JavaScript/TypeScript regex literals are recognised after operators, `(`, `,`, `[` and keywords only; TypeScript generics and JSX can be confused in rare cases; user type names are not told from variables in several languages.
- Theme: the 16-colour theme has no bold or italic, so Markdown bold and italic use colours (`storage.modifier`, `variable.parameter`).
- Speed (debug-free ReleaseSafe estimates by the grammar authors, probe tool): most grammars 0.2 to 0.7 s for 400 KB; SQL, CSS, Markdown, JSON and the C++ headers are the slowest (1 to 2 s for 1 to 2 MB). Lines over 1 MiB are not highlighted. Startup parses all grammars of a highlighted run; see the measurement in cat.md.
