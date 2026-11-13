# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Packages Octez (Tezos) for Homebrew on macOS arm64 as **prebuilt binary tarballs plus formulae** (not casks, not source formulae, not bottles). Casks were rejected because they cannot define `brew services` and would need Apple notarization. This is the macOS sibling of `../pkg-builder` (APT/RPM). Its `pkgscripts/pkg-common/*.service` and `*.default` files are the reference for what each service runs. Keep behaviour aligned with them.

Hosting and CI (publishing tarballs and a real `homebrew-*` tap repo) are not built yet. The defaults target local testing.

## Commands

```sh
./build_octez.sh [--branch octez-vX.Y] [--repo URL] [--skip-deps] [--clean]
./make_pkgs.sh [--tree work/tezos] [--version V] [--revision N] \
               [--baseurl URL] [--tap user/repo] [--packages "a b"] [--no-strip]
./local_tap.sh [tap] [formula-dir]    # Homebrew refuses loose formula files
brew trust local/octez && brew install local/octez/octez-node
```

`build_octez.sh` clones into `work/tezos` (git-ignored). It uses a local opam switch and builds only the executables in `pkgdefs/*.binaries` with `make build PROFILE=release OCTEZ_EXECUTABLES=...`, then fetches the DAL trusted setup into `_opam/share`. It forces openssl@3 ahead of Homebrew's default openssl@4 because the opam `ssl` package breaks with OpenSSL 4.

`make_pkgs.sh` writes `dist/<name>-<version>-arm64-macos.tar.gz` and `dist/Formula/<name>.rb`. Defaults are `--tap local/octez` and `file://` URLs.

To test the packaging without a real build, point `--tree` at a fake tree. It needs the binaries (any Mach-O files), `_opam/share/zcash-params/*.params`, `_opam/share/dal-trusted-setup/srsu_zcash_g{1,2}` and `src/bin_client/bash-completion.sh`.

## Architecture

- **`pkgdefs/<formula>.*`** declares each package. `.binaries` lists files copied from the Octez tree root into `bin/`. `.desc` is the formula description. `.depends` lists formulae in the same tap, rendered as `depends_on "<tap>/<name>"`. `.caveats` holds the caveats text, which may use `#{etc}`. `.version` gives a fixed version that overrides the Octez version. The data-only formulae `zcash-params` and `dal-trusted-setup` are `1.0.0`, so Octez upgrades don't download them again; bump the version only if the files change. Data files (zcash params, DAL setup, client completion) are special-cased in the `case` in `make_pkgs.sh`.
- **Library dependencies are auto-detected.** `otool -L` on each binary maps `$(brew --prefix)/opt/<formula>/...` to `depends_on "<formula>"`. Any other non-system path (Cellar, `/opt/homebrew/lib`, `@rpath`) fails the build on purpose.
- **Templates:** `templates/formula.rb.in` is a single generic formula. Its `install` copies whatever top-level dirs exist in the tarball (`bin`, `share`, `libexec`, `etc/octez`, `completions`). `templates/service.rb.in` is spliced in when `services/<formula>-service` exists. Rendering is a perl `@TOKEN@` → `$T_TOKEN` substitution that only replaces tokens whose env var is set. That is how `@HOMEBREW_PREFIX@` survives into the formula, where `inreplace` fills it in at install time.
- **Services:** Homebrew allows **one `service` block per formula**. That is why the accuser and VDF are separate service-only formulae depending on `octez-baker`, and why the baker's local and remote modes are one wrapper switched by `MODE`. Each `services/<formula>-service` is a POSIX sh wrapper. It sets defaults, sources `$PREFIX/etc/octez/<formula>.conf` (installed via `etc`, so user edits survive upgrades as `.default` files) and `exec`s the binary. The service block sets `XDG_DATA_DIRS=$HOMEBREW_PREFIX/share` because launchd doesn't set `HOMEBREW_PREFIX`, and that variable is how Octez finds `zcash-params` and `dal-trusted-setup`.

## Build results (octez-v25.3, first real build)

- Linked Homebrew libraries: gmp, zstd, openssl@3, libev, hidapi (baker, accuser and client only). Everything else comes from the system (libz, libsqlite3, libc++, Security). All are linked via `opt/` paths, so they pass `dylibDeps`.
- `--deployment-target` (14.0) sets our binaries' `minos`, but Homebrew's own dylibs carry their bottle's `minos` (26.0 here). That causes about 160 harmless "built for newer macOS" linker warnings. The effective minimum is whatever the user's Homebrew bottles target.
- `make_pkgs.sh` strips binaries by default (`--no-strip` to skip): about 19% smaller installed, and the ad-hoc signature stays valid. The script re-signs a binary if its signature fails to verify. The Debian packages are not stripped.
- The DAL trusted setup is 576 MB (g1 192 MB, g2 384 MB), so it is its own formula and `octez-dal-node` is about 49 MB.
- Verified with stripped binaries: `octez-node` started as a LaunchAgent found the zcash params through `XDG_DATA_DIRS`, ran, and shut down cleanly on `brew services stop`.

## Homebrew 7 specifics (verified on 7.0.13)

- Service labels and plists are `sh.brew.<formula>` (`~/Library/LaunchAgents/sh.brew.*.plist`), not `homebrew.mxcl.*`.
- `post_install` is deprecated. Use `post_install_steps do mkdir_p "...", base: :var end`.
- Third-party taps must be trusted (`brew trust <tap>`) before dependencies load from them.
- `brew tap-new` silently enables developer mode. Run `brew developer off` afterwards.
- Service DSL: `keep_alive successful_exit: false` ≈ systemd `Restart=on-failure`, `throttle_interval` ≈ `RestartSec`, `stop_timeout` ≈ `TimeoutStopSec`.
