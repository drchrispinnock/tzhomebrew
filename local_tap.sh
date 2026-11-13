#!/bin/sh
#
# Copy the formulae from make_pkgs.sh into a local tap so they can be
# installed and tested, e.g.:
#   ./local_tap.sh && brew install local/octez/octez-node
#
# Homebrew only installs formulae from taps, not from loose files.

set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
TAP="${1:-local/octez}"
FORMULAE="${2:-${here}/dist/Formula}"

taproot=$(brew --repository)/Library/Taps/${TAP%%/*}/homebrew-${TAP#*/}
if [ ! -d "${taproot}" ]; then
	brew tap-new --no-git "${TAP}"
fi
mkdir -p "${taproot}/Formula"
cp "${FORMULAE}"/*.rb "${taproot}/Formula/"
echo "=> Formulae copied to ${taproot}/Formula"
ls "${taproot}/Formula"
