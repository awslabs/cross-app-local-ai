#!/usr/bin/env bash
# Prepends the MIT/SPDX license header to all .swift files that lack one.
# Usage: Tools/add_license_headers.sh [directory]
#   directory — root to scan (default: current directory)

set -euo pipefail

DIR="${1:-.}"
MARKER="SPDX-License-Identifier"

HEADER='// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT
'

added=0
skipped=0

while IFS= read -r -d '' file; do
    if head -5 "$file" | grep -q "$MARKER"; then
        skipped=$((skipped + 1))
    else
        tmp=$(mktemp)
        printf '%s\n' "$HEADER" | cat - "$file" > "$tmp"
        mv "$tmp" "$file"
        added=$((added + 1))
    fi
done < <(find "$DIR" -name '*.swift' -not -path '*/.build/*' -not -path '*/DerivedData/*' -not -path '*/build/*' -not -path '*/.git/*' -not -path '*/scratch/*' -print0)

echo "License headers: added=$added, already present=$skipped"
