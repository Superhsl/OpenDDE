#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="${1:-all}"
OPENDDE_CONTAINER="${OPENDDE_CONTAINER:-opendde-sdaa}"
ACCEPTANCE_NAME="${OPENDDE_ACCEPTANCE_NAME:-acceptance}"
OPENDDE_INFERENCE_STEPS="${OPENDDE_INFERENCE_STEPS:-10}"
OPENDDE_INFERENCE_CYCLES="${OPENDDE_INFERENCE_CYCLES:-1}"
WORK_ROOT="${ROOT}/work/sdaa/${ACCEPTANCE_NAME}"
cd "${ROOT}"
mkdir -p "${WORK_ROOT}/logs"

if [[ "$(docker inspect --format '{{.State.Status}}' "${OPENDDE_CONTAINER}" 2>/dev/null || true)" != "running" ]]; then
    echo "SDAA container is not running; run OpenDDE/sdaa/build-sdaa.sh first." >&2
    exit 1
fi

if [[ "$STAGE" == "doctor" ]]; then
    docker exec -i "${OPENDDE_CONTAINER}" python /workspace/repro/OpenDDE/sdaa/container/verify_sdaa_environment.py 2>&1 | tee "$WORK_ROOT/logs/doctor-run.log"
    exit
fi

case "${STAGE}" in
    core|prepared|templates|template_smoke|json|runner|runner_full|search)
        stages=("${STAGE}")
        ;;
    all)
        stages=(core prepared json runner)
        ;;
    *)
        echo "Usage: $0 [doctor|core|prepared|templates|template_smoke|json|runner|runner_full|search|all]" >&2
        exit 2
        ;;
esac

status=0
for stage in "${stages[@]}"; do
    stage_log="${WORK_ROOT}/logs/${stage}-run.log"
    set +e
    docker exec -i \
        --env WORK_ROOT=/workspace/repro/work/sdaa/${ACCEPTANCE_NAME} \
        --env OPENDDE_INFERENCE_STEPS="${OPENDDE_INFERENCE_STEPS}" \
        --env OPENDDE_INFERENCE_CYCLES="${OPENDDE_INFERENCE_CYCLES}" \
        "${OPENDDE_CONTAINER}" \
        bash /workspace/repro/OpenDDE/sdaa/container/acceptance.sh "${stage}" \
        2>&1 | tee "${stage_log}"
    stage_status="${PIPESTATUS[0]}"
    set -e
    if [[ "${stage_status}" -ne 0 ]]; then
        status="${stage_status}"
        echo "Acceptance stage ${stage} failed; see ${stage_log}" >&2
        break
    fi
    echo "Acceptance stage ${stage} passed: ${stage_log}"
done

wrong_owner="$(find "${WORK_ROOT}" \( ! -user "$(id -u)" -o ! -group "$(id -g)" \) -print -quit)"
if [[ -n "${wrong_owner}" ]]; then
    echo "Output owner check failed for ${wrong_owner}; expected $(id -u):$(id -g)" >&2
    exit 1
fi
echo "Acceptance output ownership verified: $(id -u):$(id -g)"
exit "${status}"
