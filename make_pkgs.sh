#!/bin/sh
#
# Package a built Octez tree (see build_octez.sh) into tarballs for this
# machine's architecture, then render the formulae (render_formulae.sh).
#
# Output:
#   dist/<name>-<version>-<arch>-macos.tar.gz   Octez packages
#   dist/<name>-<version>.tar.gz                 data packages (pkgdefs/*.version)
#   dist/manifest-<arch>.txt                     what was packaged, for rendering
#   dist/Formula/<name>.rb, dist/assets.txt      from render_formulae.sh
#
# To publish arm64 and x86_64 together, build and package on each machine,
# copy the other machine's manifest-<arch>.txt and tarballs into dist/, then
# run render_formulae.sh (or this script again) and publish.sh.
#
# --tap, --baseurl and --revision are passed to render_formulae.sh.

set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"

TREE="${here}/work/tezos"
DIST="${here}/dist"
VERSION=""
PACKAGES="zcash-params dal-trusted-setup octez-client octez-node octez-baker octez-accuser octez-vdf octez-dal-node"
ARCH=$(uname -m)
STRIP=1
RENDER=1
RENDERARGS=""

usage() {
	cat <<EOF
Usage: $0 [--tree OctezTree] [--dist OutputDir] [--version Version]
          [--packages "pkg pkg ..."] [--no-strip] [--no-render]
          [--baseurl URL] [--tap user/repo] [--revision N]
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--tree) TREE="$2"; shift ;;
	--dist) DIST="$2"; shift ;;
	--version | -V) VERSION="$2"; shift ;;
	--packages) PACKAGES="$2"; shift ;;
	--no-strip) STRIP=0 ;;
	--no-render) RENDER=0 ;;
	--baseurl | --tap | --revision | -R)
		RENDERARGS="${RENDERARGS} $1 $2"; shift ;;
	*) usage ;;
	esac
	shift
done

case "${ARCH}" in
arm64 | x86_64) ;;
*) echo "Unsupported architecture ${ARCH}" >&2; exit 1 ;;
esac

TREE="$(cd "${TREE}" && pwd -P)"
mkdir -p "${DIST}"
DIST="$(cd "${DIST}" && pwd -P)"
defs="${here}/pkgdefs"
brewprefix=$(brew --prefix)
manifest="${DIST}/manifest-${ARCH}.txt"

# Octez version from the tree: octez-vX.Y[-rcN] -> X.Y[-rcN],
# otherwise a development version.
#
octezVersion() {
	_tag=$(git -C "${TREE}" describe --tags --exact-match 2> /dev/null || true)
	case "${_tag}" in
	octez-v*) echo "${_tag#octez-v}" ;;
	*) echo "0.0.$(date '+%Y%m%d%H%M')-dev.$(git -C "${TREE}" rev-parse --short HEAD)" ;;
	esac
}

# Homebrew formulae that the binaries link against, written to $1.
# Fails if a binary links to a non-portable Homebrew path.
#
dylibDeps() {
	_out=$1
	shift
	for _b in "$@"; do
		otool -L "${_b}" | tail -n +2 | awk '{print $1}' | while read -r _lib; do
			case "${_lib}" in
			/usr/lib/* | /System/*) ;;
			"${brewprefix}"/opt/*)
				echo "${_lib#"${brewprefix}"/opt/}" | cut -d/ -f1 ;;
			*)
				echo "ERROR: $(basename "${_b}") links to non-portable ${_lib}" >&2
				echo "__BAD__" ;;
			esac
		done
	done | sort -u > "${_out}"
	if grep -q __BAD__ "${_out}"; then
		exit 1
	fi
}

[ -n "${VERSION}" ] || VERSION=$(octezVersion)
echo "=> Octez version ${VERSION} (${ARCH})"

# Drop the manifest entries for the packages being rebuilt
touch "${manifest}"
awk -v pk=" ${PACKAGES} " 'index(pk, " " $1 " ") == 0' "${manifest}" > "${manifest}.new"
mv "${manifest}.new" "${manifest}"

for pkg in ${PACKAGES}; do
	if [ -f "${defs}/${pkg}.version" ]; then
		# Data package: same on every architecture
		pkgversion=$(cat "${defs}/${pkg}.version")
		pkgarch="all"
		tag="${pkg}-v${pkgversion}"
		tarball="${pkg}-${pkgversion}.tar.gz"
	else
		pkgversion="${VERSION}"
		pkgarch="${ARCH}"
		tag="octez-v${VERSION}"
		tarball="${pkg}-${pkgversion}-${ARCH}-macos.tar.gz"
	fi
	echo "=> ${pkg} ${pkgversion} (${pkgarch})"

	stagename="${pkg}-${pkgversion}"
	stage="${DIST}/stage/${stagename}"
	rm -rf "${stage}"
	mkdir -p "${stage}"

	# Binaries
	if [ -f "${defs}/${pkg}.binaries" ]; then
		mkdir -p "${stage}/bin"
		for b in $(cat "${defs}/${pkg}.binaries"); do
			[ -f "${TREE}/${b}" ] || { echo "Missing ${TREE}/${b}" >&2; exit 1; }
			cp "${TREE}/${b}" "${stage}/bin/"
			chmod 755 "${stage}/bin/${b}"
			if [ "${STRIP}" = "1" ]; then
				# Removes the symbol table only; OCaml exception
				# backtraces do not depend on it
				strip "${stage}/bin/${b}"
				codesign -v "${stage}/bin/${b}" 2> /dev/null ||
					codesign -s - -f "${stage}/bin/${b}"
			fi
		done
	fi

	# Service wrapper and configuration
	if [ -f "${here}/services/${pkg}-service" ]; then
		mkdir -p "${stage}/libexec" "${stage}/etc/octez"
		cp "${here}/services/${pkg}-service" "${stage}/libexec/"
		cp "${here}/services/${pkg}.conf" "${stage}/etc/octez/"
	fi

	# Data files
	case "${pkg}" in
	zcash-params)
		mkdir -p "${stage}/share/zcash-params"
		cp "${TREE}"/_opam/share/zcash-params/*.params "${stage}/share/zcash-params/"
		;;
	dal-trusted-setup)
		mkdir -p "${stage}/share/dal-trusted-setup"
		cp "${TREE}"/_opam/share/dal-trusted-setup/srsu_zcash_g1 \
			"${TREE}"/_opam/share/dal-trusted-setup/srsu_zcash_g2 \
			"${stage}/share/dal-trusted-setup/"
		;;
	octez-client)
		mkdir -p "${stage}/completions"
		cp "${TREE}/src/bin_client/bash-completion.sh" \
			"${stage}/completions/octez-client.bash"
		;;
	esac

	# Tarball
	# Reproducible: fixed timestamps and owners, no gzip timestamp
	find "${stage}" -exec touch -h -t 200001010000 {} +
	COPYFILE_DISABLE=1 tar -C "${DIST}/stage" --uid 0 --gid 0 \
		--uname root --gname wheel -cf - "${stagename}" |
		gzip -n > "${DIST}/${tarball}"
	sha=$(shasum -a 256 "${DIST}/${tarball}" | awk '{print $1}')

	# Linked Homebrew libraries
	deps="-"
	if [ -d "${stage}/bin" ]; then
		dylibDeps "${DIST}/stage/${pkg}.deps" "${stage}"/bin/*
		if [ -s "${DIST}/stage/${pkg}.deps" ]; then
			deps=$(paste -sd, "${DIST}/stage/${pkg}.deps")
		fi
	fi

	# name version arch tag tarball sha256 deps
	echo "${pkg} ${pkgversion} ${pkgarch} ${tag} ${tarball} ${sha} ${deps}" >> "${manifest}"
	echo "   ${tarball} ${sha}"
done

rm -rf "${DIST}/stage"
echo "=> Manifest ${manifest}"

if [ "${RENDER}" = "1" ]; then
	# shellcheck disable=SC2086
	"${here}/render_formulae.sh" --dist "${DIST}" ${RENDERARGS}
fi
