#!/bin/sh
#
# Build Octez on macOS (arm64 or x86_64) ready for packaging with
# make_pkgs.sh.
#
# The Octez tree is cloned into a work directory and built with its own
# local opam switch. Only the executables of the component's packages in
# pkgdefs/*.binaries are built.
#
# Components (pkgdefs/<pkg>.component, default octez):
#   octez  main Octez release, latest octez-vX.Y tag, tree work/tezos
#   srn    smart rollup node, versioned separately: SRNBRANCH from
#          latest-releases.env, tree work/tezos-srn (a git worktree of
#          work/tezos when that exists)
#   evm    EVM node, versioned separately: EVMBRANCH from
#          latest-releases.env, tree work/tezos-evm (likewise)

set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"

REPO="https://gitlab.com/tezos/tezos.git"
COMPONENT="octez"
BRANCH=""
WORKDIR=""
DEPLOYMENT_TARGET="14.0"
SKIPDEPS=0
CLEAN=0
ARCH=$(uname -m)

# Portable BLST avoids the ADX instructions that pre-Broadwell Intel CPUs
# (2013-2014 Macs) lack. Apple Silicon does not need it.
case "${ARCH}" in
x86_64) BLSTPORTABLE=1 ;;
*) BLSTPORTABLE=0 ;;
esac

usage() {
	cat <<EOF
Usage: $0 [--component octez|srn|evm] [--branch Branch|Tag|latest-release] [--repo GitURL]
          [--workdir Dir] [--deployment-target MacOSVersion]
          [--skip-deps] [--clean] [--(no-)blst-portable]
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--component | -C) COMPONENT="$2"; shift ;;
	--branch | -B) BRANCH="$2"; shift ;;
	--repo) REPO="$2"; shift ;;
	--workdir) WORKDIR="$2"; shift ;;
	--deployment-target) DEPLOYMENT_TARGET="$2"; shift ;;
	--skip-deps) SKIPDEPS=1 ;;
	--clean) CLEAN=1 ;;
	--blst-portable) BLSTPORTABLE=1 ;;
	--no-blst-portable) BLSTPORTABLE=0 ;;
	*) usage ;;
	esac
	shift
done

case "${COMPONENT}" in
octez)
	[ -n "${BRANCH}" ] || BRANCH="latest-release"
	[ -n "${WORKDIR}" ] || WORKDIR="${here}/work/tezos"
	;;
srn)
	if [ -z "${BRANCH}" ]; then
		. "${here}/latest-releases.env"
		BRANCH="${SRNBRANCH}"
	fi
	[ -n "${WORKDIR}" ] || WORKDIR="${here}/work/tezos-srn"
	;;
evm)
	if [ -z "${BRANCH}" ]; then
		. "${here}/latest-releases.env"
		BRANCH="${EVMBRANCH}"
	fi
	[ -n "${WORKDIR}" ] || WORKDIR="${here}/work/tezos-evm"
	;;
*) echo "Unknown component ${COMPONENT}" >&2; exit 1 ;;
esac

# Packages of a component: pkgdefs/<pkg>.component, octez when absent
componentOf() {
	if [ -f "${here}/pkgdefs/$1.component" ]; then
		cat "${here}/pkgdefs/$1.component"
	else
		echo octez
	fi
}

[ "$(uname -s)" = "Darwin" ] || { echo "This builds on macOS only" >&2; exit 1; }
case "${ARCH}" in
arm64 | x86_64) ;;
*) echo "Unsupported architecture ${ARCH}" >&2; exit 1 ;;
esac
for tool in brew opam rustup git; do
	command -v "$tool" > /dev/null || { echo "Missing $tool" >&2; exit 1; }
done

# Fetch the source
#
maintree="${here}/work/tezos"
if [ ! -e "${WORKDIR}/.git" ]; then
	mkdir -p "$(dirname "${WORKDIR}")"
	if [ "${WORKDIR}" != "${maintree}" ] && [ -d "${maintree}/.git" ]; then
		# Share the objects of the main clone
		git -C "${maintree}" worktree add --detach "${WORKDIR}"
	else
		git clone "${REPO}" "${WORKDIR}"
	fi
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
if [ "${BLSTPORTABLE}" = "1" ]; then
	export BLST_PORTABLE=yes
	echo "=> Building with BLST_PORTABLE=yes"
fi

. ./scripts/version.sh
rustup toolchain install "${recommended_rust_version}"

if [ "${SKIPDEPS}" = "0" ]; then
	make build-deps
fi
eval "$(opam env --switch="${WORKDIR}" --set-switch)"

executables=$(for b in "${here}"/pkgdefs/*.binaries; do
	pkg=$(basename "${b}" .binaries)
	if [ "$(componentOf "${pkg}")" = "${COMPONENT}" ]; then cat "${b}"; fi
done | sort -u | tr '\n' ' ')
echo "=> Building: ${executables}"
make build PROFILE=release OCTEZ_EXECUTABLES="${executables}"

# The DAL trusted setup is downloaded into the opam switch
#
if [ "${COMPONENT}" = "octez" ]; then
	./scripts/install_dal_trusted_setup.sh
fi

echo "=> Build complete in ${WORKDIR}"
