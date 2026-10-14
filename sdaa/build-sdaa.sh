#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
if [[ ! -f "$ROOT/.dockerignore" ]]; then
    echo "Missing $ROOT/.dockerignore; copy OpenDDE/sdaa/dockerignore first." >&2
    exit 1
fi
ENV_FILE="${OPENDDE_ENV_FILE:-${ROOT}/.env.sdaa}"
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing ${ENV_FILE}; copy OpenDDE/sdaa/.env.sdaa.example and set the fixed image ID and host UID/GID." >&2
    exit 1
fi
set -a
# This file contains only non-secret build pins.
source "${ENV_FILE}"
set +a
OPENDDE_CONTAINER="${OPENDDE_CONTAINER:-opendde-sdaa}"

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
EXPECTED_KALIGN_SHA="$(sed -n 's/^kalign_binary_sha256=//p' "$ROOT/OpenDDE/sdaa/source.sdaa.lock")"
actual_kalign_sha="$(sha256sum "$KALIGN_BIN" | awk '{print $1}')"
if [[ ! -x "$KALIGN_BIN" || "$actual_kalign_sha" != "$EXPECTED_KALIGN_SHA" ]]; then
    echo "Kalign artifact missing or checksum mismatch: expected $EXPECTED_KALIGN_SHA, found $actual_kalign_sha" >&2
    exit 1
fi
KALIGN_COMMIT="$(sed -n 's/^kalign_source_commit=//p' "$ROOT/OpenDDE/sdaa/source.sdaa.lock")"
if docker container inspect "${OPENDDE_CONTAINER}" >/dev/null 2>&1; then
    echo "Container ${OPENDDE_CONTAINER} already exists; inspect it before reusing this script." >&2
    exit 1
fi

docker build \
    --file OpenDDE/sdaa/Dockerfile.sdaa \
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
