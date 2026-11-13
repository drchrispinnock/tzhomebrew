#!/bin/sh
#
# Build Octez on macOS (arm64) ready for packaging with make_pkgs.sh.
#
# The Octez tree is cloned into a work directory (default ./work/tezos) and
# built with its own local opam switch. Only the executables listed in
# pkgdefs/*.binaries are built.

set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"

REPO="https://gitlab.com/tezos/tezos.git"
BRANCH="latest-release"
WORKDIR="${here}/work/tezos"
DEPLOYMENT_TARGET="14.0"
SKIPDEPS=0
CLEAN=0

usage() {
	cat <<EOF
Usage: $0 [--branch Branch|Tag|latest-release] [--repo GitURL]
          [--workdir Dir] [--deployment-target MacOSVersion]
          [--skip-deps] [--clean]
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--branch | -B) BRANCH="$2"; shift ;;
	--repo) REPO="$2"; shift ;;
	--workdir) WORKDIR="$2"; shift ;;
	--deployment-target) DEPLOYMENT_TARGET="$2"; shift ;;
	--skip-deps) SKIPDEPS=1 ;;
	--clean) CLEAN=1 ;;
	*) usage ;;
	esac
	shift
done

[ "$(uname -s)" = "Darwin" ] || { echo "This builds on macOS only" >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "Only arm64 is supported for now" >&2; exit 1; }
for tool in brew opam rustup git; do
	command -v "$tool" > /dev/null || { echo "Missing $tool" >&2; exit 1; }
done

# Fetch the source
#
if [ ! -d "${WORKDIR}/.git" ]; then
	mkdir -p "$(dirname "${WORKDIR}")"
	git clone "${REPO}" "${WORKDIR}"
fi
cd "${WORKDIR}"
git fetch -q --tags origin

if [ "${BRANCH}" = "latest-release" ]; then
	BRANCH=$(git tag -l --sort=-v:refname 'octez-v*' |
		grep -E '^octez-v[0-9]+\.[0-9]+$' | head -1)
	echo "=> latest-release is ${BRANCH}"
fi

if git rev-parse -q --verify "refs/tags/${BRANCH}" > /dev/null; then
	ref="refs/tags/${BRANCH}"
else
	ref="origin/${BRANCH}"
fi
git -c advice.detachedHead=false checkout -q --detach "${ref}"
echo "=> Building $(git describe --tags --always) ($(git rev-parse --short HEAD))"

if [ "${CLEAN}" = "1" ]; then
	rm -rf _build _opam
fi

# Build environment
#
# openssl@4 is Homebrew's default OpenSSL but the opam ssl package needs
# openssl@3 (it sets SSLv3 as minimum protocol, which OpenSSL 4 rejects).
# openssl@3 is keg-only, so put it ahead of the Homebrew prefix everywhere.
#
brewprefix=$(brew --prefix)
ossl=$(brew --prefix openssl@3)
[ -d "${ossl}" ] || { echo "brew install openssl@3" >&2; exit 1; }

export LDFLAGS="-L${ossl}/lib -L${brewprefix}/lib"
export LIBRARY_PATH="${ossl}/lib:${brewprefix}/lib"
export CPATH="${ossl}/include:${brewprefix}/include"
export PKG_CONFIG_PATH="${ossl}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export MACOSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}"
export OPAMYES=true

. ./scripts/version.sh
rustup toolchain install "${recommended_rust_version}"

if [ "${SKIPDEPS}" = "0" ]; then
	make build-deps
fi
eval "$(opam env --switch="${WORKDIR}" --set-switch)"

executables=$(cat "${here}"/pkgdefs/*.binaries | sort -u | tr '\n' ' ')
echo "=> Building: ${executables}"
make build PROFILE=release OCTEZ_EXECUTABLES="${executables}"

# The DAL trusted setup is downloaded into the opam switch
#
./scripts/install_dal_trusted_setup.sh

echo "=> Build complete in ${WORKDIR}"
