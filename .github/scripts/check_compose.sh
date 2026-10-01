#!/usr/bin/env bash
# Merge every compose overlay set the labs use, then assert what the merge must contain.
# Run from anywhere inside the repository:  ./.github/scripts/check_compose.sh
#
# Why: check_syntax.sh only proves each YAML file parses. An overlay that parses can still
# merge into a stack that starts and silently lacks the feature -- a service name that no
# longer matches the base, or an env var on langfuse-web when the worker is the one that
# reads it. `docker compose config` resolves the merge without pulling or starting anything.
#
# Needs: docker compose, python3. Needs no secret and no running stack.
#
# Input is pinned so a local run and a CI run see the same thing:
#   * --env-file /dev/null  -> compose does not read a developer's _base/.env
#   * the variables the compose files reference are unset in this script's environment,
#     so a value exported in the developer's shell does not leak in either
#   * LANGFUSE_EE_LICENSE_KEY=ci-dummy satisfies the `:?` guard in docker-compose.ee.yml
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

# ── Overlay sets the labs actually use (one place to keep in step with _base/lib/env.sh) ──
#   base                    labs 01-04 (01-up.sh) and every langfuse-eval script
#   ee                      labs 05-07, 09, 11  (05-ee-activate.sh starts it; EE=1 _base/bin/up.sh)
#   ee masking              lab 08  (08-ee-data-masking.sh)
#   ee governance           lab 10  (10-ee-instance-governance.sh)
#   ee masking governance   lab 99 cleanup  (99-cleanup.sh -> _base/bin/down.sh tears down all of them)
SETS=(
    "base"
    "ee"
    "ee masking"
    "ee governance"
    "ee masking governance"
)

# Reset the compose input to a known state.
for v in COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES \
         $(grep -ohE '\$\{[A-Za-z_][A-Za-z_0-9]*' _base/docker-compose*.yml | tr -d '${' | sort -u); do
    unset "$v"
done
export LANGFUSE_EE_LICENSE_KEY=ci-dummy

# What a merged config must contain. Read from stdin (`config --format json`); argv[1] is
# the space-separated overlay set ("base" = no overlay). Python 3.9-compatible on purpose.
read -r -d '' ASSERT_PY <<'PYEOF' || true
import json
import os
import sys

overlays = sys.argv[1].split()
cfg = json.load(sys.stdin)
services = cfg.get("services") or {}
fails = 0


def check(ok, label, detail=""):
    global fails
    if ok:
        print("    PASS  %s" % label)
    else:
        fails += 1
        print("    FAIL  %s%s" % (label, " -- " + detail if detail else ""))


def env_of(service):
    return (services.get(service) or {}).get("environment") or {}


def has_env(service, names):
    """One check per service: every name must be in that service's merged environment."""
    missing = [n for n in names if n not in env_of(service)]
    check(not missing, "%s environment has %s" % (service, ", ".join(names)),
          "missing on %s: %s" % (service, ", ".join(missing)))


# ── base (always) ────────────────────────────────────────────────────────────
# The six services of _base/README.md. The expected set is exact, so a typo'd overlay
# service name that happens to carry an image still shows up as an extra service.
expected = ["langfuse-web", "langfuse-worker", "postgres", "clickhouse", "redis", "minio"]
if "masking" in overlays:
    expected.append("masking")  # lab 08 adds the sidecar
check(sorted(services) == sorted(expected), "services are exactly: " + " ".join(sorted(expected)),
      "got: " + " ".join(sorted(services)))
# All lab SQL docs say `docker exec ... langfuse-hols-clickhouse-1`; that name comes from here.
check(cfg.get("name") == "langfuse-hols", "project name is langfuse-hols", "got: %r" % cfg.get("name"))

# ── ee (labs 05-07, 09, 11; required by masking and governance too) ──────────
if "ee" in overlays:
    for svc in ("langfuse-web", "langfuse-worker"):
        # lab 05: both containers need the key; web alone leaves the worker's EE jobs off.
        has_env(svc, ["LANGFUSE_EE_LICENSE_KEY"])
    # lab 06: Instance Management API (/api/admin/*) authenticates with this key. Web only.
    has_env("langfuse-web", ["ADMIN_API_KEY"])

# ── masking (lab 08) ─────────────────────────────────────────────────────────
if "masking" in overlays:
    # lab 08: the WORKER calls the sidecar during ingestion; langfuse-web never reads these.
    has_env("langfuse-worker", [
        "LANGFUSE_INGESTION_MASKING_CALLBACK_URL",
        "LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS",
        "LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED",
    ])
    depends = (services.get("langfuse-worker") or {}).get("depends_on") or {}
    cond = depends.get("masking", {}).get("condition") if isinstance(depends, dict) else None
    check(cond == "service_healthy", "langfuse-worker depends_on masking: service_healthy",
          "got: %r" % cond)
    mounts = (services.get("masking") or {}).get("volumes") or []
    sources = [m.get("source", "") for m in mounts if m.get("type") == "bind"]
    wanted = [s for s in sources if s.replace(os.sep, "/").endswith("_base/masking/masking_service.py")]
    check(bool(wanted), "masking bind-mounts _base/masking/masking_service.py",
          "bind sources: %s" % (sources or "none"))
    check(bool(wanted) and all(os.path.isfile(s) for s in wanted),
          "the mounted masking_service.py exists", "not a file: %s" % wanted)

# ── governance (lab 10) ──────────────────────────────────────────────────────
if "governance" in overlays:
    # lab 10: UI customization (A) and the org-creators allowlist (B), both read by langfuse-web.
    has_env("langfuse-web", [
        "LANGFUSE_UI_LOGO_LIGHT_MODE_HREF",
        "LANGFUSE_UI_LOGO_DARK_MODE_HREF",
        "LANGFUSE_UI_FEEDBACK_HREF",
        "LANGFUSE_UI_DOCUMENTATION_HREF",
        "LANGFUSE_UI_SUPPORT_HREF",
        "LANGFUSE_ALLOWED_ORGANIZATION_CREATORS",
    ])

sys.exit(1 if fails else 0)
PYEOF

failed=0
echo "docker compose: $(docker compose version --short 2>&1)"

for set in "${SETS[@]}"; do
    files=(-f _base/docker-compose.yml)
    for o in $set; do
        [ "$o" = base ] || files+=(-f "_base/docker-compose.$o.yml")
    done
    echo "--- $set"

    if ! out=$(docker compose "${files[@]}" --env-file /dev/null config -q 2>&1); then
        echo "    FAIL  docker compose config -q (${files[*]})"
        printf '%s\n' "$out" | sed 's/^/          /'
        failed=1
        continue
    fi
    echo "    PASS  docker compose config -q"

    if ! json=$(docker compose "${files[@]}" --env-file /dev/null config --format json 2>&1); then
        echo "    FAIL  docker compose config --format json"
        printf '%s\n' "$json" | sed 's/^/          /'
        failed=1
        continue
    fi
    printf '%s' "$json" | python3 -c "$ASSERT_PY" "$set" || failed=1
done

echo
if [ "$failed" -eq 0 ]; then
    echo "OK: every overlay set merges and contains what the labs need"
else
    echo "FAIL: see FAIL lines above"
fi
exit "$failed"
