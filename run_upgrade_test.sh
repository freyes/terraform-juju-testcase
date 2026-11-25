#!/usr/bin/env bash
#
# terraform-provider-juju upgrade test case: 1.3.1 -> 2.3.1
#
# Exercises the documented upgrade procedure
# (https://canonical.com/juju/docs/terraform-provider-juju/latest/howto/manage-provider/upgrade-provider-to-v2/):
#
#   1. baseline-init         terraform init     (provider 1.3.1)   expected: PASS
#   2. baseline-validate     terraform validate (provider 1.3.1)   expected: PASS
#   3. upgrade-init          pin -> 2.3.1, init -upgrade           expected: PASS
#   4. upgrade-validate       terraform validate (provider 2.3.1)   CLASSIFY failure
#   5. upgrade-plan           plan -refresh=false over fixture state
#                            as written by provider 1.3.1            CLASSIFY failure
#   6. upgrade-plan-legacy    plan over pre-v1.x fixture state
#                            (schema_version 0)                      CLASSIFY failure
#   7. e2e-*                  against the ambient Juju environment:
#                            real apply @1.3.1 (model + the charmhub
#                            "ubuntu" application), init -upgrade to
#                            2.3.1, plan @2.3.1 over the real
#                            1.3.1-written state, then destroy.
#
# A working Juju environment is assumed: a bootstrapped controller the
# local juju CLI is logged in to. The provider discovers connection
# details from the CLI (live discovery); no JUJU_* variables are used.
#
# Expectation under test: the upgrade FAILS with a provider-schema error
# ("fail to upgrade due to schema"). Failures in the upgrade phases are
# classified as SCHEMA / CONNECT / OTHER.
#
# Verdict:
#   exit 0  CONFIRMED    - an upgrade step failed with a schema-classified error
#   exit 2  REFUTED      - every upgrade step succeeded; no schema failure exists
#   exit 1  INCONCLUSIVE- harness or environment problem prevented a full run
#                          (registry unreachable, fixture invalid, Juju
#                          environment not working); see results/
#
# Environment:
#   TF_BIN          terraform binary           (default: terraform)
#   FROM_VERSION    starting provider version   (default: 1.3.1)
#   TO_VERSION      upgrade target version     (default: 2.3.1)
#   E2E_MODEL_NAME  model name for the e2e phase
#                   (default: tf-provider-upgrade-e2e-<timestamp>)
#   KEEP_WORKSPACE  1 = keep the temp workspace for debugging
#   RESULTS_DIR     where logs are written       (default: <case>/results)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FROM_VERSION="${FROM_VERSION:-1.3.1}"
TO_VERSION="${TO_VERSION:-2.3.1}"
TF_BIN="${TF_BIN:-terraform}"
RESULTS_DIR="${RESULTS_DIR:-$HERE/results}"
KEEP_WORKSPACE="${KEEP_WORKSPACE:-0}"
E2E_MODEL_NAME="${E2E_MODEL_NAME:-tf-provider-upgrade-e2e-$(date +%s)}"

log()  { printf '\n==> %s\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

command -v "$TF_BIN" >/dev/null 2>&1 || die "terraform ($TF_BIN) not found on PATH. Install terraform or set TF_BIN."
TF_BIN="$(command -v "$TF_BIN")"
info "terraform: $("$TF_BIN" version | head -n1)"

mkdir -p "$RESULTS_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tf-juju-upgrade.XXXXXX")"

E2E_CLEANUP_NEEDED=0
e2e_cleanup() {
  if [[ "$E2E_CLEANUP_NEEDED" == "1" && -f "$WORK/terraform.tfstate" ]]; then
    log "e2e cleanup: destroying the applied resources"
    ( cd "$WORK" && "$TF_BIN" destroy -auto-approve -input=false -no-color \
        -var "model_name=$E2E_MODEL_NAME" ) >"$RESULTS_DIR/e2e-cleanup.log" 2>&1 \
      || info "e2e cleanup failed - clean up model '$E2E_MODEL_NAME' manually with juju"
    E2E_CLEANUP_NEEDED=0
  fi
}
cleanup() {
  e2e_cleanup
  if [[ "$KEEP_WORKSPACE" == "1" ]]; then
    printf '\n(debug) workspace kept at %s\n' "$WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# Provider-schema error patterns terraform emits when a configuration or a
# state file is incompatible with the active provider schema.
classify() { # $1 = log file, $2 = exit code -> prints PASS|SCHEMA|CONNECT|OTHER
  local logf="$1" rc="$2"
  # 0 = clean, 2 = plan succeeded with changes pending (-detailed-exitcode)
  if [[ "$rc" -eq 0 || "$rc" -eq 2 ]]; then
    echo PASS
    return
  fi
  if grep -Eqi \
    'unsupported argument|unsupported attribute|unsupported block|invalid resource type|not expected here|invalid attribute|invalid or unknown key|missing required argument|schema version|state schema|unsupported schema|inconsistent|duplicate|unable to upgrade resource|upgradestate\(\)|version [0-9]+ upgrade' \
    "$logf"; then
    echo SCHEMA
  elif grep -Eqi \
    'connection|controller_addresses|websocket|facade|unauthorized|authentication|connection refused|timeout|timed out|login|no controller|unable to connect' \
    "$logf"; then
    echo CONNECT
  else
    echo OTHER
  fi
}

PHASE_CLASS=""; PHASE_RC=""; PHASE_TABLE=""
VERDICTS=()
SCHEMA_FAILURE_OBSERVED=0
INCONCLUSIVE=0

# Runs a terraform command in the workspace, logs output, classifies the
# outcome, and appends to the phase table.
run_phase() { # <name> <expectation> <args...>
  local name="$1" expectation="$2"; shift 2
  local logf="$RESULTS_DIR/$name.log"
  info "terraform $*"
  ( cd "$WORK" && "$TF_BIN" "$@" ) >"$logf" 2>&1
  PHASE_RC=$?
  PHASE_CLASS="$(classify "$logf" "$PHASE_RC")"
  PHASE_TABLE+="$(printf '%-20s %-12s rc=%-3s %s' "$name" "$expectation" "$PHASE_RC" "$PHASE_CLASS")"$'\n'
}

set_pin() { # $1 = version - rewrites the workspace pin
  sed -i "s/version = \"[0-9][^\"]*\"/version = \"$1\"/" "$WORK/versions.tf"
  grep 'version' "$WORK/versions.tf" | sed 's/^/    /' >&2
}

note() { # $1 = verdict line
  VERDICTS+=("$1")
}

skip_rest() { # $1 = reason - mark the run inconclusive
  INCONCLUSIVE=1
  note "$1"
}

# ----------------------------------------------------------- phases 1-2: old --

log "Phases 1-2: baseline init + validate (provider $FROM_VERSION)"
cp "$HERE/versions.tf" "$HERE/main.tf" "$HERE/provider.tf" "$WORK/"
run_phase baseline-init PASS init -backend=false -input=false -no-color
if [[ "$PHASE_CLASS" != "PASS" ]]; then
  skip_rest "baseline-init: $PHASE_CLASS (expected PASS - is registry.terraform.io reachable? see results/baseline-init.log)"
else
  run_phase baseline-validate PASS validate -no-color
  [[ "$PHASE_CLASS" == "PASS" ]] || skip_rest "baseline-validate: $PHASE_CLASS (expected PASS - fixture config invalid under $FROM_VERSION? see results/baseline-validate.log)"
fi

# ------------------------------------------------------- phases 3-6: upgrade --

if [[ "$INCONCLUSIVE" -eq 0 ]]; then
  log "Phase 3: upgrade init ($FROM_VERSION -> $TO_VERSION)"
  set_pin "$TO_VERSION"
  run_phase upgrade-init PASS init -backend=false -upgrade -input=false -no-color
  if [[ "$PHASE_CLASS" == "PASS" ]]; then
    info "lock file provider block:"
    sed -n '/provider "registry.terraform.io\/juju\/juju"/,/^}/p' "$WORK/.terraform.lock.hcl" | sed 's/^/    /' >&2
  else
    skip_rest "upgrade-init: $PHASE_CLASS (expected PASS - the provider swap must download; see results/upgrade-init.log)"
  fi
fi

if [[ "$INCONCLUSIVE" -eq 0 ]]; then
  log "Phase 4: upgrade validate (provider $TO_VERSION)"
  run_phase upgrade-validate SCHEMA? validate -no-color
  case "$PHASE_CLASS" in
    SCHEMA) SCHEMA_FAILURE_OBSERVED=1
            note "upgrade-validate: SCHEMA failure - 1.3.1 configuration is invalid under $TO_VERSION (matches expectation)" ;;
    PASS)   note "upgrade-validate: PASS - 1.3.1 configuration is schema-valid under $TO_VERSION" ;;
    *)      skip_rest "upgrade-validate: $PHASE_CLASS (rc=$PHASE_RC)" ;;
  esac
fi

# Two state shapes travel through the plan phases:
#
#  state-v$FROM_VERSION/terraform.tfstate  - state as actually written by
#    provider 1.3.1 (schema_version 1 on juju_application, 0 on juju_model,
#    matching each resource's Version in the 1.3.1 source).
#    Expected: passthrough upgrade, plans cleanly under 2.3.1.
#
#  state-legacy-v0/terraform.tfstate      - pre-v1.x state (schema_version 0
#    on the same resources, v0-era attribute shape derived from the
#    appV0Schema PriorSchema in the 1.3.1 source). 1.3.1 shipped
#    UpgradeState() upgraders for this; 2.3.1 removed them.
#    Expected: "Unable to Upgrade Resource State" - the schema-caused
#    upgrade failure this test case exists to demonstrate.
#
# Both plans run -refresh=false: fixture state carries synthetic model
# UUIDs that must not be read from any controller.

if [[ "$INCONCLUSIVE" -eq 0 ]]; then
  log "Phase 5: plan over fixture state (provider $TO_VERSION)"
  cp "$HERE/fixtures/state-v$FROM_VERSION/terraform.tfstate" "$WORK/terraform.tfstate"
  run_phase upgrade-plan SCHEMA? plan -refresh=false -input=false -lock=false -no-color -detailed-exitcode
  case "$PHASE_CLASS" in
    SCHEMA) SCHEMA_FAILURE_OBSERVED=1
            note "upgrade-plan: SCHEMA failure loading/planning 1.3.1-written state under $TO_VERSION (matches expectation)" ;;
    PASS)   note "upgrade-plan: PASS - 1.3.1-written state plans cleanly under $TO_VERSION (rc=$PHASE_RC)" ;;
    *)      skip_rest "upgrade-plan: $PHASE_CLASS (rc=$PHASE_RC)" ;;
  esac

  cp "$HERE/fixtures/state-legacy-v0/terraform.tfstate" "$WORK/terraform.tfstate"
  run_phase upgrade-plan-legacy SCHEMA? plan -refresh=false -input=false -lock=false -no-color -detailed-exitcode
  case "$PHASE_CLASS" in
    SCHEMA) SCHEMA_FAILURE_OBSERVED=1
            note "upgrade-plan-legacy: SCHEMA failure - $TO_VERSION dropped the UpgradeState() upgraders $FROM_VERSION shipped (matches expectation)" ;;
    PASS)   note "upgrade-plan-legacy: PASS - legacy v0 state plans under $TO_VERSION (upgraders not needed)" ;;
    *)      skip_rest "upgrade-plan-legacy: $PHASE_CLASS (rc=$PHASE_RC)" ;;
  esac
fi

# ---------------------------------------------------------- phase 7: e2e real --

if [[ "$INCONCLUSIVE" -eq 0 ]]; then
  log "Phase 7: e2e - real apply @$FROM_VERSION, plan @$TO_VERSION, destroy (ambient Juju environment)"

  rm -f "$WORK/terraform.tfstate" "$WORK/.terraform.lock.hcl"
  set_pin "$FROM_VERSION"
  run_phase e2e-init PASS init -backend=false -input=false -no-color
  if [[ "$PHASE_CLASS" == "PASS" ]]; then
    run_phase e2e-apply PASS@old apply -auto-approve -input=false -no-color -var "model_name=$E2E_MODEL_NAME"
  else
    skip_rest "e2e-init: $PHASE_CLASS (expected PASS - see results/e2e-init.log)"
  fi

  if [[ "$INCONCLUSIVE" -eq 0 && "$PHASE_CLASS" == "PASS" ]]; then
    E2E_CLEANUP_NEEDED=1

    set_pin "$TO_VERSION"
    run_phase e2e-upgrade-init PASS init -backend=false -upgrade -input=false -no-color
    if [[ "$PHASE_CLASS" == "PASS" ]]; then
      run_phase e2e-upgrade-plan SCHEMA? plan -input=false -lock=false -no-color -detailed-exitcode -var "model_name=$E2E_MODEL_NAME"
      case "$PHASE_CLASS" in
        SCHEMA) SCHEMA_FAILURE_OBSERVED=1
                note "e2e-upgrade-plan: SCHEMA failure - real 1.3.1-written state fails under $TO_VERSION (matches expectation)" ;;
        PASS)   note "e2e-upgrade-plan: PASS - real 1.3.1-written state plans under $TO_VERSION (rc=$PHASE_RC)" ;;
        *)      skip_rest "e2e-upgrade-plan: $PHASE_CLASS (rc=$PHASE_RC)" ;;
      esac
    else
      skip_rest "e2e-upgrade-init: $PHASE_CLASS (expected PASS - see results/e2e-upgrade-init.log)"
    fi
  elif [[ "$INCONCLUSIVE" -eq 0 ]]; then
    skip_rest "e2e-apply: $PHASE_CLASS - could not build baseline state on the ambient controller (is the Juju environment working? see results/e2e-apply.log)"
  fi

  if [[ "$E2E_CLEANUP_NEEDED" == "1" ]]; then
    run_phase e2e-destroy PASS destroy -auto-approve -input=false -no-color -var "model_name=$E2E_MODEL_NAME"
    if [[ "$PHASE_CLASS" == "PASS" ]]; then
      E2E_CLEANUP_NEEDED=0
      note "e2e-destroy: PASS - applied resources cleaned up"
    else
      note "e2e-destroy: $PHASE_CLASS - model '$E2E_MODEL_NAME' needs manual cleanup (see results/e2e-destroy.log)"
    fi
  fi
fi

# ---------------------------------------------------------------- verdict ------

log "Phase summary"
printf '%s' "$PHASE_TABLE" | sed 's/^/  /' >&2
log "Verdict"
for v in "${VERDICTS[@]}"; do printf '  * %s\n' "$v" >&2; done

if [[ "$SCHEMA_FAILURE_OBSERVED" -eq 1 ]]; then
  printf '\nVERDICT: CONFIRMED - upgrade %s -> %s fails due to schema.\n' "$FROM_VERSION" "$TO_VERSION" >&2
  printf 'Logs in %s\n' "$RESULTS_DIR" >&2
  exit 0
fi

if [[ "$INCONCLUSIVE" -eq 1 ]]; then
  printf '\nVERDICT: INCONCLUSIVE - harness or environment problem prevented a full run.\n' >&2
  printf 'Inspect %s and the verdict lines above.\n' "$RESULTS_DIR" >&2
  exit 1
fi

printf '\nVERDICT: REFUTED - no schema-caused upgrade failure %s -> %s.\n' "$FROM_VERSION" "$TO_VERSION" >&2
printf 'Every upgrade step (provider swap, validate, plan over 1.3.1-written\n' >&2
printf 'state, real e2e apply/plan/destroy) ran without a schema error.\n' >&2
printf 'Logs in %s\n' "$RESULTS_DIR" >&2
exit 2