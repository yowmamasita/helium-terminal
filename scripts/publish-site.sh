#!/bin/sh
# Publishes site/ to the gh-pages branch, which GitHub Pages serves at
# https://helium-terminal.bensarmiento.com. Only that branch is pushed.
set -eu
cd "$(dirname "$0")/.."
git diff --quiet -- site && git diff --cached --quiet -- site || { echo "commit site/ first" >&2; exit 1; }
git fetch -q origin gh-pages
split=$(git subtree split --prefix site)
tree=$(git rev-parse "$split^{tree}")
[ "$tree" != "$(git rev-parse 'origin/gh-pages^{tree}')" ] || { echo "site already published"; exit 0; }
# A merge on top of gh-pages, so commits made there (say, a CNAME edit on GitHub) never block a publish; site/ wins.
commit=$(git commit-tree "$tree" -p origin/gh-pages -p "$split" -m "Publish site/ from $(git rev-parse --short HEAD)")
git push origin "$commit:refs/heads/gh-pages"
git branch -f gh-pages "$commit"
