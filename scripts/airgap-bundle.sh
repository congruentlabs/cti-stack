#!/usr/bin/env bash
# airgap-bundle.sh - Prepare a complete airgap transfer bundle
#
# Pulls all container images (via docker) and packages all Helm charts into a
# single output directory ready for offline transfer. No parameters required.
#
# Requires: docker, helm
#
# Output: airgap-bundle/ directory containing:
#   - images/*.tar        (one per container image)
#   - charts/*.tgz        (one per Helm chart)
#   - images.txt          (image manifest)
#   - checksums.sha256    (integrity verification)

set -euo pipefail

###############################################################################
# Setup
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHARTS_DIR="${REPO_ROOT}/charts"
ARGOCD_DIR="${REPO_ROOT}/argocd"
BUNDLE_DIR="${REPO_ROOT}/airgap-bundle"
IMAGES_DIR="${BUNDLE_DIR}/images"
CHARTS_OUT="${BUNDLE_DIR}/charts"

# Counters
IMAGES_PULLED=0
IMAGES_SKIPPED=0
IMAGES_FAILED=0
CHARTS_PACKAGED=0

# Colours (if terminal supports it)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; }

###############################################################################
# Preflight checks
###############################################################################
info "Checking prerequisites..."

for cmd in docker helm; do
  if ! command -v "${cmd}" &>/dev/null; then
    fail "${cmd} is not installed or not in PATH."
    exit 1
  fi
done

# Verify docker daemon is running
if ! docker info &>/dev/null; then
  fail "Docker daemon is not running."
  exit 1
fi

ok "docker and helm are available"

###############################################################################
# Create output directories
###############################################################################
mkdir -p "${IMAGES_DIR}" "${CHARTS_OUT}"
info "Bundle directory: ${BUNDLE_DIR}"

###############################################################################
# Phase 1: Build Helm dependencies
###############################################################################
echo ""
echo -e "${BOLD}=== Phase 1: Building Helm chart dependencies ===${NC}"
echo ""

for chart_dir in "${CHARTS_DIR}"/*/; do
  [[ ! -f "${chart_dir}/Chart.yaml" ]] && continue
  chart_name="$(basename "${chart_dir}")"

  if grep -q "^dependencies:" "${chart_dir}/Chart.yaml" 2>/dev/null; then
    info "Building deps: ${chart_name}"
    if helm dependency build "${chart_dir}" --skip-refresh &>/dev/null; then
      ok "${chart_name}"
    else
      # Try with repo add/update
      warn "${chart_name} — retrying with repo update..."
      helm dependency update "${chart_dir}" 2>/dev/null || {
        fail "${chart_name}: could not build dependencies"
      }
    fi
  fi
done

###############################################################################
# Phase 2: Extract image list from all charts
###############################################################################
echo ""
echo -e "${BOLD}=== Phase 2: Extracting container image list ===${NC}"
echo ""

TMPFILE="$(mktemp)"
trap 'rm -f "${TMPFILE}"' EXIT

# Template each chart with both profiles
for chart_dir in "${CHARTS_DIR}"/*/; do
  [[ ! -f "${chart_dir}/Chart.yaml" ]] && continue
  chart_name="$(basename "${chart_dir}")"

  for profile in k3s rke2; do
    values_args=("-f" "${chart_dir}/values.yaml")
    profile_values="${chart_dir}/values-${profile}.yaml"
    [[ -f "${profile_values}" ]] && values_args+=("-f" "${profile_values}")

    helm template "cti-${chart_name}" "${chart_dir}" "${values_args[@]}" 2>/dev/null \
      | grep -E '^\s*-?\s*image:\s' \
      | sed -E 's/^\s*-?\s*image:\s*["'"'"']?//; s/["'"'"']?\s*$//' \
      >> "${TMPFILE}" || true
  done
done

# Add well-known images that helm template may not emit
# (operator-managed workloads, init containers, etc.)
cat >> "${TMPFILE}" <<'KNOWN_IMAGES'
quay.io/keycloak/keycloak:26.0
ghcr.io/cloudnative-pg/postgresql:16.4
redis:7.4
rabbitmq:3.13-management
opensecurity/mobile-security-framework-mobsf:v4.1.3
quay.io/jetstack/cert-manager-controller:v1.17.1
quay.io/jetstack/cert-manager-webhook:v1.17.1
quay.io/jetstack/cert-manager-cainjector:v1.17.1
quay.io/jetstack/cert-manager-startupapicheck:v1.17.1
registry.k8s.io/ingress-nginx/controller:v1.12.0
registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.0
quay.io/strimzi/operator:0.44.0
quay.io/strimzi/kafka:0.44.0-kafka-3.8.0
docker.io/minio/minio:RELEASE.2024-11-07T00-52-20Z
docker.io/minio/mc:RELEASE.2024-11-21T17-21-54Z
KNOWN_IMAGES

# Deduplicate and clean
sort -u "${TMPFILE}" \
  | grep -v '^\s*$' \
  | grep -v '^\s*#' \
  | sed 's/^[[:space:]]*//' \
  > "${BUNDLE_DIR}/images.txt"

IMAGE_COUNT="$(wc -l < "${BUNDLE_DIR}/images.txt")"
ok "Found ${IMAGE_COUNT} unique container images"

###############################################################################
# Phase 3: Pull and save images
###############################################################################
echo ""
echo -e "${BOLD}=== Phase 3: Pulling container images (docker) ===${NC}"
echo ""

# Sanitize image ref to a safe filename
image_to_filename() {
  echo "$1" | sed 's|/|__|g; s|:|_|g; s|@|_|g'
}

CURRENT=0
while IFS= read -r image || [[ -n "${image}" ]]; do
  image="$(echo "${image}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "${image}" ]] && continue

  CURRENT=$((CURRENT + 1))
  filename="$(image_to_filename "${image}")"
  tarball="${IMAGES_DIR}/${filename}.tar"

  # Skip if already pulled
  if [[ -f "${tarball}" ]]; then
    IMAGES_SKIPPED=$((IMAGES_SKIPPED + 1))
    echo -e "  [${CURRENT}/${IMAGE_COUNT}] ${YELLOW}SKIP${NC} (exists) ${image}"
    continue
  fi

  echo -ne "  [${CURRENT}/${IMAGE_COUNT}] PULL ${image}... "

  if docker pull "${image}" &>/dev/null && docker save "${image}" -o "${tarball}" 2>/dev/null; then
    IMAGES_PULLED=$((IMAGES_PULLED + 1))
    echo -e "${GREEN}OK${NC}"
  else
    IMAGES_FAILED=$((IMAGES_FAILED + 1))
    echo -e "${RED}FAILED${NC}"
    rm -f "${tarball}"
  fi
done < "${BUNDLE_DIR}/images.txt"

###############################################################################
# Phase 4: Package Helm charts
###############################################################################
echo ""
echo -e "${BOLD}=== Phase 4: Packaging Helm charts ===${NC}"
echo ""

for chart_dir in "${CHARTS_DIR}"/*/; do
  [[ ! -f "${chart_dir}/Chart.yaml" ]] && continue
  chart_name="$(basename "${chart_dir}")"

  if helm package "${chart_dir}" -d "${CHARTS_OUT}" &>/dev/null; then
    CHARTS_PACKAGED=$((CHARTS_PACKAGED + 1))
    ok "${chart_name}"
  else
    fail "${chart_name}: packaging failed"
  fi
done

# Also package the ArgoCD app-of-apps chart
if [[ -f "${ARGOCD_DIR}/Chart.yaml" ]]; then
  if helm package "${ARGOCD_DIR}" -d "${CHARTS_OUT}" &>/dev/null; then
    CHARTS_PACKAGED=$((CHARTS_PACKAGED + 1))
    ok "argocd (app-of-apps)"
  else
    fail "argocd: packaging failed"
  fi
fi

###############################################################################
# Phase 5: Generate checksums
###############################################################################
echo ""
echo -e "${BOLD}=== Phase 5: Generating checksums ===${NC}"
echo ""

(
  cd "${BUNDLE_DIR}"
  find images/ charts/ -type f \( -name '*.tar' -o -name '*.tgz' \) | sort \
    | xargs sha256sum > checksums.sha256
)
ok "checksums.sha256 written"

###############################################################################
# Report
###############################################################################
# Calculate sizes
IMAGES_SIZE="$(du -sh "${IMAGES_DIR}" 2>/dev/null | cut -f1)"
CHARTS_SIZE="$(du -sh "${CHARTS_OUT}" 2>/dev/null | cut -f1)"
TOTAL_SIZE="$(du -sh "${BUNDLE_DIR}" 2>/dev/null | cut -f1)"
IMAGE_TAR_COUNT="$(find "${IMAGES_DIR}" -name '*.tar' -type f | wc -l)"
CHART_TGZ_COUNT="$(find "${CHARTS_OUT}" -name '*.tgz' -type f | wc -l)"

echo ""
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                        AIRGAP BUNDLE REPORT                             ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║ Bundle directory: ${NC}${BUNDLE_DIR}"
echo -e "${BOLD}║ Total size:      ${NC}${TOTAL_SIZE}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║ CONTAINER IMAGES                                                        ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
printf  "║  %-12s %s\n" "Pulled:" "${IMAGES_PULLED}"
printf  "║  %-12s %s\n" "Skipped:" "${IMAGES_SKIPPED} (already in bundle)"
if [[ ${IMAGES_FAILED} -gt 0 ]]; then
printf  "║  %-12s ${RED}%s${NC}\n" "Failed:" "${IMAGES_FAILED}"
fi
printf  "║  %-12s %s\n" "Tarballs:" "${IMAGE_TAR_COUNT} files (${IMAGES_SIZE})"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║ HELM CHARTS                                                             ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
printf  "║  %-12s %s\n" "Packaged:" "${CHARTS_PACKAGED} charts (${CHARTS_SIZE})"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║ FILES TO TRANSFER                                                       ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"

echo "║"
echo "║  images/"
for f in "${IMAGES_DIR}"/*.tar; do
  [[ ! -f "$f" ]] && continue
  sz="$(du -h "$f" | cut -f1)"
  printf "║    %-60s %8s\n" "$(basename "$f")" "${sz}"
done
echo "║"
echo "║  charts/"
for f in "${CHARTS_OUT}"/*.tgz; do
  [[ ! -f "$f" ]] && continue
  sz="$(du -h "$f" | cut -f1)"
  printf "║    %-60s %8s\n" "$(basename "$f")" "${sz}"
done
echo "║"
printf "║  %-60s\n" "images.txt"
printf "║  %-60s\n" "checksums.sha256"

echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║ NEXT STEPS                                                              ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
echo "║"
echo "║  1. Transfer the bundle to the airgapped environment:"
echo "║"
echo "║     tar czf airgap-bundle.tar.gz -C \"$(dirname "${BUNDLE_DIR}")\" airgap-bundle"
echo "║     # copy airgap-bundle.tar.gz via USB / approved media"
echo "║"
echo "║  2. On the airgapped host, push images to your Docker registry:"
echo "║"
echo "║     ./scripts/airgap-push.sh <REGISTRY_HOST:PORT>"
echo "║"
echo "║  3. Deploy via ArgoCD (see docs/airgap.md)"
echo "║"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${NC}"

if [[ ${IMAGES_FAILED} -gt 0 ]]; then
  echo ""
  warn "${IMAGES_FAILED} image(s) failed to pull. Re-run this script to retry (it skips already-pulled images)."
  exit 1
fi
