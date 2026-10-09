#!/bin/sh
# Publishes site/ to the gh-pages branch, which GitHub Pages serves at
# https://helium-terminal.bensarmiento.com. Only that branch is pushed.
set -eu
cd "$(dirname "$0")/.."
git diff --quiet -- site && git diff --cached --quiet -- site || { echo "commit site/ first" >&2; exit 1; }
git subtree split --prefix site -b gh-pages
git push origin gh-pages
