#!/bin/sh
#
# Render Homebrew formulae from the manifests that make_pkgs.sh writes
# (dist/manifest-<arch>.txt), combining architectures into on_arm/on_intel
# blocks. Formulae built for one architecture only get a depends_on arch.
#
# Output:
#   dist/Formula/<name>.rb
#   dist/assets.txt   "tag tarball sha256" for publish.sh
#
# The defaults produce formulae for local testing (file:// URLs and the
# local/octez tap, see local_tap.sh). For publishing, set --baseurl to where
# the tarballs will be hosted and --tap to the published tap. @TAG@ in
# --baseurl is replaced by each tarball's release tag: octez-v<version>, or
# <name>-v<version> for data packages.

set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"

DIST="${here}/dist"
BASEURL=""
TAP="local/octez"

usage() {
	cat <<EOF
Usage: $0 [--dist Dir] [--baseurl URL] [--tap user/repo]
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--dist) DIST="$2"; shift ;;
	--baseurl) BASEURL="$2"; shift ;;
	--tap) TAP="$2"; shift ;;
	*) usage ;;
	esac
	shift
done

DIST="$(cd "${DIST}" && pwd -P)"
BASEURL="${BASEURL:-file://${DIST}}"
defs="${here}/pkgdefs"

ls "${DIST}"/manifest-*.txt > /dev/null 2>&1 ||
	{ echo "No manifests in ${DIST}; run make_pkgs.sh" >&2; exit 1; }
manifests() { cat "${DIST}"/manifest-*.txt; }

# Within a component (release tag prefix: the tag less its version), all
# architecture-specific packages must be the same version
mixed=$(manifests | awk '$3 != "all" {
	p = substr($4, 1, length($4) - length($2))
	if (p in v && v[p] != $2) { print p ": " v[p] " and " $2 }
	v[p] = $2
}')
if [ -n "${mixed}" ]; then
	echo "Manifests mix versions:" >&2
	echo "${mixed}" >&2
	exit 1
fi

# Manifest entry for package $1 and architecture $2 (first match)
entry() {
	manifests | awk -v p="$1" -v a="$2" '$1 == p && $3 == a' | head -1
}

# Field $2 of manifest line $1
field() {
	echo "$1" | awk -v n="$2" '{ print $n }'
}

# Linked libraries of manifest line $1, one per line
deps() {
	_d=$(field "$1" 7)
	[ "${_d}" = "-" ] || echo "${_d}" | tr , '\n'
}

# url and sha256 lines for manifest line $1, indented by $2
srcLines() {
	_url="$(echo "${BASEURL}" | sed "s|@TAG@|$(field "$1" 4)|g")/$(field "$1" 5)"
	echo "$2url \"${_url}\""
	echo "$2sha256 \"$(field "$1" 6)\""
	echo "$(field "$1" 4) $(field "$1" 5) $(field "$1" 6)" >> "${DIST}/assets.txt"
}

# CamelCase class name from a formula name: octez-dal-node -> OctezDalNode
className() {
	echo "$1" | awk -F- '{ for (i = 1; i <= NF; i++) printf "%s", toupper(substr($i,1,1)) substr($i,2) }'
}

# Replace @TOKEN@ with the value of $T_TOKEN where it is set
render() {
	perl -pe 's/@([A-Z0-9_]+)@/exists $ENV{"T_$1"} ? $ENV{"T_$1"} : $&/ge' "$1"
}

mkdir -p "${DIST}/Formula"
rm -f "${DIST}"/Formula/*.rb
: > "${DIST}/assets.txt"
tmp="${DIST}/.render"
rm -rf "${tmp}"
mkdir -p "${tmp}"

for pkg in $(manifests | awk '!seen[$1]++ { print $1 }'); do
	all=$(entry "${pkg}" all)
	arm=$(entry "${pkg}" arm64)
	intel=$(entry "${pkg}" x86_64)
	archs=""
	: > "${tmp}/sources"
	: > "${tmp}/depends"

	if [ -n "${all}" ]; then
		shas=$(manifests | awk -v p="${pkg}" '$1 == p && $3 == "all" { print $6 }' | sort -u | wc -l)
		[ "${shas}" -eq 1 ] || echo "WARNING: ${pkg} differs between manifests; using the first" >&2
		pkgversion=$(field "${all}" 2)
		srcLines "${all}" "  " >> "${tmp}/sources"
	else
		[ -n "${arm}" ] && archs="${archs} arm64"
		[ -n "${intel}" ] && archs="${archs} x86_64"
		pkgversion=$(field "${arm:-${intel}}" 2)
		[ -n "${arm}" ] && deps "${arm}" | sort > "${tmp}/arm"
		[ -n "${intel}" ] && deps "${intel}" | sort > "${tmp}/intel"
		if [ -n "${arm}" ] && [ -n "${intel}" ]; then
			# Common libraries at the top, the rest per architecture
			comm -12 "${tmp}/arm" "${tmp}/intel" > "${tmp}/common"
			comm -23 "${tmp}/arm" "${tmp}/intel" > "${tmp}/armonly"
			comm -13 "${tmp}/arm" "${tmp}/intel" > "${tmp}/intelonly"
		elif [ -n "${arm}" ]; then
			cp "${tmp}/arm" "${tmp}/common"
			: > "${tmp}/armonly"
			echo "  depends_on arch: :arm64" >> "${tmp}/depends"
		else
			cp "${tmp}/intel" "${tmp}/common"
			: > "${tmp}/intelonly"
			echo "  depends_on arch: :x86_64" >> "${tmp}/depends"
		fi
		if [ -n "${arm}" ]; then
			{
				echo "  on_arm do"
				srcLines "${arm}" "    "
				sed 's/.*/    depends_on "&"/' "${tmp}/armonly"
				echo "  end"
			} >> "${tmp}/sources"
		fi
		if [ -n "${intel}" ]; then
			{
				echo "  on_intel do"
				srcLines "${intel}" "    "
				sed 's/.*/    depends_on "&"/' "${tmp}/intelonly"
				echo "  end"
			} >> "${tmp}/sources"
		fi
	fi

	# Dependencies: other formulae in the tap, then linked libraries
	if [ -f "${defs}/${pkg}.depends" ]; then
		sed "s|.*|  depends_on \"${TAP}/&\"|" "${defs}/${pkg}.depends" >> "${tmp}/depends"
	fi
	if [ -s "${tmp}/common" ] && [ -z "${all}" ]; then
		sed 's/.*/  depends_on "&"/' "${tmp}/common" >> "${tmp}/depends"
	fi
	rm -f "${tmp}/common"

	# Service block
	if [ -f "${here}/services/${pkg}-service" ]; then
		T_NAME="${pkg}"
		export T_NAME
		T_SERVICE="$(render "${here}/templates/service.rb.in")
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
	elif [ -f "${here}/services/${pkg}-service" ]; then
		T_TEST="    assert_path_exists libexec/\"${pkg}-service\""
	else
		T_TEST="    assert_path_exists share/\"${pkg}\""
	fi

	# Revision (manifest field 8, from make_pkgs.sh --revision): the highest
	# of the architectures, so both see the same formula version
	revision=0
	for e in "${arm}" "${intel}"; do
		[ -n "${e}" ] || continue
		r=$(field "${e}" 8)
		[ "${r:-0}" -gt "${revision}" ] && revision="${r}"
	done
	if [ "${revision}" -gt 0 ] && [ -z "${all}" ]; then
		T_REVISION="  revision ${revision}
"
	else
		T_REVISION=""
	fi

	T_CLASS=$(className "${pkg}")
	T_DESC=$(cat "${defs}/${pkg}.desc")
	T_VERSION="${pkgversion}"
	T_SOURCES=$(cat "${tmp}/sources")
	T_DEPENDS=$(cat "${tmp}/depends")
	[ -z "${T_DEPENDS}" ] || T_DEPENDS="${T_DEPENDS}
"
	export T_CLASS T_DESC T_VERSION T_SOURCES T_DEPENDS T_SERVICE \
		T_CAVEATS T_TEST T_REVISION
	render "${here}/templates/formula.rb.in" > "${DIST}/Formula/${pkg}.rb"
	echo "=> ${pkg} ${pkgversion} ${all:+(all)}${archs}"
done

rm -rf "${tmp}"
sort -u -o "${DIST}/assets.txt" "${DIST}/assets.txt"
echo "=> Formulae in ${DIST}/Formula (tap ${TAP})"
