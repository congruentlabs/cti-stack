#!/usr/bin/env bash
# airgap-push.sh - Load and push airgap images to a Docker registry
#
# Loads image tarballs from the airgap bundle and pushes them to a private
# Docker registry in the offline environment.
#
# Requires: docker
#
# Usage:
#   ./scripts/airgap-push.sh REGISTRY_HOST:PORT

set -euo pipefail

###############################################################################
# Setup
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_DIR="${REPO_ROOT}/airgap-bundle"
IMAGES_DIR="${BUNDLE_DIR}/images"

# Colours
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
# Parse arguments
###############################################################################
if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  echo "Usage: $0 REGISTRY_HOST:PORT"
  echo ""
  echo "Load airgap image tarballs and push them to a private Docker registry."
  echo ""
  echo "Arguments:"
  echo "  REGISTRY_HOST:PORT   The registry to push to (e.g., registry.local:5000)"
  echo ""
  echo "The script reads images from: airgap-bundle/images/"
  echo "Each .tar is loaded into Docker, retagged for the target registry, and pushed."
  exit 0
fi

REGISTRY="$1"

###############################################################################
# Preflight
###############################################################################
if ! command -v docker &>/dev/null; then
  fail "docker is not installed or not in PATH."
  exit 1
fi

if ! docker info &>/dev/null; then
  fail "Docker daemon is not running."
  exit 1
fi

if [[ ! -d "${IMAGES_DIR}" ]]; then
  fail "Images directory not found: ${IMAGES_DIR}"
  echo "  Run ./scripts/airgap-bundle.sh first on an internet-connected machine." >&2
  exit 1
fi

TARBALL_COUNT="$(find "${IMAGES_DIR}" -name '*.tar' -type f | wc -l)"
if [[ "${TARBALL_COUNT}" -eq 0 ]]; then
  fail "No .tar files found in ${IMAGES_DIR}"
  exit 1
fi

info "Registry:  ${REGISTRY}"
info "Source:    ${IMAGES_DIR}"
info "Tarballs:  ${TARBALL_COUNT}"
echo ""

###############################################################################
# Load, retag, and push each image
###############################################################################
CURRENT=0
PUSHED=0
FAILED=0

for tarball in "${IMAGES_DIR}"/*.tar; do
  [[ ! -f "${tarball}" ]] && continue
  CURRENT=$((CURRENT + 1))

  basename_tar="$(basename "${tarball}" .tar)"

  echo -ne "  [${CURRENT}/${TARBALL_COUNT}] Loading ${basename_tar}... "

  # Load the tarball — docker load prints "Loaded image: <ref>" or "Loaded image ID: sha256:..."
  load_output="$(docker load -i "${tarball}" 2>&1)"
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}LOAD FAILED${NC}"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Extract the loaded image reference(s)
  loaded_images="$(echo "${load_output}" | grep -oP 'Loaded image: \K.+' || true)"

  if [[ -z "${loaded_images}" ]]; then
    # Fallback: extract image ID for images without a tag
    loaded_id="$(echo "${load_output}" | grep -oP 'Loaded image ID: \K.+' || true)"
    if [[ -n "${loaded_id}" ]]; then
      warn "Image loaded as ID only (${loaded_id}), cannot retag automatically"
      FAILED=$((FAILED + 1))
      continue
    fi
    echo -e "${RED}UNKNOWN OUTPUT${NC}"
    FAILED=$((FAILED + 1))
    continue
  fi

  echo -e "${GREEN}OK${NC}"

  # Retag and push each loaded image
  while IFS= read -r original_ref; do
    [[ -z "${original_ref}" ]] && continue

    # Strip the original registry prefix and retag for the target registry
    # e.g., quay.io/keycloak/keycloak:26.0 -> registry.local:5000/keycloak/keycloak:26.0
    # e.g., redis:7.4 -> registry.local:5000/library/redis:7.4
    local_ref="${original_ref}"

    # Remove known registry prefixes
    local_ref="${local_ref#docker.io/}"
    local_ref="${local_ref#quay.io/}"
    local_ref="${local_ref#ghcr.io/}"
    local_ref="${local_ref#registry.k8s.io/}"

    # If no slash (bare image like redis:7.4), prefix with library/
    if [[ "${local_ref}" != *"/"* ]]; then
      local_ref="library/${local_ref}"
    fi

    target_ref="${REGISTRY}/${local_ref}"

    echo -ne "         Pushing ${target_ref}... "

    if docker tag "${original_ref}" "${target_ref}" 2>/dev/null \
       && docker push "${target_ref}" &>/dev/null; then
      echo -e "${GREEN}OK${NC}"
      PUSHED=$((PUSHED + 1))
    else
      echo -e "${RED}FAILED${NC}"
      FAILED=$((FAILED + 1))
    fi

    # Clean up local tags to save disk
    docker rmi "${target_ref}" &>/dev/null || true
    docker rmi "${original_ref}" &>/dev/null || true

  done <<< "${loaded_images}"
done

###############################################################################
# Report
###############################################################################
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "  Push complete"
printf  "  %-12s %s\n" "Pushed:" "${PUSHED} images"
if [[ ${FAILED} -gt 0 ]]; then
printf  "  %-12s ${RED}%s${NC}\n" "Failed:" "${FAILED}"
fi
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

if [[ ${FAILED} -gt 0 ]]; then
  warn "Some images failed. Check Docker login and registry connectivity."
  exit 1
fi

echo "Next steps:"
echo ""
echo "  Configure k3s to mirror from your registry:"
echo "    See docs/airgap.md for /etc/rancher/k3s/registries.yaml"
echo ""
echo "  Deploy the stack:"
echo "    helm upgrade --install cti-stack airgap-bundle/charts/cti-stack-0.1.0.tgz \\"
echo "      -f argocd/values.yaml \\"
echo "      -f argocd/values-k3s.yaml \\"
echo "      -f secrets-generated.yaml"
