#!/bin/sh
# Bundles the graphic before Quarto renders the site.
cd "$(dirname "$0")" || exit 1
[ -d node_modules ] || npm ci
npm run build
