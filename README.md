# Octez Homebrew Packages

Builds Octez on macOS (arm64 and x86_64) and packages it as prebuilt binary tarballs with
Homebrew formulae, including launchd services via `brew services`. This is the
macOS counterpart to the APT/RPM work in `pkg-builder`.

Nomadic Labs' formula builds Octez from source on the user's machine. These
formulae install binaries built once by `build_octez.sh`.

## Packages

| Formula          | Contents                                   | Service |
|------------------|--------------------------------------------|---------|
| `zcash-params`   | Sapling parameters (`share/zcash-params`)  |         |
| `octez-client`   | octez-client, octez-admin-client, octez-codec, bash completion | |
| `octez-node`     | octez-node                                 | yes     |
| `octez-baker`    | octez-baker, octez-accuser                 | yes (local or remote) |
| `octez-accuser`  | service only, depends on octez-baker       | yes     |
| `octez-vdf`      | service only, depends on octez-baker       | yes     |
| `dal-trusted-setup` | DAL SRS files (`share/dal-trusted-setup`) |       |
| `octez-dal-node` | octez-dal-node, depends on dal-trusted-setup | yes   |

## Building

```
./build_octez.sh                       # latest octez-vX.Y release tag
./build_octez.sh --branch octez-v25.3
./make_pkgs.sh                         # tarballs, manifest + formulae in dist/
./make_pkgs.sh --no-strip              # keep symbol tables
```

Run these on each architecture. `make_pkgs.sh` packages for the machine it runs
on and records the result in `dist/manifest-<arch>.txt`. To combine
architectures, copy the other machine's manifest and `*-<arch>-macos.tar.gz`
tarballs into `dist/`, then run `./render_formulae.sh`. The formulae then
contain `on_arm`/`on_intel` blocks. On Intel, blst is built portable by default
so the binaries also run on 2013–2014 Macs.

## Testing locally

Homebrew only installs formulae from taps:

```
./local_tap.sh                         # copies dist/Formula into local/octez
brew trust local/octez
brew install local/octez/octez-node
brew services start octez-node
```

## Publishing

The tap is [drchrispinnock/homebrew-octez](https://github.com/drchrispinnock/homebrew-octez),
with tarballs on its GitHub Releases:

```
./render_formulae.sh --tap drchrispinnock/octez \
  --baseurl 'https://github.com/drchrispinnock/homebrew-octez/releases/download/@TAG@'
./publish.sh
```

## Using the services

Each service reads `$(brew --prefix)/etc/octez/<name>.conf`, a shell
fragment like the `/etc/default/octez-*` files in the Debian packages. Logs
go to `$(brew --prefix)/var/log/octez/<name>.log`. Data directories default
to the Octez defaults (`~/.tezos-node`, `~/.tezos-client`,
`~/.tezos-dal-node`).

`brew services start` runs a service as a LaunchAgent for the logged-in user.
To run at boot as a dedicated user:
`sudo brew services start --sudo-service-user tezos octez-node`.
