# ---------------------------------------------------------------------------
# Shared helper: make sure the tool needed by a format is installed.
# ---------------------------------------------------------------------------

# Install a missing tool with pacman.
# Usage: _archive_require <command> <pacman-package>
_archive_require() {
  local cmd=$1 pkg=$2
  command -v "$cmd" >/dev/null 2>&1 && return 0

  if ! command -v pacman >/dev/null 2>&1; then
    echo "Missing '$cmd'; install the '$pkg' package for your distribution" >&2
    return 1
  fi

  echo "Missing '$cmd' -> installing package '$pkg'..." >&2
  sudo pacman -S --needed "$pkg" || {
    echo "Could not install '$pkg'" >&2
    return 1
  }

  command -v "$cmd" >/dev/null 2>&1 || {
    echo "'$pkg' installed but '$cmd' is still not on PATH" >&2
    return 1
  }
}

# Map an internal format kind to the tools it needs, then require them.
# Usage: _archive_require_kind <kind> <mode>   where mode is "extract" or "compress"
_archive_require_kind() {
  local kind=$1 mode=$2

  case "$kind" in
    tar|tar_gz|tar_bz2|tar_xz) _archive_require tar tar || return 1 ;;
    tar_zst)
      _archive_require tar tar || return 1
      _archive_require zstd zstd || return 1
      ;;
    zip)
      if [[ "$mode" == extract ]]; then
        _archive_require unzip unzip || return 1
      else
        _archive_require zip zip || return 1
      fi
      ;;
    sevenzip) _archive_require 7z p7zip || return 1 ;;
    rar)      _archive_require unrar unrar || return 1 ;;
    raw_gz)   _archive_require gzip gzip || return 1 ;;
    raw_bz2)  _archive_require bzip2 bzip2 || return 1 ;;
    raw_xz)   _archive_require xz xz || return 1 ;;
    raw_zst)  _archive_require zstd zstd || return 1 ;;
    raw_z)    _archive_require uncompress ncompress || return 1 ;;
    iso)
      # Any one of these can read ISO9660; only install if none is present.
      command -v bsdtar >/dev/null 2>&1 && return 0
      command -v 7z     >/dev/null 2>&1 && return 0
      command -v 7zz    >/dev/null 2>&1 && return 0
      _archive_require bsdtar libarchive || return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# extract
# ---------------------------------------------------------------------------

# Extract any archive.
# Usage: extract [-r] <archive> [destination]
#   -r  remove the archive once it has been extracted successfully
extract() {
  local remove=0

  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -r|--remove) remove=1; shift ;;
      -h|--help)
        echo "Usage: extract [-r] <archive> [destination]" >&2
        echo "  -r  remove the archive after a successful extraction" >&2
        return 0
        ;;
      --) shift; break ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: extract [-r] <archive> [destination]" >&2
    return 1
  fi

  if [[ ! -f "$1" ]]; then
    echo "File not found: $1" >&2
    return 1
  fi

  local archive dest base lower kind inner mnt created=0 rc=0
  archive=$(realpath -- "$1") || return 1
  base=$(basename -- "$archive")
  lower=$(printf '%s' "$archive" | tr '[:upper:]' '[:lower:]')

  # Resolve the handler before touching the filesystem, so an unsupported
  # format never leaves an empty destination directory behind.
  case "$lower" in
    *.tar.bz2|*.tbz2)                     kind=tar_bz2 ;;
    *.tar.gz|*.tgz)                       kind=tar_gz ;;
    *.tar.xz|*.txz)                       kind=tar_xz ;;
    *.tar.zst|*.tzst)                     kind=tar_zst ;;
    *.tar)                                kind=tar ;;
    *.zip|*.jar|*.war|*.apk|*.epub|*.whl) kind=zip ;;
    *.iso)                                kind=iso ;;
    *.7z)                                 kind=sevenzip ;;
    *.rar)                                kind=rar ;;
    *.bz2)                                kind=raw_bz2 ;;
    *.gz)                                 kind=raw_gz ;;
    *.xz)                                 kind=raw_xz ;;
    *.zst)                                kind=raw_zst ;;
    *.z)                                  kind=raw_z ;;
    *) echo "Unsupported format: $1" >&2; return 1 ;;
  esac

  # Install any missing tool before creating the destination directory.
  _archive_require_kind "$kind" extract || return 1

  dest=${2:-.}
  if [[ ! -d "$dest" ]]; then
    mkdir -p "$dest" || { echo "Cannot create destination: $dest" >&2; return 1; }
    created=1
  fi
  dest=$(realpath "$dest") || return 1

  case "$kind" in
    tar_bz2)  tar xjf "$archive" -C "$dest" ;;
    tar_gz)   tar xzf "$archive" -C "$dest" ;;
    tar_xz)   tar xJf "$archive" -C "$dest" ;;
    tar_zst)  tar --zstd -xf "$archive" -C "$dest" ;;
    tar)      tar xf "$archive" -C "$dest" ;;
    zip)      unzip -q -o "$archive" -d "$dest" ;;
    sevenzip) 7z x -o"$dest" "$archive" ;;
    rar)      unrar x "$archive" "$dest/" ;;

    # ISO9660 has no single standard extractor. Try the userspace tools first
    # and fall back to a read-only loop mount, which requires root.
    iso)
      if command -v bsdtar >/dev/null 2>&1; then
        bsdtar xf "$archive" -C "$dest"
      elif command -v 7z >/dev/null 2>&1; then
        7z x -o"$dest" "$archive"
      elif command -v 7zz >/dev/null 2>&1; then
        7zz x -o"$dest" "$archive"
      else
        mnt=$(mktemp -d) || return 1
        if sudo mount -o loop,ro "$archive" "$mnt"; then
          cp -a "$mnt/." "$dest/"
          rc=$?
          sudo umount "$mnt"
        else
          echo "Cannot mount ISO image" >&2
          rc=1
        fi
        rmdir "$mnt" 2>/dev/null
        (( rc != 0 && created == 1 )) && rmdir "$dest" 2>/dev/null
        (( rc == 0 && remove == 1 )) && rm -f "$archive"
        return $rc
      fi
      ;;

    # Single-file compressors have no destination flag and would consume the
    # source in place, so decompress to stdout and rebuild the name ourselves.
    raw_gz)
      # Prefer the original name recorded in the gzip header when present.
      inner=$(gzip -lNv "$archive" 2>/dev/null | awk 'NR==2 {print $NF}')
      [[ -z "$inner" || "$inner" == "$base" ]] && inner=${base%.*}
      # Strip any directory component: the stored name must not escape dest.
      inner=$(basename -- "$inner")
      gunzip -c "$archive" > "$dest/$inner"
      ;;
    raw_bz2)  bunzip2 -c "$archive" > "$dest/${base%.*}" ;;
    raw_xz)   unxz    -c "$archive" > "$dest/${base%.*}" ;;
    raw_zst)  zstd -d -c "$archive" > "$dest/${base%.*}" ;;
    raw_z)    uncompress -c "$archive" > "$dest/${base%.*}" ;;
  esac
  rc=$?

  # Roll back a directory we created ourselves if the extraction left it empty.
  if (( rc != 0 && created == 1 )); then
    rmdir "$dest" 2>/dev/null
  fi

  # Only drop the archive once the extraction has actually succeeded.
  if (( rc == 0 && remove == 1 )); then
    rm -f "$archive"
  fi

  return $rc
}

# ---------------------------------------------------------------------------
# compress
# ---------------------------------------------------------------------------

# Create an archive from a file or directory.
# Usage: compress <source> <format> [destination]
#   destination may be a directory (archive is created inside it) or a full
#   archive path. Defaults to the current directory.
compress() {
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: compress <source> <format> [destination]" >&2
    echo "Formats: tar.gz tgz tar.bz2 tar.xz tar.zst tar zip 7z gz bz2 xz zst" >&2
    return 1
  fi

  if [[ ! -e "$1" ]]; then
    echo "Source not found: $1" >&2
    return 1
  fi

  local src parent name format out outdir kind rc=0
  src=$(realpath -- "$1") || return 1
  parent=$(dirname -- "$src")
  name=$(basename -- "$src")

  # Normalise the format: accept ".tar.gz", "tar.gz" or "TAR.GZ" alike.
  format=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  format=${format#.}

  case "$format" in
    tar.gz|tgz)   kind=tar_gz ;;
    tar.bz2|tbz2) kind=tar_bz2 ;;
    tar.xz|txz)   kind=tar_xz ;;
    tar.zst|tzst) kind=tar_zst ;;
    tar)          kind=tar ;;
    zip)          kind=zip ;;
    7z)           kind=sevenzip ;;
    gz)           kind=raw_gz ;;
    bz2)          kind=raw_bz2 ;;
    xz)           kind=raw_xz ;;
    zst)          kind=raw_zst ;;
    *) echo "Unsupported format: $2" >&2; return 1 ;;
  esac

  # Single-file compressors cannot pack a directory tree.
  if [[ -d "$src" && "$kind" == raw_* ]]; then
    echo "Format '$format' cannot archive a directory; use tar.$format instead" >&2
    return 1
  fi

  # Install any missing tool before creating files on disk.
  _archive_require_kind "$kind" compress || return 1

  # Work out the output path. A destination that exists as a directory, or
  # ends in a slash, receives the archive; anything else is the archive name.
  if [[ -z "${3:-}" ]]; then
    out="$PWD/$name.$format"
  elif [[ -d "$3" || "$3" == */ ]]; then
    outdir=${3%/}
    mkdir -p "$outdir" || { echo "Cannot create destination: $outdir" >&2; return 1; }
    out="$(realpath "$outdir")/$name.$format"
  else
    outdir=$(dirname "$3")
    mkdir -p "$outdir" || { echo "Cannot create destination: $outdir" >&2; return 1; }
    out="$(realpath "$outdir")/$(basename "$3")"
  fi

  if [[ -e "$out" ]]; then
    echo "Archive already exists: $out" >&2
    return 1
  fi

  # Refuse to write the archive inside the tree being archived, which would
  # otherwise make the compressor read its own growing output.
  if [[ -d "$src" && "$out" == "$src"/* ]]; then
    echo "Destination is inside the source directory: $out" >&2
    return 1
  fi

  # Always pack from the parent directory so the archive holds a relative
  # path instead of the full absolute one.
  case "$kind" in
    tar_gz)   tar czf  "$out" -C "$parent" "$name" ;;
    tar_bz2)  tar cjf  "$out" -C "$parent" "$name" ;;
    tar_xz)   tar cJf  "$out" -C "$parent" "$name" ;;
    tar_zst)  tar --zstd -cf "$out" -C "$parent" "$name" ;;
    tar)      tar cf   "$out" -C "$parent" "$name" ;;
    zip)      ( cd "$parent" && zip -qr "$out" "$name" ) ;;
    sevenzip) ( cd "$parent" && 7z a -bso0 "$out" "$name" ) ;;
    raw_gz)   gzip  -c "$src" > "$out" ;;
    raw_bz2)  bzip2 -c "$src" > "$out" ;;
    raw_xz)   xz    -c "$src" > "$out" ;;
    raw_zst)  zstd -q -c "$src" > "$out" ;;
  esac
  rc=$?

  if (( rc != 0 )); then
    rm -f "$out"
    echo "Compression failed" >&2
    return $rc
  fi

  echo "$out"
}
