#!/usr/bin/env bash
# generate-secrets.sh - Generate random secrets for all CHANGE_ME placeholders
# in the CTI Stack. Outputs a Helm-compatible values override file.
#
# Usage:
#   ./scripts/generate-secrets.sh [--force] [--output FILE]
#
# Options:
#   --force        Overwrite the output file if it already exists
#   --output FILE  Write to FILE instead of the default secrets-generated.yaml

set -euo pipefail

###############################################################################
# Defaults
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_FILE="${REPO_ROOT}/secrets-generated.yaml"
FORCE=false

###############################################################################
# Parse arguments
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
      shift
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--force] [--output FILE]"
      echo ""
      echo "Generate random secrets for the CTI Stack and write a Helm values"
      echo "override file that can be passed with 'helm install -f'."
      echo ""
      echo "Options:"
      echo "  --force        Overwrite output file if it already exists"
      echo "  --output FILE  Destination file (default: secrets-generated.yaml)"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

###############################################################################
# Idempotency check
###############################################################################
if [[ -f "${OUTPUT_FILE}" && "${FORCE}" != "true" ]]; then
  echo "ERROR: Output file already exists: ${OUTPUT_FILE}"
  echo "       Use --force to overwrite."
  exit 1
fi

###############################################################################
# Helper: generate a random alphanumeric string of a given length
###############################################################################
rand_alphanum() {
  local length="${1:-32}"
  if command -v openssl &>/dev/null; then
    openssl rand -base64 "$((length * 2))" 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${length}"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${length}"
  fi
}

###############################################################################
# Helper: generate a bcrypt hash (cost 12)
# Tries: python3 bcrypt → htpasswd → error
###############################################################################
bcrypt_hash() {
  local password="$1"
  if python3 -c "import bcrypt" &>/dev/null; then
    python3 -c "import bcrypt; print(bcrypt.hashpw(b'${password}', bcrypt.gensalt(rounds=12)).decode())"
  elif command -v htpasswd &>/dev/null; then
    # htpasswd -nbBC outputs ":$2y$..." — extract just the hash after the colon
    htpasswd -nbBC 12 "" "${password}" | cut -d: -f2
  else
    echo "ERROR: bcrypt hashing requires python3 with bcrypt module, or htpasswd." >&2
    echo "       Install one of: pip3 install bcrypt | apt install apache2-utils" >&2
    exit 1
  fi
}

###############################################################################
# Helper: generate a UUID-v4-like token
###############################################################################
rand_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    # Fallback: build a pseudo-UUID from random hex
    local hex
    hex="$(openssl rand -hex 16 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
    printf '%s-%s-%s-%s-%s' \
      "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
  fi
}

###############################################################################
# Generate all secrets
###############################################################################
echo "Generating secrets..."

# --- Per-app MinIO ---
AZUL_MINIO_ROOT_PASSWORD="$(rand_alphanum 32)"
OPENCTI_MINIO_ROOT_PASSWORD="$(rand_alphanum 32)"

# --- Grafana ---
GRAFANA_ADMIN_PASSWORD="$(rand_alphanum 24)"

# --- PostgreSQL database passwords ---
PG_KEYCLOAK_PASSWORD="$(rand_alphanum 32)"
PG_OPENCTI_PASSWORD="$(rand_alphanum 32)"
PG_MOBSF_PASSWORD="$(rand_alphanum 32)"

# --- RabbitMQ ---
RABBITMQ_PASSWORD="$(rand_alphanum 32)"

# --- Redis (ISM-1469: authentication) ---
REDIS_PASSWORD="$(rand_alphanum 32)"

# --- OpenCTI ---
OPENCTI_ADMIN_PASSWORD="$(rand_alphanum 24)"
OPENCTI_ADMIN_TOKEN="$(rand_uuid)"

# --- Per-app OpenSearch admin passwords ---
AZUL_OPENSEARCH_ADMIN_PASSWORD="$(rand_alphanum 32)"
OPENCTI_OPENSEARCH_ADMIN_PASSWORD="$(rand_alphanum 32)"

# --- Azul OpenSearch service users ---
OPENSEARCH_AZUL_WRITER_PASSWORD="$(rand_alphanum 32)"
OPENSEARCH_AZUL_SECURITY_PASSWORD="$(rand_alphanum 32)"

echo "  Generating bcrypt hashes for OpenSearch service users (this may take a moment)..."
# Note: admin password hash is auto-generated by the OpenSearch Operator from adminCredentialsSecret
OPENSEARCH_AZUL_WRITER_BCRYPT="$(bcrypt_hash "${OPENSEARCH_AZUL_WRITER_PASSWORD}")"
OPENSEARCH_AZUL_SECURITY_BCRYPT="$(bcrypt_hash "${OPENSEARCH_AZUL_SECURITY_PASSWORD}")"

# --- Azul JWT signing secret ---
AZUL_JWT_SIGNING_SECRET="$(rand_alphanum 64)"

# --- Azul S3 keys (MinIO access/secret for Azul bucket) ---
AZUL_S3_ACCESS_KEY="$(rand_alphanum 20)"
AZUL_S3_SECRET_KEY="$(rand_alphanum 40)"

# --- OpenCTI MinIO keys ---
OPENCTI_MINIO_ACCESS_KEY="$(rand_alphanum 20)"
OPENCTI_MINIO_SECRET_KEY="$(rand_alphanum 40)"

# --- OIDC client secrets ---
OIDC_AZUL_SECRET="$(rand_uuid)"
OIDC_OPENCTI_SECRET="$(rand_uuid)"
OIDC_MOBSF_SECRET="$(rand_uuid)"
OIDC_GRAFANA_SECRET="$(rand_uuid)"

# --- MobSF ---
MOBSF_SECRET_KEY="$(rand_alphanum 50)"

###############################################################################
# Write the values file
###############################################################################
cat > "${OUTPUT_FILE}" <<EOF
## =============================================================================
## CTI Stack - Generated Secrets
## Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
##
## IMPORTANT: This file contains sensitive credentials. Do NOT commit it to git.
## Pass it to Helm or ArgoCD as a values override:
##
##   helm upgrade --install cti-stack argocd/ \\
##     -f argocd/values.yaml \\
##     -f argocd/values-k3s.yaml \\
##     -f secrets-generated.yaml
##
## Or configure ArgoCD to reference it as a values file source.
## =============================================================================

## ---------------------------------------------------------------------------
## charts/azul-minio
## ---------------------------------------------------------------------------
azulMinio:
  rootPassword: "${AZUL_MINIO_ROOT_PASSWORD}"

## ---------------------------------------------------------------------------
## charts/opencti-minio
## ---------------------------------------------------------------------------
openctiMinio:
  rootPassword: "${OPENCTI_MINIO_ROOT_PASSWORD}"

## ---------------------------------------------------------------------------
## charts/monitoring  (Grafana admin + OIDC)
## ---------------------------------------------------------------------------
monitoring:
  grafanaAdminPassword: "${GRAFANA_ADMIN_PASSWORD}"
  grafanaOidcSecret: "${OIDC_GRAFANA_SECRET}"

## ---------------------------------------------------------------------------
## charts/postgresql  (Keycloak database password)
## ---------------------------------------------------------------------------
postgresql:
  passwords:
    keycloak: "${PG_KEYCLOAK_PASSWORD}"

## ---------------------------------------------------------------------------
## charts/rabbitmq
## ---------------------------------------------------------------------------
rabbitmq:
  password: "${RABBITMQ_PASSWORD}"

## ---------------------------------------------------------------------------
## charts/redis  (ISM-1469: Redis authentication)
## ---------------------------------------------------------------------------
redis:
  password: "${REDIS_PASSWORD}"

## ---------------------------------------------------------------------------
## charts/azul-opensearch  (admin password + bcrypt hashes for service users)
## ---------------------------------------------------------------------------
azulOpensearch:
  adminCredentials:
    password: "${AZUL_OPENSEARCH_ADMIN_PASSWORD}"
  securityConfig:
    internalUsersYml: |
      _meta:
        type: "internalusers"
        config_version: 2
      admin:
        reserved: true
        backend_roles:
          - "admin"
        description: "OpenSearch admin user"
      azul_writer:
        hash: "${OPENSEARCH_AZUL_WRITER_BCRYPT}"
        reserved: false
        backend_roles:
          - "azul_write"
        description: "Azul metastore write access"
      azul_security:
        hash: "${OPENSEARCH_AZUL_SECURITY_BCRYPT}"
        reserved: false
        backend_roles:
          - "azul_admin"
        description: "Azul security configuration access"

## ---------------------------------------------------------------------------
## charts/opencti-opensearch  (admin password only — OpenCTI connects as admin)
## ---------------------------------------------------------------------------
openctiOpensearch:
  adminCredentials:
    password: "${OPENCTI_OPENSEARCH_ADMIN_PASSWORD}"

## ---------------------------------------------------------------------------
## charts/opencti-postgresql  (bootstrap password)
## ---------------------------------------------------------------------------
openctiPostgresql:
  bootstrap:
    password: "${PG_OPENCTI_PASSWORD}"

## ---------------------------------------------------------------------------
## charts/mobsf-postgresql  (bootstrap password)
## ---------------------------------------------------------------------------
mobsfPostgresql:
  bootstrap:
    password: "${PG_MOBSF_PASSWORD}"

## ---------------------------------------------------------------------------
## charts/azul-prereqs
## ---------------------------------------------------------------------------
azulPrereqs:
  secrets:
    s3:
      accessKey: "${AZUL_S3_ACCESS_KEY}"
      secretKey: "${AZUL_S3_SECRET_KEY}"
    metastore:
      writerPassword: "${OPENSEARCH_AZUL_WRITER_PASSWORD}"
      jwtSigningSecret: "${AZUL_JWT_SIGNING_SECRET}"
      securityPassword: "${OPENSEARCH_AZUL_SECURITY_PASSWORD}"

## ---------------------------------------------------------------------------
## charts/opencti-prereqs
## ---------------------------------------------------------------------------
openctiPrereqs:
  admin:
    password: "${OPENCTI_ADMIN_PASSWORD}"
    token: "${OPENCTI_ADMIN_TOKEN}"
  rabbitmqPassword: "${RABBITMQ_PASSWORD}"
  minio:
    accessKey: "${OPENCTI_MINIO_ACCESS_KEY}"
    secretKey: "${OPENCTI_MINIO_SECRET_KEY}"
  oidcSecret: "${OIDC_OPENCTI_SECRET}"
  pgPassword: "${PG_OPENCTI_PASSWORD}"
  redisPassword: "${REDIS_PASSWORD}"

## ---------------------------------------------------------------------------
## charts/mobsf-prereqs
## ---------------------------------------------------------------------------
mobsfPrereqs:
  secretKey: "${MOBSF_SECRET_KEY}"
  oidcSecret: "${OIDC_MOBSF_SECRET}"
  pgPassword: "${PG_MOBSF_PASSWORD}"
EOF

chmod 600 "${OUTPUT_FILE}"

echo ""
echo "============================================================================"
echo "  Secrets generated successfully!"
echo "  Output: ${OUTPUT_FILE}"
echo "============================================================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. Review the generated file to ensure all values look correct."
echo ""
echo "  2. For k3s deployments, pass the file to ArgoCD or Helm:"
echo ""
echo "     helm upgrade --install cti-stack argocd/ \\"
echo "       -f argocd/values.yaml \\"
echo "       -f argocd/values-k3s.yaml \\"
echo "       -f ${OUTPUT_FILE}"
echo ""
echo "  3. For RKE2 deployments:"
echo ""
echo "     helm upgrade --install cti-stack argocd/ \\"
echo "       -f argocd/values.yaml \\"
echo "       -f argocd/values-rke2.yaml \\"
echo "       -f ${OUTPUT_FILE}"
echo ""
echo "  4. IMPORTANT: Do NOT commit this file to version control."
echo "     Add 'secrets-generated.yaml' to your .gitignore."
echo ""
echo "  5. Extract the CA certificate and inject it into azul-prereqs:"
echo ""
echo "     kubectl get secret cti-ca-tls -n cti-infra -o jsonpath='{.data.ca\\.crt}' | base64 -d > ca.crt"
echo "     # Then set azulPrereqs.caCert in your values override to the contents of ca.crt"
echo ""
echo "  6. For production environments, consider using Sealed Secrets,"
echo "     External Secrets Operator, or HashiCorp Vault instead."
echo "============================================================================"
