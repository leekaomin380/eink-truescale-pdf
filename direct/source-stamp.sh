# Sourced by direct/build-helper.sh and gui/build-app.sh.
# One hash over everything that goes into the direct runtime, so a stale runtime can be detected.
# Usage: direct_source_stamp <direct dir>. Fails (no output) if any source file is missing, so a
# broken path can never produce a constant hash that "matches". (Not ${(%):-%x}: prompt expansion
# mangles the non-ASCII repo path.)
direct_source_stamp() {
  local dir="$1" file sums=""
  for file in quaderno_direct.py requirements-build.txt build-helper.sh; do
    [[ -f "$dir/$file" ]] || { print -u2 "source-stamp: missing $dir/$file"; return 1; }
    sums+="$(/usr/bin/shasum -a 256 < "$dir/$file")"$'\n'
  done
  print -rn -- "$sums" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}
