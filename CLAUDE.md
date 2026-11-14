# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Packages Octez (Tezos) for Homebrew on macOS (arm64 and x86_64) as **prebuilt binary tarballs plus formulae** (not casks, not source formulae, not bottles). Casks were rejected because they cannot define `brew services` and would need Apple notarization. This is the macOS sibling of `../pkg-builder` (APT/RPM). Its `pkgscripts/pkg-common/*.service` and `*.default` files are the reference for what each service runs. Keep behaviour aligned with them.

The published tap is `github.com/drchrispinnock/homebrew-octez` (`brew tap drchrispinnock/octez`). Its tarballs are assets on that repo's GitHub Releases. There is no CI yet: build and packaging run by hand on each architecture, and publishing runs from the arm64 Mac. The defaults of `make_pkgs.sh` and `render_formulae.sh` target local testing.

## Commands

```sh
./build_octez.sh [--component octez|srn|evm] [--branch octez-vX.Y] [--repo URL] [--skip-deps] [--clean] [--(no-)blst-portable]
./make_pkgs.sh [--component octez|srn|evm] [--tree work/tezos] [--version V] [--packages "a b"] [--no-strip] [--no-render] \
               [--revision N] [--baseurl URL] [--tap user/repo]   # last two go to render_formulae.sh
./render_formulae.sh [--dist dist] [--baseurl URL] [--tap user/repo]
./local_tap.sh [tap] [formula-dir]    # Homebrew refuses loose formula files
brew trust local/octez && brew install local/octez/octez-node

# Publish (after build_octez.sh and make_pkgs.sh on each architecture, with the
# Intel Mac's dist/manifest-x86_64.txt and *-x86_64-macos.tar.gz copied into dist/):
./render_formulae.sh --tap drchrispinnock/octez \
  --baseurl 'https://github.com/drchrispinnock/homebrew-octez/releases/download/@TAG@'
./publish.sh [--clobber] [--no-push]  # uploads assets, then pushes Formula/ to the tap
```

`@TAG@` in `--baseurl` becomes each tarball's release tag: `octez-v<version>`, or `<name>-v<version>` for fixed-version data formulae. That way `zcash-params` and `dal-trusted-setup` live in their own releases and aren't re-uploaded with each Octez release. `render_formulae.sh` writes `dist/assets.txt` (tag, tarball, sha256), and `publish.sh` checks every listed tarball is present with that sha before uploading anything. Tarballs are reproducible: fixed mtimes and owners, `gzip -n`, and tar's `--no-xattrs --no-acls --no-fflags --no-mac-metadata`. Without those flags, bsdtar on recent macOS stores each file's per-machine `com.apple.provenance` xattr in pax headers, and the same files tar differently on each Mac. The published 1.0.0 data tarballs were made before that fix and still contain the arm64 Mac's provenance headers. `publish.sh` skips an asset whose GitHub `digest` matches, and fails on a mismatch unless `--clobber` is given. It uploads before it pushes, so a pushed formula never points at a missing asset. The tap checkout is `work/homebrew-octez`. Its README comes from `templates/tap-README.md` and is copied only if the tap doesn't have one yet.

`build_octez.sh` clones into `work/tezos` (git-ignored). It uses a local opam switch and builds only the executables in `pkgdefs/*.binaries` with `make build PROFILE=release OCTEZ_EXECUTABLES=...`, then fetches the DAL trusted setup into `_opam/share`. It forces openssl@3 ahead of Homebrew's default openssl@4 because the opam `ssl` package breaks with OpenSSL 4. On x86_64 it builds with `BLST_PORTABLE=yes` by default, because non-portable blst uses ADX instructions that 2013–2014 (Haswell) Intel Macs lack.

The work is split across machines:
- **`make_pkgs.sh`** packages for the machine it runs on (`uname -m`). Octez packages become `dist/<name>-<version>[_<revision>]-<arch>-macos.tar.gz`. `--revision N` (default 0) is for repackaging the same Octez version, for example after a service change. It goes into the tarball name, so a published asset is never replaced (no `--clobber`), and into the manifest. Give it only with `--packages` naming the formulae that changed. Data packages (those with `pkgdefs/*.version`) become arch-neutral `dist/<name>-<version>.tar.gz`. If that tarball is already in `dist/`, it is kept rather than rebuilt, so its published sha never changes. On a second machine, download the published data tarballs into `dist/` first, or render will warn that the manifests disagree. Each package gets a line in `dist/manifest-<arch>.txt`: `name version arch tag tarball sha256 deps revision`, where arch is `arm64`, `x86_64` or `all`, deps is a comma-separated list or `-`, and revision may be missing in older manifests (meaning 0). Rerunning with `--packages` replaces only those lines. It then runs `render_formulae.sh` unless `--no-render` is given.
- **`render_formulae.sh`** reads every `dist/manifest-*.txt` and fails if the architecture-specific entries mix Octez versions. It writes one formula per package. With both architectures it emits `on_arm`/`on_intel` blocks, each with its own url and sha256: libraries common to both go at the top level, and the rest go inside the blocks. With one architecture it emits `depends_on arch:`. A formula's `revision` is the highest revision among its architecture entries. Data packages get a single url; if the manifests disagree on one, the first wins and a warning is printed.
- To check the Intel side from an arm64 Mac, use `brew info --json=v2 --variations <formula>` and `brew fetch --arch=intel --os=tahoe <formula>`. The flag values are `arm`/`intel`, not `arm64`/`x86_64`.

To test the packaging without a real build, point `--tree` at a fake tree. It needs the binaries (any Mach-O files), `_opam/share/zcash-params/*.params`, `_opam/share/dal-trusted-setup/srsu_zcash_g{1,2}` and `src/bin_client/bash-completion.sh`.

## Architecture

- **Components:** a package belongs to the `octez` component unless `pkgdefs/<pkg>.component` says otherwise. Each component has its own tree, branch, version and release tag. `octez` builds in `work/tezos` from the latest `octez-vX.Y` tag and is released as `octez-v<version>`. `srn` (`octez-smart-rollup-node`) builds in `work/tezos-srn` from `SRNBRANCH` in `latest-releases.env`, the same setting as in `../pkg-builder`. That tree is a git worktree of `work/tezos` with its own opam switch. The SRN is built for arm64 only, by choice, so its formula gets `depends_on arch: :arm64`. `evm` (`octez-evm-node`) works the same way, and is also arm64 only, with `EVMBRANCH`, `work/tezos-evm` and the tag `octez-evm-node-v<version>`, for example `0.68`. Its service runs `run observer` against a rollup node, like pkg-builder's unit. That unit reads `/etc/default/octez-node`, which looks like a bug. Its version comes from the tag, so `octez-smart-rollup-node-v20260724` gives version `20260724` and that release tag. `build_octez.sh` and `make_pkgs.sh` take `--component` and handle only that component's binaries and packages. `render_formulae.sh` checks for mixed versions within a component, grouping entries by their tag prefix.

- **`pkgdefs/<formula>.*`** declares each package. `.binaries` lists files copied from the Octez tree root into `bin/`. `.desc` is the formula description. `.depends` lists formulae in the same tap, rendered as `depends_on "<tap>/<name>"`. `.caveats` holds the caveats text, which may use `#{etc}`. `.version` gives a fixed version that overrides the Octez version. The data-only formulae `zcash-params` and `dal-trusted-setup` are `1.0.0`, so Octez upgrades don't download them again; bump the version only if the files change. Data files (zcash params, DAL setup, client completion) are special-cased in the `case` in `make_pkgs.sh`. Service, caveats and test blocks are decided at render time from `services/` and `pkgdefs/`, not from the tarball.
- **Library dependencies are auto-detected.** `otool -L` on each binary maps `$(brew --prefix)/opt/<formula>/...` to `depends_on "<formula>"`. Any other non-system path (Cellar, `/opt/homebrew/lib`, `@rpath`) fails the build on purpose.
- **Templates:** `templates/formula.rb.in` is a single generic formula. Its `install` copies whatever top-level dirs exist in the tarball (`bin`, `share`, `libexec`, `etc/octez`, `completions`). `templates/service.rb.in` is spliced in when `services/<formula>-service` exists. Rendering (in `render_formulae.sh`) is a perl `@TOKEN@` → `$T_TOKEN` substitution that only replaces tokens whose env var is set. That is how `@HOMEBREW_PREFIX@` survives into the formula, where `inreplace` fills it in at install time.
- **Services:** Homebrew allows **one `service` block per formula**. That is why the accuser and VDF are separate service-only formulae depending on `octez-baker`, and why the baker's local and remote modes are one wrapper switched by `MODE`. Each `services/<formula>-service` is a POSIX sh wrapper. It sets defaults, sources `$PREFIX/etc/octez/<formula>.conf` (installed via `etc`, so user edits survive upgrades as `.default` files) and `exec`s the binary. The service block sets `XDG_DATA_DIRS=$HOMEBREW_PREFIX/share` because launchd doesn't set `HOMEBREW_PREFIX`, and that variable is how Octez finds `zcash-params` and `dal-trusted-setup`.
- **Logs:** launchd opens `StandardOutPath` once, and macOS newsyslog can only rename, never truncate, so the `var/log/octez` files cannot be rotated without restarting the service. Instead each wrapper exports `TEZOS_LOG=$LOG_RULES` (default `warning`). That only filters the stdout sink: Octez's own daily-log sink (`<data-dir>/daily_logs`, `<base-dir>/logs/octez-{baker,accuser}`, info level, 7 days) is unaffected. Verified with octez-node 25.3: no NOTICE lines on stdout, daily log written as usual.

## Build results (octez-v25.3, first real build)

- Linked Homebrew libraries: gmp, zstd, openssl@3, libev, hidapi (baker, accuser and client only). Everything else comes from the system (libz, libsqlite3, libc++, Security). All are linked via `opt/` paths, so they pass `dylibDeps`.
- `--deployment-target` (14.0) sets our binaries' `minos`, but Homebrew's own dylibs carry their bottle's `minos` (26.0 here). That causes about 160 harmless "built for newer macOS" linker warnings. The effective minimum is whatever the user's Homebrew bottles target.
- `make_pkgs.sh` strips binaries by default (`--no-strip` to skip): about 19% smaller installed, and the ad-hoc signature stays valid. The script re-signs a binary if its signature fails to verify. The Debian packages are not stripped.
- The DAL trusted setup is 576 MB (g1 192 MB, g2 384 MB), so it is its own formula and `octez-dal-node` is about 49 MB.
- Verified with stripped binaries: `octez-node` started as a LaunchAgent found the zcash params through `XDG_DATA_DIRS`, ran, and shut down cleanly on `brew services stop`.

- **Published state:** octez-v25.3 for arm64 and x86_64 (tap commit 19eb487). Homebrew has no Intel bottles (Intel is Tier 3 since September 2026), so on Intel the linked libraries and their build tools (cmake etc.) are compiled from source at install time. We decided not to bundle them into the tarballs, so that Homebrew keeps updating them, not us.

## Homebrew 7 specifics (verified on 7.0.13)

- Service labels and plists are `sh.brew.<formula>` (`~/Library/LaunchAgents/sh.brew.*.plist`), not `homebrew.mxcl.*`.
- `post_install` is deprecated. Use `post_install_steps do mkdir_p "...", base: :var end`.
- Third-party taps must be trusted (`brew trust <tap>`) before dependencies load from them.
- `brew tap-new` silently enables developer mode. Run `brew developer off` afterwards.
- Service DSL: `keep_alive successful_exit: false` ≈ systemd `Restart=on-failure`, `throttle_interval` ≈ `RestartSec`, `stop_timeout` ≈ `TimeoutStopSec`.
