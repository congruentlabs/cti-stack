#!/usr/bin/env bash
# validate.sh - Lint and template all CTI Stack Helm charts
#
# Runs helm lint, helm dependency build, and helm template on every chart in
# charts/ using both k3s and rke2 value profiles. Reports pass/fail for each
# step and returns a non-zero exit code if any validation fails.
#
# Usage:
#   ./scripts/validate.sh [--chart NAME] [--skip-deps]
#
# Options:
#   --chart NAME   Validate only the named chart (e.g., "postgresql")
#   --skip-deps    Skip dependency build step

set -euo pipefail

###############################################################################
# Defaults
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHARTS_DIR="${REPO_ROOT}/charts"
ARGOCD_DIR="${REPO_ROOT}/argocd"
SINGLE_CHART=""
SKIP_DEPS=false

###############################################################################
# Parse arguments
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chart)
      SINGLE_CHART="$2"
      shift 2
      ;;
    --skip-deps)
      SKIP_DEPS=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--chart NAME] [--skip-deps]"
      echo ""
      echo "Validate all Helm charts in the CTI Stack repository."
      echo ""
      echo "Options:"
      echo "  --chart NAME  Validate only the named chart"
      echo "  --skip-deps   Skip helm dependency build"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

###############################################################################
# Preflight
###############################################################################
if ! command -v helm &>/dev/null; then
  echo "ERROR: helm is not installed or not in PATH." >&2
  exit 1
fi

###############################################################################
# State tracking
###############################################################################
TOTAL_PASS=0
TOTAL_FAIL=0
FAILURES=()

pass() {
  echo "  PASS: $1"
  TOTAL_PASS=$((TOTAL_PASS + 1))
}

fail() {
  echo "  FAIL: $1" >&2
  TOTAL_FAIL=$((TOTAL_FAIL + 1))
  FAILURES+=("$1")
}

###############################################################################
# Validate a single chart
###############################################################################
validate_chart() {
  local chart_dir="$1"
  local chart_name
  chart_name="$(basename "${chart_dir}")"

  echo ""
  echo "--- ${chart_name} ---"

  # 1. Dependency build
  if [[ "${SKIP_DEPS}" != "true" ]] && grep -q "^dependencies:" "${chart_dir}/Chart.yaml" 2>/dev/null; then
    echo "  Building dependencies..."
    if helm dependency build "${chart_dir}" --skip-refresh &>/dev/null; then
      pass "${chart_name}: dependency build"
    else
      fail "${chart_name}: dependency build"
      # Skip further validation if deps fail
      return
    fi
  fi

  # 2. Helm lint (base values)
  if helm lint "${chart_dir}" -f "${chart_dir}/values.yaml" &>/dev/null; then
    pass "${chart_name}: lint (base)"
  else
    fail "${chart_name}: lint (base)"
  fi

  # 3. Helm template + lint for each profile
  for profile in k3s rke2; do
    local values_args=("-f" "${chart_dir}/values.yaml")
    local profile_values="${chart_dir}/values-${profile}.yaml"
    if [[ -f "${profile_values}" ]]; then
      values_args+=("-f" "${profile_values}")
    fi

    # Lint with profile
    if helm lint "${chart_dir}" "${values_args[@]}" &>/dev/null; then
      pass "${chart_name}: lint (${profile})"
    else
      fail "${chart_name}: lint (${profile})"
    fi

    # Template with profile
    if helm template "cti-${chart_name}" "${chart_dir}" "${values_args[@]}" &>/dev/null; then
      pass "${chart_name}: template (${profile})"
    else
      fail "${chart_name}: template (${profile})"
    fi
  done
}

###############################################################################
# Validate the ArgoCD app-of-apps chart
###############################################################################
validate_argocd() {
  echo ""
  echo "--- argocd (app-of-apps) ---"

  # Lint and template with k3s values
  if helm lint "${ARGOCD_DIR}" -f "${ARGOCD_DIR}/values.yaml" -f "${ARGOCD_DIR}/values-k3s.yaml" &>/dev/null; then
    pass "argocd: lint (k3s)"
  else
    fail "argocd: lint (k3s)"
  fi

  if helm template cti-stack "${ARGOCD_DIR}" -f "${ARGOCD_DIR}/values.yaml" -f "${ARGOCD_DIR}/values-k3s.yaml" &>/dev/null; then
    pass "argocd: template (k3s)"
  else
    fail "argocd: template (k3s)"
  fi

  # Lint and template with rke2 values
  if helm lint "${ARGOCD_DIR}" -f "${ARGOCD_DIR}/values.yaml" -f "${ARGOCD_DIR}/values-rke2.yaml" &>/dev/null; then
    pass "argocd: lint (rke2)"
  else
    fail "argocd: lint (rke2)"
  fi

  if helm template cti-stack "${ARGOCD_DIR}" -f "${ARGOCD_DIR}/values.yaml" -f "${ARGOCD_DIR}/values-rke2.yaml" &>/dev/null; then
    pass "argocd: template (rke2)"
  else
    fail "argocd: template (rke2)"
  fi
}

###############################################################################
# Main
###############################################################################
echo "============================================================================"
echo "  CTI Stack Helm Chart Validation"
echo "============================================================================"

if [[ -n "${SINGLE_CHART}" ]]; then
  # Validate a single chart
  chart_path="${CHARTS_DIR}/${SINGLE_CHART}"
  if [[ ! -d "${chart_path}" ]]; then
    echo "ERROR: Chart not found: ${chart_path}" >&2
    exit 1
  fi
  validate_chart "${chart_path}"
else
  # Validate all charts
  for chart_dir in "${CHARTS_DIR}"/*/; do
    if [[ -f "${chart_dir}/Chart.yaml" ]]; then
      validate_chart "${chart_dir}"
    fi
  done

  # Validate the ArgoCD app-of-apps chart
  if [[ -f "${ARGOCD_DIR}/Chart.yaml" ]]; then
    validate_argocd
  fi
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================================================"
echo "  Validation Summary"
echo "  Passed: ${TOTAL_PASS}"
echo "  Failed: ${TOTAL_FAIL}"
echo "============================================================================"

if [[ ${TOTAL_FAIL} -gt 0 ]]; then
  echo ""
  echo "  Failures:"
  for f in "${FAILURES[@]}"; do
    echo "    - ${f}"
  done
  echo ""
  exit 1
else
  echo ""
  echo "  All validations passed."
fi
