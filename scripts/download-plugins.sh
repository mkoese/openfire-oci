#!/usr/bin/env sh
set -eu

PLUGIN_LIST_FILE="${1:-plugins.txt}"
PLUGIN_DIR="${2:-plugins}"

mkdir -p "${PLUGIN_DIR}"

while IFS='|' read -r name url || [ -n "${name}${url}" ]; do
  # Remove CR from Windows CRLF line endings.
  name="$(printf '%s' "${name}" | tr -d '\r')"
  url="$(printf '%s' "${url}" | tr -d '\r')"
  # Skip empty and comment lines.
  [ -z "${name}" ] && continue
  case "${name}" in
    \#*) continue ;;
  esac
  echo "Downloading plugin: ${name} from ${url}"
  curl -fsSL -o "${PLUGIN_DIR}/${name}.jar" "${url}"
done < "${PLUGIN_LIST_FILE}"
