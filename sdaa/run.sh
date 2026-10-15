#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="${1:-official}"
OPENDDE_CONTAINER="${OPENDDE_CONTAINER:-opendde-sdaa}"
ACCEPTANCE_NAME="${OPENDDE_ACCEPTANCE_NAME:-acceptance}_$(date +%Y%m%d-%H%M%S)_$$"
OPENDDE_INFERENCE_STEPS="${OPENDDE_INFERENCE_STEPS:-10}"
OPENDDE_INFERENCE_CYCLES="${OPENDDE_INFERENCE_CYCLES:-1}"
WORK_ROOT="${ROOT}/work/sdaa/${ACCEPTANCE_NAME}"
cd "${ROOT}"
mkdir -p "${WORK_ROOT}/logs"

if [[ "$(docker inspect --format '{{.State.Status}}' "${OPENDDE_CONTAINER}" 2>/dev/null || true)" != "running" ]]; then
    echo "SDAA container is not running; run OpenDDE/sdaa/build.sh first." >&2
    exit 1
fi

if [[ "$STAGE" == "doctor" ]]; then
    docker exec -i "${OPENDDE_CONTAINER}" python /workspace/repro/OpenDDE/sdaa/scripts/container/verify_sdaa_environment.py 2>&1 | tee "$WORK_ROOT/logs/doctor-run.log"
    exit
fi

if [[ "$STAGE" == "official" ]]; then
    run_name="official_7r6r_$(date +%Y%m%d-%H%M%S)_$$"
    run_dir="$WORK_ROOT/$run_name"
    mkdir "$run_dir"
    python3 - "$ROOT/OpenDDE/examples/example.json" "$run_dir/input_7r6r.json" <<'PY_JSON'
import json
import sys
from pathlib import Path

jobs = json.loads(Path(sys.argv[1]).read_text())
selected = [job for job in jobs if job["name"] == "7r6r"]
if len(selected) != 1:
    raise SystemExit("Expected exactly one official 7r6r task")
Path(sys.argv[2]).write_text(json.dumps(selected, indent=2) + "\n")
PY_JSON
    container_run_dir="/workspace/repro/work/sdaa/${ACCEPTANCE_NAME}/${run_name}"
    set +e
    docker exec -i \
        --env "RUN_DIR=$container_run_dir" \
        --env "INFERENCE_STEPS=$OPENDDE_INFERENCE_STEPS" \
        --env "INFERENCE_CYCLES=$OPENDDE_INFERENCE_CYCLES" \
        "$OPENDDE_CONTAINER" bash -lc '
            cd /workspace/repro/OpenDDE &&
            test -s examples/7r6r/msa/1/pairing.a3m &&
            test -s examples/7r6r/msa/1/non_pairing.a3m &&
            opendde pred -i "$RUN_DIR/input_7r6r.json" -o "$RUN_DIR/result" \
                -s 101 -n opendde_v1 --device sdaa \
                --use_msa true --use_template false --use_rna_msa false \
                --trimul_kernel torch --triatt_kernel torch --enable_tf32 false \
                --sample 1 --step "$INFERENCE_STEPS" --cycle "$INFERENCE_CYCLES" --dtype bf16
        ' 2>&1 | tee "$run_dir/run.log"
    run_status="${PIPESTATUS[0]}"
    set -e
    if [[ "$run_status" -ne 0 ]]; then
        echo "Official 7r6r inference failed; see $run_dir/run.log" >&2
        exit "$run_status"
    fi
    if ! find "$run_dir/result" -type f -name '*.cif' -print -quit | grep -q .; then
        echo "Official 7r6r inference produced no CIF; see $run_dir/run.log" >&2
        exit 1
    fi
    echo "Official 7r6r result: $run_dir/result"
    exit 0
fi

case "${STAGE}" in
    core|prepared|templates|template_smoke|json|runner|runner_full|search)
        stages=("${STAGE}")
        ;;
    all)
        stages=(core prepared json runner)
        ;;
    *)
        echo "Usage: $0 [official|doctor|core|prepared|templates|template_smoke|json|runner|runner_full|search|all]" >&2
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
        bash /workspace/repro/OpenDDE/sdaa/scripts/container/acceptance.sh "${stage}" \
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
