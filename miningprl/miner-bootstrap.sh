#!/usr/bin/env bash
set -Eeuo pipefail

: "${PRL_WALLET:?PRL_WALLET wajib diisi}"
: "${PRL_WORKER_NAME:?PRL_WORKER_NAME wajib diisi}"
: "${PRL_EXPECTED_GPU:?PRL_EXPECTED_GPU wajib diisi}"
: "${PRL_BENCHMARK_THS:?PRL_BENCHMARK_THS wajib diisi}"
: "${PRL_AGENT_URL:?PRL_AGENT_URL wajib diisi}"
: "${PRL_AGENT_TOKEN:?PRL_AGENT_TOKEN wajib diisi}"

GPU=0
DIR="${PRL_MINER_DIR:-/root/prl-pearlhash}"
WILDRIG_VERSION="${WILDRIG_VERSION:-0.51.3}"
WILDRIG_FILE="wildrig-multi-linux-${WILDRIG_VERSION}.tar.gz"
WILDRIG_URL="https://github.com/andru-kun/wildrig-multi/releases/download/${WILDRIG_VERSION}/${WILDRIG_FILE}"
WILDRIG_SHA256="${WILDRIG_SHA256:-85db1069b807d78b2a766dcceb8b92c0745ac4e1315a400d6ebdcc1832b25e27}"
POOL_URL="${PRL_POOL_URL:-stratum+tcp://pool.pearlhash.xyz:9000}"
ACCOUNT_URL="https://pearlhash.xyz/api/account/${PRL_WALLET}"
STARTED_AT="$(date +%s)"

post_status() {
    local stage="$1" hashrate="${2:-}" message="${3:-}"
    python3 - "$stage" "$hashrate" "$message" <<'PY' || true
import json, os, sys, urllib.request
stage, hashrate, message = sys.argv[1:4]
payload = {
    "group": os.environ.get("SALAD_CONTAINER_GROUP_NAME", ""),
    "instance_id": os.environ.get("SALAD_INSTANCE_ID", ""),
    "machine_id": os.environ.get("SALAD_MACHINE_ID", ""),
    "worker": os.environ["PRL_WORKER_NAME"],
    "gpu_name": os.environ.get("PRL_ACTUAL_GPU", ""),
    "stage": stage,
    "message": message,
}
if hashrate:
    payload["hashrate_ths"] = float(hashrate)
body = json.dumps(payload).encode()
request = urllib.request.Request(
    os.environ["PRL_AGENT_URL"], data=body, method="POST",
    headers={
        "Authorization": "Bearer " + os.environ["PRL_AGENT_TOKEN"],
        "Content-Type": "application/json",
        "User-Agent": "salad-prl-miner-agent/1.0",
    },
)
with urllib.request.urlopen(request, timeout=15) as response:
    response.read()
PY
}

mkdir -p "$DIR"
export LD_LIBRARY_PATH="/usr/local/nvidia/lib64:/usr/local/nvidia/lib:/usr/lib/x86_64-linux-gnu:/usr/lib64:${LD_LIBRARY_PATH:-}"

post_status "gpu_wait" "" "Menunggu GPU/NVML siap"
GPU_NAME=""
for attempt in $(seq 1 60); do
    GPU_NAME="$(nvidia-smi -i "$GPU" --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs || true)"
    [ -n "$GPU_NAME" ] && break
    sleep 2
done
[ -n "$GPU_NAME" ] || { post_status "bootstrap_failed" "" "GPU/NVML tidak siap setelah 120 detik"; exit 1; }
export PRL_ACTUAL_GPU="$GPU_NAME"
post_status "gpu_detected" "" "GPU terdeteksi"

gpu_compatible() {
    local expected="${1,,}" actual="${2,,}"
    [[ "$actual" == "$expected" ]] && return 0
    case "$expected" in
        *"rtx 2060") [[ "$actual" == *"rtx 2060 super" ]] && return 0 ;;
        *"rtx 2070") [[ "$actual" == *"rtx 2070 super" ]] && return 0 ;;
        *"rtx 2080") [[ "$actual" == *"rtx 2080 super" ]] && return 0 ;;
    esac
    return 1
}

if ! gpu_compatible "$PRL_EXPECTED_GPU" "$GPU_NAME"; then
    # Keep reporting until the control plane has observed this fresh Salad
    # instance. A one-shot heartbeat can arrive before the Salad poller and be
    # (correctly) rejected as stale, which would otherwise leave a paid but
    # non-mining instance alive forever.
    while true; do
        post_status "gpu_mismatch" "" "Expected ${PRL_EXPECTED_GPU}; actual ${GPU_NAME}"
        sleep 30
    done
fi

NEED_APT=0
command -v curl >/dev/null 2>&1 || NEED_APT=1
if ! ldconfig -p 2>/dev/null | grep -q 'libOpenCL.so.1'; then NEED_APT=1; fi
if [ "$NEED_APT" -eq 1 ]; then
    for attempt in 1 2 3; do
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
            curl ca-certificates ocl-icd-libopencl1 ocl-icd-opencl-dev clinfo && break
        [ "$attempt" -eq 3 ] && exit 1
        sleep 5
    done
    ldconfig
fi

cd "$DIR"
BIN="$(find "$DIR" -type f \( -name wildrig-multi -o -name wildrig \) 2>/dev/null | head -n1 || true)"
if [ -z "$BIN" ]; then
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 \
        -o "$WILDRIG_FILE" "$WILDRIG_URL"
    printf '%s  %s\n' "$WILDRIG_SHA256" "$WILDRIG_FILE" | sha256sum -c - || {
        post_status "bootstrap_failed" "" "Checksum WildRig ${WILDRIG_VERSION} tidak cocok"
        exit 1
    }
    tar -xzf "$WILDRIG_FILE"
    BIN="$(find "$DIR" -type f \( -name wildrig-multi -o -name wildrig \) 2>/dev/null | head -n1 || true)"
fi
[ -n "$BIN" ] || { post_status "bootstrap_failed" "" "WildRig tidak ditemukan"; exit 1; }
chmod +x "$BIN"

case "$GPU_NAME" in
    *"RTX 2080 SUPER"*) TARGET_POWER=200; TARGET_CORE=1710; TARGET_MEM=8000 ;;
    *"RTX 2080"*)       TARGET_POWER=220; TARGET_CORE=1605; TARGET_MEM=6800 ;;
    *"RTX 2070"*)       TARGET_POWER=225; TARGET_CORE=1785; TARGET_MEM=6850 ;;
    *"RTX 2060"*)       TARGET_POWER=175; TARGET_CORE=1500; TARGET_MEM="" ;;
    *"RTX 3060 Ti"*)    TARGET_POWER=200; TARGET_CORE=1635; TARGET_MEM=6800 ;;
    *) post_status "bootstrap_failed" "" "GPU belum mempunyai tuning profile"; exit 1 ;;
esac

MAX_POWER="$(nvidia-smi -i "$GPU" --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | xargs || true)"
if [[ "$MAX_POWER" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk "BEGIN{exit !($MAX_POWER < $TARGET_POWER)}"; then
    TARGET_POWER="$(printf '%.0f' "$MAX_POWER")"
fi

nvidia-smi -i "$GPU" -pm 1 >/dev/null 2>&1 || true
POWER_OK=0; CORE_OK=0; MEM_OK=0
nvidia-smi -i "$GPU" -pl "$TARGET_POWER" >/dev/null 2>&1 && POWER_OK=1 || true
nvidia-smi -i "$GPU" -lgc "${TARGET_CORE},${TARGET_CORE}" >/dev/null 2>&1 && CORE_OK=1 || true
if [ -n "$TARGET_MEM" ]; then
    nvidia-smi -i "$GPU" -lmc "${TARGET_MEM},${TARGET_MEM}" >/dev/null 2>&1 && MEM_OK=1 || true
else
    MEM_OK=1
fi

ARGS=(
    --algo pearlhash --url "$POOL_URL"
    --user "${PRL_WALLET}.${PRL_WORKER_NAME}" --pass x
    --gpu-list 0 --gpu-temp-limit 82 --gpu-temp-resume 70
    --print-time 15 --watchdog
)
HELP_TEXT="$("$BIN" --help 2>&1 || true)"
if [ "$POWER_OK" -eq 0 ] && grep -q -- '--gpu-powerlimit' <<<"$HELP_TEXT"; then ARGS+=(--gpu-powerlimit "$TARGET_POWER"); fi
if [ "$CORE_OK" -eq 0 ] && grep -q -- '--gpu-core-clock' <<<"$HELP_TEXT"; then ARGS+=(--gpu-core-clock "$TARGET_CORE"); fi
if [ "$MEM_OK" -eq 0 ] && [ -n "$TARGET_MEM" ] && grep -q -- '--gpu-memory-clock' <<<"$HELP_TEXT"; then ARGS+=(--gpu-memory-clock "$TARGET_MEM"); fi

post_status "miner_starting" "" "WildRig ${WILDRIG_VERSION} dimulai"

python3 - <<'PY' &
import json, os, statistics, time, urllib.request

agent_url = os.environ["PRL_AGENT_URL"]
token = os.environ["PRL_AGENT_TOKEN"]
wallet = os.environ["PRL_WALLET"]
worker_name = os.environ["PRL_WORKER_NAME"]
expected_gpu = os.environ["PRL_EXPECTED_GPU"]
actual_gpu = os.environ.get("PRL_ACTUAL_GPU", "")
benchmark = float(os.environ["PRL_BENCHMARK_THS"])
ratio = float(os.environ.get("PRL_MIN_HASH_RATIO", "0.90"))
warmup = int(os.environ.get("PRL_VALIDATION_WARMUP_SECONDS", "420"))
timeout = int(os.environ.get("PRL_POOL_TIMEOUT_SECONDS", "600"))
started = time.monotonic()
samples = []

def gpu_compatible(expected, actual):
    expected = expected.strip().lower()
    actual = actual.strip().lower()
    if actual == expected:
        return True
    upgrades = {
        "rtx 2060": "rtx 2060 super",
        "rtx 2070": "rtx 2070 super",
        "rtx 2080": "rtx 2080 super",
    }
    for base, upgrade in upgrades.items():
        if expected.endswith(base) and actual.endswith(upgrade):
            return True
    return False

def post(stage, hashrate=None, message=""):
    payload = {
        "group": os.environ.get("SALAD_CONTAINER_GROUP_NAME", ""),
        "instance_id": os.environ.get("SALAD_INSTANCE_ID", ""),
        "machine_id": os.environ.get("SALAD_MACHINE_ID", ""),
        "worker": worker_name,
        "gpu_name": actual_gpu,
        "stage": stage,
        "message": message,
    }
    if hashrate is not None:
        payload["hashrate_ths"] = hashrate
    request = urllib.request.Request(
        agent_url, data=json.dumps(payload).encode(), method="POST",
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json", "User-Agent": "salad-prl-miner-agent/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            response.read()
    except Exception:
        pass

while True:
    elapsed = time.monotonic() - started
    found = None
    try:
        request = urllib.request.Request(
            "https://pearlhash.xyz/api/account/" + wallet,
            headers={"Accept": "application/json", "User-Agent": "salad-prl-miner-agent/1.0"},
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            account = json.load(response)
        found = next((w for w in account.get("connected_workers", []) if w.get("worker_name") == worker_name), None)
    except Exception:
        found = None
    if found:
        gpu_info = found.get("gpu_info") or []
        pool_gpu = str(gpu_info[0].get("name") or "") if gpu_info else ""
        hashrate = sum(float(g.get("hashrate") or 0) for g in gpu_info) / 1e12
        if pool_gpu and not gpu_compatible(expected_gpu, pool_gpu):
            post("gpu_mismatch", hashrate, f"Pool GPU {pool_gpu}; expected {expected_gpu}")
        elif elapsed >= warmup:
            samples.append(hashrate)
            samples = samples[-5:]
            median = statistics.median(samples)
            if len(samples) >= 5:
                if median >= benchmark * ratio:
                    post("healthy", median, f"Median 5 sampel; benchmark {benchmark:.3f} TH/s")
                else:
                    post("validation_failed", median, f"Median di bawah {ratio:.0%} benchmark {benchmark:.3f} TH/s")
            else:
                post("benchmarking", median, f"Sampel {len(samples)}/5")
        else:
            post("warming_up", hashrate, f"Warm-up {int(elapsed)}/{warmup} detik")
    elif elapsed >= timeout:
        post("validation_failed", 0.0, f"Worker tidak terlihat di pool setelah {timeout} detik")
    else:
        post("pool_connecting", None, f"Menunggu worker pool {int(elapsed)}/{timeout} detik")
    time.sleep(30)
PY

exec "$BIN" "${ARGS[@]}"

