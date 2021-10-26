#!/usr/bin/env bash
set -e

PACKAGES="${1}"
ARCH="${2:-$(uname -m)}"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(readlink -f "${0}")")
CONFIG="${ROOT}/config.json"

declare -A DEPS=(
  [jq]=jq
  [docker]=docker
)


# ----


SELF=$(basename "$(readlink -f "${0}")")
log() {
  echo "[${SELF}] $@"
}
err() {
  log >&2 "$@"
  exit 1
}


for dep in "${!DEPS[@]}"; do
  command -v "${dep}" 2>&1 >/dev/null || err "Missing dependency: ${DEPS["${dep}"]}"
done

config=$(cat "${CONFIG}")

jq -e ".builds[\"${ARCH}\"]" >/dev/null <<< "${config}" \
 || err "Unsupported arch"

docker_image=$(jq -r ".builds[\"${ARCH}\"].image" <<< "${config}")
abi=$(jq -r ".builds[\"${ARCH}\"].abi" <<< "${config}")


# ----


get_docker_image() {
  log "Getting docker image"
  [[ -n "$(docker image ls -q "${docker_image}")" ]] \
    || docker image pull "${docker_image}"
}


get_deps() {
  log "Finding dependencies (${ARCH} / ${abi}) for ${PACKAGES}"
  local script=$(cat <<EOF
shopt -s nullglob

cd "\$(mktemp -d)"
PYTHON="/opt/python/${abi}/bin/python"

(
  "\${PYTHON}" -m pip download --disable-pip-version-check ${PACKAGES}
  "\${PYTHON}" -m pip install --disable-pip-version-check --no-deps --no-compile * >/dev/null
  echo
) 1>&2

packages=\$("\${PYTHON}" -m pip list \
  --disable-pip-version-check \
  --format columns \
  --exclude build \
  --exclude packaging \
  --exclude pep517 \
  --exclude pip \
  --exclude pyparsing \
  --exclude setuptools \
  --exclude tomli \
  --exclude wheel \
  | tail -n+3
)

while read -r name version; do
  hash=\$("\${PYTHON}" -m pip hash \
    "\${name}-\${version}"*.tar{,.gz} \
    "\${name//-/_}-\${version}-"*.whl \
    | tail -n1
  )
  echo "\${name}==\${version} \${hash}"
done <<< "\${packages}"
EOF
  )

  docker run \
    --interactive \
    --rm \
    "${docker_image}" \
    /usr/bin/bash <<< "${script}" \
    | jq -CRn '[(inputs | split("\n")) | .[] | split("==") | {key: .[0], value: .[1]}] | from_entries'
}


get_docker_image
get_deps
