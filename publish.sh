#!/bin/sh
#
# Publish the output of make_pkgs.sh to a GitHub tap:
#   1. upload each tarball as an asset of its GitHub release (dist/assets.txt)
#   2. copy dist/Formula/*.rb into the tap repository, commit and push
#
# Assets are uploaded before the formulae are pushed, so a published formula
# never points at a missing tarball. An existing asset is kept if its digest
# matches and is an error otherwise (unless --clobber).
#
# make_pkgs.sh must have been run with the matching --tap and --baseurl, e.g.
#   ./make_pkgs.sh --tap drchrispinnock/octez \
#     --baseurl https://github.com/drchrispinnock/homebrew-octez/releases/download/@TAG@

set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"

REPO="drchrispinnock/homebrew-octez"
TAPDIR="${here}/work/homebrew-octez"
DIST="${here}/dist"
CLOBBER=0
PUSH=1

usage() {
	cat <<EOF
Usage: $0 [--repo owner/homebrew-name] [--tap-dir Dir] [--dist Dir]
          [--clobber] [--no-push]
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--repo) REPO="$2"; shift ;;
	--tap-dir) TAPDIR="$2"; shift ;;
	--dist) DIST="$2"; shift ;;
	--clobber) CLOBBER=1 ;;
	--no-push) PUSH=0 ;;
	*) usage ;;
	esac
	shift
done

command -v gh > /dev/null || { echo "Missing gh" >&2; exit 1; }
[ -f "${DIST}/assets.txt" ] || { echo "No ${DIST}/assets.txt; run make_pkgs.sh" >&2; exit 1; }

baseurl="https://github.com/${REPO}/releases/download/"
if grep -L -F "${baseurl}" "${DIST}"/Formula/*.rb | grep -q .; then
	echo "Formulae in ${DIST}/Formula do not point at ${baseurl}" >&2
	exit 1
fi

# All tarballs must be here, including those copied from another machine
missing=0
while read -r tag tarball sha; do
	if [ ! -f "${DIST}/${tarball}" ]; then
		echo "Missing ${DIST}/${tarball}" >&2
		missing=1
	elif [ "$(shasum -a 256 "${DIST}/${tarball}" | awk '{print $1}')" != "${sha}" ]; then
		echo "${DIST}/${tarball} does not match its manifest sha256" >&2
		missing=1
	fi
done < "${DIST}/assets.txt"
[ "${missing}" = "0" ] || exit 1

# 1. Release assets
#
while read -r tag tarball sha; do
	if ! gh release view "${tag}" -R "${REPO}" > /dev/null 2>&1; then
		echo "=> Creating release ${tag}"
		gh release create "${tag}" -R "${REPO}" --title "${tag}" \
			--notes "Octez Homebrew packages (macOS arm64)."
	fi
	digest=$(gh api "repos/${REPO}/releases/tags/${tag}" \
		--jq ".assets[] | select(.name == \"${tarball}\") | .digest")
	if [ -z "${digest}" ]; then
		echo "=> Uploading ${tarball} to ${tag}"
		gh release upload "${tag}" "${DIST}/${tarball}" -R "${REPO}"
	elif [ "${digest}" = "sha256:${sha}" ]; then
		echo "=> ${tarball} already in ${tag}"
	elif [ "${CLOBBER}" = "1" ]; then
		echo "=> Replacing ${tarball} in ${tag}"
		gh release upload "${tag}" "${DIST}/${tarball}" -R "${REPO}" --clobber
	else
		echo "${tarball} in ${tag} has digest ${digest}, expected sha256:${sha}" >&2
		echo "Use --clobber to replace it" >&2
		exit 1
	fi
done < "${DIST}/assets.txt"

# 2. Formulae
#
if [ ! -d "${TAPDIR}/.git" ]; then
	mkdir -p "$(dirname "${TAPDIR}")"
	gh repo clone "${REPO}" "${TAPDIR}"
fi
if git -C "${TAPDIR}" rev-parse -q --verify HEAD > /dev/null; then
	git -C "${TAPDIR}" pull -q --ff-only
fi
mkdir -p "${TAPDIR}/Formula"
cp "${DIST}"/Formula/*.rb "${TAPDIR}/Formula/"
[ -f "${TAPDIR}/README.md" ] || cp "${here}/templates/tap-README.md" "${TAPDIR}/README.md"

git -C "${TAPDIR}" add -A
if git -C "${TAPDIR}" diff --cached --quiet; then
	echo "=> Tap already up to date"
	exit 0
fi
versions=$(awk '{print $1}' "${DIST}/assets.txt" | sort -u | tr '\n' ' ')
git -C "${TAPDIR}" commit -q -m "Update formulae: ${versions% }"
if [ "${PUSH}" = "1" ]; then
	git -C "${TAPDIR}" push -q -u origin HEAD:main
	echo "=> Pushed ${REPO}"
else
	echo "=> Committed in ${TAPDIR} (not pushed)"
fi
