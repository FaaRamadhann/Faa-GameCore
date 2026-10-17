#!/system/bin/sh
# gamelist.sh — the ONE place that knows the on-disk shape of config/gamelist.json.
#
# The file is written PRETTY so it stays readable when a user (or a bug report)
# opens it:
#   {"games": [
#       {
#           "package": "com.example.game",
#           "label": "Example Game",
#           "profile": 3
#       },
#       {
#           "package": "com.example.chess",
#           "label": "Chess",
#           "profile": 0
#       }
#   ]}
# An empty gamelist is the compact one-liner `{"games": []}`.
#
# Readers are LAYOUT-TOLERANT: newlines are stripped before parsing, so a file
# written by an older FGC (single line, or python's indent=1) parses exactly
# like the pretty form. Labels are carried around as the JSON-ESCAPED text just
# as stored, so a rewrite can never double-escape or corrupt them (jesc already
# removed every tab/CR/LF, which keeps the TSV transport below safe).
#
# Writes are atomic (tmp + rename) and verified.
#
# All locals are named _gl_*: these functions are called from the CLI, and POSIX
# sh has no scoping — a plain `_p` inside here would silently overwrite the
# caller's package variable and corrupt the very command being served.
#
# Pure POSIX sh + tr/sed/grep. No python, no `local`, no awk.

fgc_pkg_ok() {
  # $1 = candidate package name: exact charset only (no shell/sed metachars).
  case "$1" in ''|*[!a-zA-Z0-9._]*) return 1 ;; *) return 0 ;; esac
}

fgc_glist_dump() {
  # $1 = gamelist.json -> one line per game: pkg<TAB>label<TAB>profile
  # Missing/unreadable file prints nothing (callers treat that as "empty").
  _gl_f="$1"
  [ -f "$_gl_f" ] || return 0
  _gl_one="$(tr -d '\n\r' < "$_gl_f" 2>/dev/null)"
  case "$_gl_one" in *'"games"'*) ;; *) return 0 ;; esac
  # Packages in file order, then each one's own label/profile: packages are
  # unique, so an anchored match can only hit that game's object.
  printf '%s' "$_gl_one" | grep -o '"package"[ ]*:[ ]*"[a-zA-Z0-9._]*"' 2>/dev/null > "$_gl_f.pkgs"
  while IFS= read -r _gl_m; do
    _gl_p="${_gl_m%\"}"; _gl_p="${_gl_p##*\"}"   # drop trailing, then opening quote
    fgc_pkg_ok "$_gl_p" || continue
    # Label = the string that ends right before "profile": that anchor stops the
    # greedy [^}]* from swallowing the rest of the object. Fallback covers a
    # hand-edited object with no profile key (label ends at the object brace).
    _gl_l="$(printf '%s' "$_gl_one" | sed -n "s/.*\"package\"[ ]*:[ ]*\"$_gl_p\"[^}]*\"label\"[ ]*:[ ]*\"\([^}]*\)\"[ ]*,[ ]*\"profile\".*/\1/p")"
    [ -n "$_gl_l" ] || _gl_l="$(printf '%s' "$_gl_one" | sed -n "s/.*\"package\"[ ]*:[ ]*\"$_gl_p\"[^}]*\"label\"[ ]*:[ ]*\"\([^}]*\)\"[ ]*[,}].*/\1/p")"
    _gl_pf="$(printf '%s' "$_gl_one" | sed -n "s/.*\"package\"[ ]*:[ ]*\"$_gl_p\"[^}]*\"profile\"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p")"
    case "$_gl_pf" in ''|*[!0-9]*) _gl_pf=0 ;; esac
    [ -n "$_gl_l" ] || _gl_l="$_gl_p"
    printf '%s\t%s\t%s\n' "$_gl_p" "$_gl_l" "$_gl_pf"
  done < "$_gl_f.pkgs"
  rm -f "$_gl_f.pkgs" 2>/dev/null
}

fgc_glist_profile() {
  # $1 = gamelist.json, $2 = package -> its per-game profile, or nothing.
  # Layout-tolerant: the file is COMPACTED first, because a pretty-printed
  # object spans several lines and a line-oriented sed could never match it.
  _gl_f="$1"; _gl_q="$2"
  fgc_pkg_ok "$_gl_q" || return 0
  [ -f "$_gl_f" ] || return 0
  _gl_one="$(tr -d '\n\r' < "$_gl_f" 2>/dev/null)"
  printf '%s' "$_gl_one" | sed -n "s/.*\"package\"[ ]*:[ ]*\"$_gl_q\"[^}]*\"profile\"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p"
}

fgc_glist_pretty() {
  # stdin: pkg<TAB>label<TAB>profile -> stdout: the pretty gamelist document.
  _gl_tab="$(printf '\t')"
  _gl_started=0
  while IFS="$_gl_tab" read -r _gl_p _gl_l _gl_pf || [ -n "$_gl_p" ]; do
    fgc_pkg_ok "$_gl_p" || continue
    case "$_gl_pf" in ''|*[!0-9]*) _gl_pf=0 ;; esac
    _gl_l="$(printf '%s' "$_gl_l" | tr -d '\t\n\r')"
    [ -n "$_gl_l" ] || _gl_l="$_gl_p"
    if [ "$_gl_started" = "0" ]; then
      _gl_started=1; printf '{"games": [\n'
    else
      printf ',\n'
    fi
    printf '    {\n        "package": "%s",\n        "label": "%s",\n        "profile": %s\n    }' "$_gl_p" "$_gl_l" "$_gl_pf"
  done
  if [ "$_gl_started" = "0" ]; then
    printf '{"games": []}\n'
  else
    printf '\n]}\n'
  fi
}

fgc_glist_normalize() {
  # $1 = gamelist.json. Upgrade a legacy COMPACT document (one line) to the
  # pretty layout so it can be read and edited by hand. Idempotent: an already
  # pretty file, and the canonical empty form, are left completely untouched —
  # no rewrite on every boot. A backup is taken first and restored if the
  # rewrite would lose a game (fgc_glist_write verifies the count).
  _gl_nf="$1"
  [ -f "$_gl_nf" ] || return 0
  grep -q '"package"' "$_gl_nf" 2>/dev/null || return 0
  [ "$(head -n 1 "$_gl_nf" 2>/dev/null)" = "{" ] && return 0
  fgc_glist_dump "$_gl_nf" > "$_gl_nf.norm" 2>/dev/null || { rm -f "$_gl_nf.norm" 2>/dev/null; return 1; }
  [ -s "$_gl_nf.norm" ] || { rm -f "$_gl_nf.norm" 2>/dev/null; return 1; }
  cp "$_gl_nf" "$_gl_nf.bak" 2>/dev/null
  if fgc_glist_write "$_gl_nf" < "$_gl_nf.norm"; then
    rm -f "$_gl_nf.norm" 2>/dev/null
    return 0
  fi
  cp "$_gl_nf.bak" "$_gl_nf" 2>/dev/null
  rm -f "$_gl_nf.norm" 2>/dev/null
  return 1
}

fgc_glist_write() {
  # $1 = gamelist.json. stdin: pkg<TAB>label<TAB>profile lines. Writes the
  # pretty document atomically and only then renames it over the original: a
  # partial write must never leave a truncated gamelist behind. Returns 1
  # (original untouched) unless the written document provably carries exactly
  # as many games as it was handed (a row the writer skipped = a lost game).
  _gl_f="$1"; _gl_tmp="$1.tmp"; _gl_in="$1.in"
  cat > "$_gl_in" 2>/dev/null || { rm -f "$_gl_in" 2>/dev/null; return 1; }
  _gl_want="$(grep -c . "$_gl_in" 2>/dev/null)"
  case "$_gl_want" in ''|*[!0-9]*) _gl_want=0 ;; esac
  fgc_glist_pretty < "$_gl_in" > "$_gl_tmp" 2>/dev/null || { rm -f "$_gl_in" "$_gl_tmp" 2>/dev/null; return 1; }
  rm -f "$_gl_in" 2>/dev/null
  grep -q '"games"' "$_gl_tmp" 2>/dev/null || { rm -f "$_gl_tmp" 2>/dev/null; return 1; }
  _gl_got="$(grep -c '"package"[ ]*:[ ]*"' "$_gl_tmp" 2>/dev/null)"
  case "$_gl_got" in ''|*[!0-9]*) _gl_got=0 ;; esac
  [ "$_gl_got" = "$_gl_want" ] || { rm -f "$_gl_tmp" 2>/dev/null; return 1; }
  mv "$_gl_tmp" "$_gl_f" 2>/dev/null || { rm -f "$_gl_tmp" 2>/dev/null; return 1; }
  return 0
}
