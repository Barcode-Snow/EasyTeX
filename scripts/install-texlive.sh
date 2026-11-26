#!/bin/bash
# Installs the TeX Live that EasyTeX PLUS ships: every collection except Chinese, Japanese and Korean
# (left out to keep the download under GitHub's 2 GB limit), without documentation or sources.
# Usage: scripts/install-texlive.sh [destination]   (default: build/texlive)
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-build/texlive}"
if [ -x "$DEST/bin/universal-darwin/latexmk" ]; then
  echo "✓ TeX Live is already in $DEST"
  exit 0
fi

# TeX writes its install path into format files and configs. Installing at a fixed, neutral path
# keeps the path of the build machine (user name etc.) out of the app. The tree is moved afterwards.
STAGE="/tmp/easytex-texlive"
WORK="/tmp/easytex-texlive-installer"
rm -rf "$STAGE" "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Pick one mirror and use it for everything, so the package list matches the installer.
REPO="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://mirror.ctan.org/systems/texlive/tlnet/)"
echo "▸ Using $REPO"
curl -fsSL "$REPO/install-tl-unx.tar.gz" | tar xz -C "$WORK"

{
  echo "selected_scheme scheme-custom"
  curl -fsSL "$REPO/tlpkg/texlive.tlpdb" | sed -n 's/^name \(collection-.*\)$/\1/p' \
    | grep -vxE 'collection-lang(cjk|chinese|japanese|korean)' | sed 's/$/ 1/'
  cat <<PROFILE
TEXDIR $STAGE
TEXMFLOCAL $STAGE/texmf-local
TEXMFSYSCONFIG $STAGE/texmf-config
TEXMFSYSVAR $STAGE/texmf-var
binary_universal-darwin 1
tlpdbopt_install_docfiles 0
tlpdbopt_install_srcfiles 0
tlpdbopt_autobackup 0
instopt_adjustpath 0
instopt_adjustrepo 1
instopt_letter 0
PROFILE
} > "$WORK/profile"
echo "▸ Installing $(grep -c '^collection-' "$WORK/profile") collections (takes a while)"
perl "$WORK"/install-tl-*/install-tl --profile="$WORK/profile" --repository "$REPO" --no-interaction

[ -f "$("$STAGE/bin/universal-darwin/kpsewhich" tikz.sty)" ] || { echo "✗ The installation looks incomplete"; exit 1; }
rm -f "$STAGE/install-tl.log" "$STAGE/tlpkg/texlive.profile"
find "$STAGE/texmf-var/web2c" -name "*.log" -delete

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv "$STAGE" "$DEST"
echo "✓ TeX Live installed in $DEST ($(du -sh "$DEST" | cut -f1))"
