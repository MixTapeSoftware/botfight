#!/bin/sh
# Print a plain-text map of where a PR's changed lines are.
#
#   change-map.sh OWNER/REPO PR-NUMBER
#
# Needs only gh (authenticated), awk, and sort. Changed lines are additions
# plus deletions. Files are grouped by directory (two levels deep); lockfiles,
# snapshots, generated, and vendored files each get their own tagged row so
# they stand out. Rows are sorted by changed lines, and each bar shows that
# row's share of the PR's total.

set -eu

if [ $# -ne 2 ]; then
  echo "usage: $0 OWNER/REPO PR-NUMBER" >&2
  exit 2
fi

MAX_ROWS=15
BAR_WIDTH=20
TAB=$(printf '\t')

# Fetch before the pipeline: POSIX sh has no pipefail, so a gh failure inside
# the pipeline would be masked and print "No changed files." with exit 0. With
# set -e, a failing command substitution in an assignment exits here instead.
rows=$(gh api --paginate "repos/$1/pulls/$2/files" \
  --jq '.[] | [.filename, .additions, .deletions] | @tsv')

printf "%s\n" "$rows" |
awk -F '\t' -v OFS='\t' '
  function tag_for(p,   base) {
    base = p; sub(/.*\//, "", base)
    if (base ~ /^(pnpm-lock\.yaml|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|bun\.lockb?|Cargo\.lock|Gemfile\.lock|poetry\.lock|Pipfile\.lock|uv\.lock|pdm\.lock|composer\.lock|go\.sum|mix\.lock|flake\.lock|Podfile\.lock|Package\.resolved|packages\.lock\.json|pubspec\.lock|gradle\.lockfile)$/) return "lockfile"
    if (p ~ /\.snap$/ || p ~ /(^|\/)(__snapshots__|snapshots)\//) return "snapshot"
    if (p ~ /(^|\/)(vendor|third_party|node_modules)\//) return "vendored"
    if (p ~ /\.min\.(js|css)$/ || p ~ /\.map$/ || p ~ /[._]generated\./ || p ~ /\.pb\.go$/ || p ~ /_pb2(_grpc)?\.py$/ || p ~ /\.(g|freezed)\.dart$/ || p ~ /(^|\/)(dist|build)\//) return "generated"
    return ""
  }
  function group_for(p,   n, parts) {
    n = split(p, parts, "/")
    if (n == 1) return p
    if (n == 2) return parts[1] "/"
    return parts[1] "/" parts[2] "/"
  }
  NF == 0 { next }
  {
    tag = tag_for($1)
    key = tag != "" ? $1 : group_for($1)
    if (!(key in files)) order[++n] = key
    tags[key] = tag; add[key] += $2; del[key] += $3; files[key]++; last[key] = $1
  }
  END {
    for (i = 1; i <= n; i++) {
      k = order[i]
      label = (tags[k] == "" && files[k] == 1) ? last[k] : k
      if (tags[k] != "") label = label " [" tags[k] "]"
      print add[k] + del[k], label, tags[k], add[k], del[k], files[k]
    }
  }' |
sort -t "$TAB" -k1,1nr -k2,2 |
awk -F '\t' -v max_rows="$MAX_ROWS" -v bar_width="$BAR_WIDTH" '
  function commas(x,   s) {
    s = sprintf("%d", x)
    while (s ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]([,]|$)/, ",&", s)
    return s
  }
  function pct(x) {
    if (total == 0) return "0%"
    if (x > 0 && 100 * x / total < 1) return "<1%"
    return sprintf("%d%%", 100 * x / total + 0.5)
  }
  function bar(x,   len, s, i) {
    len = (x == 0 || total == 0) ? 0 : int(bar_width * x / total + 0.5)
    if (x > 0 && len < 1) len = 1
    s = ""
    for (i = 0; i < bar_width; i++) s = s (i < len ? "█" : " ")
    return s
  }
  {
    rows++; lines[rows] = $1; label[rows] = $2; tag[rows] = $3
    add[rows] = $4; del[rows] = $5; nfiles[rows] = $6
    total += $1; tadd += $4; tdel += $5; tfiles += $6
    if ($3 != "") tagged += $1
  }
  END {
    if (rows == 0) { print "No changed files."; exit }
    shown = rows < max_rows ? rows : max_rows
    for (i = 1; i <= shown; i++) if (length(label[i]) > width) width = length(label[i])
    printf "%s files · %s lines changed (+%s −%s)\n", commas(tfiles), commas(total), commas(tadd), commas(tdel)
    if (tagged) printf "Lockfiles, snapshots, generated, vendored: %s lines (%s)\n", commas(tagged), pct(tagged)
    print ""
    for (i = 1; i <= shown; i++) {
      line = sprintf("%-" width "s  %7s  %4s  %s  +%s −%s", label[i], commas(lines[i]), pct(lines[i]), bar(lines[i]), commas(add[i]), commas(del[i]))
      if (nfiles[i] > 1) line = line "  " nfiles[i] " files"
      sub(/ +$/, "", line)
      print line
    }
    if (rows > shown) {
      for (i = shown + 1; i <= rows; i++) { hl += lines[i]; hf += nfiles[i] }
      printf "… %s more files in %d groups: %s lines (%s)\n", commas(hf), rows - shown, commas(hl), pct(hl)
    }
  }'
