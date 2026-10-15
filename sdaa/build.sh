#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDAA_DIR="$ROOT/OpenDDE/sdaa"
cd "$ROOT"
mkdir -p "$ROOT/data" "$ROOT/work" "$ROOT/tmp" "$ROOT/vendor"

ENV_FILE="${OPENDDE_ENV_FILE:-$ROOT/.env.sdaa}"
if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -n "${OPENDDE_ENV_FILE:-}" ]]; then
        echo "Specified environment file does not exist: $ENV_FILE" >&2
        exit 1
    fi
    cp "$SDAA_DIR/build/.env.sdaa.example" "$ENV_FILE"
    sed -i "s/^HOST_UID=.*/HOST_UID=$(id -u)/" "$ENV_FILE"
    sed -i "s/^HOST_GID=.*/HOST_GID=$(id -g)/" "$ENV_FILE"
    echo "Created $ENV_FILE with the pinned base image ID and current host UID/GID."
fi
set -a
# This file contains only non-secret build pins.
source "${ENV_FILE}"
set +a
OPENDDE_CONTAINER="${OPENDDE_CONTAINER:-opendde-sdaa}"

if docker container inspect "${OPENDDE_CONTAINER}" >/dev/null 2>&1; then
    echo "Container ${OPENDDE_CONTAINER} already exists; inspect it before reusing this script." >&2
    exit 1
fi

if [[ ! -f "$ROOT/.dockerignore" ]]; then
    cp "$SDAA_DIR/build/dockerignore" "$ROOT/.dockerignore"
fi
missing_rules=()
while IFS= read -r rule; do
    if [[ -z "$rule" || "$rule" == \#* ]]; then
        continue
    fi
    if ! grep -Fxq -- "$rule" "$ROOT/.dockerignore"; then
        missing_rules+=("$rule")
    fi
done < "$SDAA_DIR/build/dockerignore"
if (( ${#missing_rules[@]} > 0 )); then
    mkdir -p "$ROOT/backups"
    ignore_backup="$ROOT/backups/dockerignore-before-sdaa-$(date +%Y%m%d-%H%M%S)"
    cp -p "$ROOT/.dockerignore" "$ignore_backup"
    printf '\n%s\n' "${missing_rules[@]}" >> "$ROOT/.dockerignore"
    echo "Added missing Docker ignore rules; previous file: $ignore_backup"
fi

actual_image_id="$(docker image inspect "${BASE_IMAGE}" --format '{{.Id}}')"
if [[ "${actual_image_id}" != "${BASE_IMAGE_ID}" ]]; then
    echo "Base image ID mismatch: expected ${BASE_IMAGE_ID}, found ${actual_image_id}" >&2
    exit 1
fi
if [[ "$(id -u)" != "${HOST_UID}" || "$(id -g)" != "${HOST_GID}" ]]; then
    echo "Host UID/GID mismatch: pinned ${HOST_UID}:${HOST_GID}, current $(id -u):$(id -g)" >&2
    exit 1
fi
KALIGN_BIN="$ROOT/vendor/kalign-3.6.0/bin/kalign"
EXPECTED_KALIGN_SHA="$(sed -n 's/^kalign_binary_sha256=//p' "$SDAA_DIR/build/source.sdaa.lock")"
if [[ ! -e "$KALIGN_BIN" ]]; then
    "$SDAA_DIR/scripts/build-kalign.sh"
fi
if [[ ! -x "$KALIGN_BIN" ]]; then
    echo "Kalign artifact is not executable: $KALIGN_BIN" >&2
    exit 1
fi
actual_kalign_sha="$(sha256sum "$KALIGN_BIN" | awk '{print $1}')"
if [[ "$actual_kalign_sha" != "$EXPECTED_KALIGN_SHA" ]]; then
    echo "Kalign checksum mismatch: expected $EXPECTED_KALIGN_SHA, found $actual_kalign_sha" >&2
    exit 1
fi
KALIGN_COMMIT="$(sed -n 's/^kalign_source_commit=//p' "$SDAA_DIR/build/source.sdaa.lock")"

docker build \
    --file OpenDDE/sdaa/build/Dockerfile.sdaa \
    --tag "${OPENDDE_IMAGE}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "BASE_IMAGE_ID=${BASE_IMAGE_ID}" \
    --build-arg "HOST_UID=${HOST_UID}" \
    --build-arg "HOST_GID=${HOST_GID}" \
    --build-arg "OPENDDE_COMMIT=${OPENDDE_COMMIT}" \
    --build-arg "KALIGN_COMMIT=$KALIGN_COMMIT" \
    .

run_args=(
    --detach
    --name "${OPENDDE_CONTAINER}"
    --restart unless-stopped
    --init
    --shm-size 8g
    --user "${HOST_UID}:${HOST_GID}"
    --workdir /workspace/repro/OpenDDE
    --env HOME=/home/opendde
    --env VIRTUAL_ENV=/opt/venvs/opendde-sdaa
    --env PATH=/opt/venvs/opendde-sdaa/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    --env PYTHONPATH=/workspace/repro/OpenDDE
    --env PYTHONUNBUFFERED=1
    --env PYTHONDONTWRITEBYTECODE=1
    --env OPENDDE_ROOT_DIR=/opendde_data
    --env LAYERNORM_TYPE=torch
    --volume "${ROOT}/OpenDDE:/workspace/repro/OpenDDE:ro"
    --volume "${ROOT}/data:/opendde_data:ro"
    --volume "${ROOT}/work:/workspace/repro/work:rw"
    --volume "${ROOT}/tmp:/tmp:rw"
)
for card in {0..7}; do
    if [[ ! -e "/dev/tcaicard${card}" ]]; then
        echo "Missing host device /dev/tcaicard${card}" >&2
        exit 1
    fi
    run_args+=(--device "/dev/tcaicard${card}:/dev/tcaicard${card}")
done

docker run "${run_args[@]}" "${OPENDDE_IMAGE}" sleep infinity
docker inspect "${OPENDDE_CONTAINER}" \
    --format 'status={{.State.Status}} image={{.Image}} user={{.Config.User}} devices={{len .HostConfig.Devices}}'
