#!/bin/sh
#
# Package a built Octez tree (see build_octez.sh) into tarballs and
# Homebrew formulae.
#
# Output:
#   dist/<name>-<version>-arm64-macos.tar.gz
#   dist/Formula/<name>.rb
#
# The defaults produce formulae for local testing (file:// URLs and the
# local/octez tap, see local_tap.sh). For publishing, set --baseurl to where
# the tarballs will be hosted and --tap to the published tap. @TAG@ in
# --baseurl is replaced by the release tag of each tarball: octez-v<version>,
# or <name>-v<version> for packages with a fixed version (pkgdefs/*.version).
# dist/assets.txt lists "tag tarball sha256" for each tarball, for publish.sh.

set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"

TREE="${here}/work/tezos"
DIST="${here}/dist"
BASEURL=""
TAP="local/octez"
VERSION=""
REVISION=0
PACKAGES="zcash-params dal-trusted-setup octez-client octez-node octez-baker octez-accuser octez-vdf octez-dal-node"
ARCH="arm64"
STRIP=1

usage() {
	cat <<EOF
Usage: $0 [--tree OctezTree] [--dist OutputDir] [--baseurl URL]
          [--tap user/repo] [--version Version] [--revision N]
          [--packages "pkg pkg ..."] [--no-strip]
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--tree) TREE="$2"; shift ;;
	--dist) DIST="$2"; shift ;;
	--baseurl) BASEURL="$2"; shift ;;
	--tap) TAP="$2"; shift ;;
	--version | -V) VERSION="$2"; shift ;;
	--revision | -R) REVISION="$2"; shift ;;
	--packages) PACKAGES="$2"; shift ;;
	--no-strip) STRIP=0 ;;
	*) usage ;;
	esac
	shift
done

TREE="$(cd "${TREE}" && pwd -P)"
mkdir -p "${DIST}/Formula"
DIST="$(cd "${DIST}" && pwd -P)"
BASEURL="${BASEURL:-file://${DIST}}"
defs="${here}/pkgdefs"
brewprefix=$(brew --prefix)

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

# CamelCase class name from a formula name: octez-dal-node -> OctezDalNode
#
className() {
	echo "$1" | awk -F- '{ for (i = 1; i <= NF; i++) printf "%s", toupper(substr($i,1,1)) substr($i,2) }'
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

# Replace @TOKEN@ with the value of $T_TOKEN where it is set
#
render() {
	perl -pe 's/@([A-Z0-9_]+)@/exists $ENV{"T_$1"} ? $ENV{"T_$1"} : $&/ge' "$1"
}

[ -n "${VERSION}" ] || VERSION=$(octezVersion)
echo "=> Octez version ${VERSION}"

: > "${DIST}/assets.txt"
for pkg in ${PACKAGES}; do
	if [ -f "${defs}/${pkg}.version" ]; then
		pkgversion=$(cat "${defs}/${pkg}.version")
	else
		pkgversion="${VERSION}"
	fi
	echo "=> ${pkg} ${pkgversion}"

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
	tarball="${pkg}-${pkgversion}-${ARCH}-macos.tar.gz"
	# Reproducible: fixed timestamps and owners, no gzip timestamp
	find "${stage}" -exec touch -h -t 200001010000 {} +
	COPYFILE_DISABLE=1 tar -C "${DIST}/stage" --uid 0 --gid 0 \
		--uname root --gname wheel -cf - "${stagename}" |
		gzip -n > "${DIST}/${tarball}"
	sha=$(shasum -a 256 "${DIST}/${tarball}" | awk '{print $1}')

	# Dependencies: other formulae in the tap, then linked libraries
	depends=""
	if [ -f "${defs}/${pkg}.depends" ]; then
		for d in $(cat "${defs}/${pkg}.depends"); do
			depends="${depends}  depends_on \"${TAP}/${d}\"
"
		done
	fi
	if [ -d "${stage}/bin" ]; then
		dylibDeps "${DIST}/stage/${pkg}.deps" "${stage}"/bin/*
		for d in $(cat "${DIST}/stage/${pkg}.deps"); do
			depends="${depends}  depends_on \"${d}\"
"
		done
	fi

	# Service block
	if [ -f "${stage}/libexec/${pkg}-service" ]; then
		T_NAME="${pkg}"
		export T_NAME
		T_SERVICE=$(render "${here}/templates/service.rb.in")
		T_SERVICE="${T_SERVICE}
"
	else
		T_SERVICE=""
	fi

	# Caveats
	if [ -f "${defs}/${pkg}.caveats" ]; then
		T_CAVEATS="
  def caveats
    <<~EOS
$(sed 's/^/      /' "${defs}/${pkg}.caveats")
    EOS
  end
"
	else
		T_CAVEATS=""
	fi

	# Test
	if [ -f "${defs}/${pkg}.binaries" ]; then
		T_TEST="    system bin/\"$(head -1 "${defs}/${pkg}.binaries")\", \"--version\""
	elif [ -f "${stage}/libexec/${pkg}-service" ]; then
		T_TEST="    assert_path_exists libexec/\"${pkg}-service\""
	else
		T_TEST="    assert_path_exists share/\"${pkg}\""
	fi

	if [ "${REVISION}" -gt 0 ] && [ ! -f "${defs}/${pkg}.version" ]; then
		T_REVISION="  revision ${REVISION}
"
	else
		T_REVISION=""
	fi

	T_CLASS=$(className "${pkg}")
	T_DESC=$(cat "${defs}/${pkg}.desc")
	if [ -f "${defs}/${pkg}.version" ]; then
		tag="${pkg}-v${pkgversion}"
	else
		tag="octez-v${VERSION}"
	fi
	echo "${tag} ${tarball} ${sha}" >> "${DIST}/assets.txt"
	T_URL="$(echo "${BASEURL}" | sed "s|@TAG@|${tag}|g")/${tarball}"
	T_VERSION="${pkgversion}"
	T_SHA256="${sha}"
	T_DEPENDS="${depends}"
	export T_CLASS T_DESC T_URL T_VERSION T_SHA256 T_DEPENDS T_SERVICE \
		T_CAVEATS T_TEST T_REVISION
	render "${here}/templates/formula.rb.in" > "${DIST}/Formula/${pkg}.rb"
	echo "   ${tarball} ${sha}"
done

rm -rf "${DIST}/stage"
echo "=> Formulae in ${DIST}/Formula (tap ${TAP})"
