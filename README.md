# CTI Stack

WIP: Don't try deploying this until this message is deleted! It's not fully tested yet.

A GitOps-managed deployment of cyber threat intelligence and malware analysis tools, orchestrated by ArgoCD. Deploys [Azul](https://github.com/AustralianCyberSecurityCentre/azul-app) (ACSC), [OpenCTI](https://github.com/OpenCTI-Platform/opencti), and [MobSF](https://github.com/MobSF/Mobile-Security-Framework-MobSF) on Kubernetes with shared infrastructure, SSO, TLS, and monitoring.

For malware detonation we also run this in airgapped environments, so running the stack in an offline network is also supported.

## ISM/IRAP Compliance

As we're in Australia this stack is hardened against the Australian Government Information Security Manual (ISM) at the **PROTECTED** classification level. These controls will likely overlap with many other govt control frameworks, but if you want specifc hardening rules applied just ask.

| Control Area | Implementation |
|-------------|---------------|
| Pod Security (ISM-1249) | Pod Security Standards enforced on all namespaces (`restricted`/`baseline`) |
| Network Segmentation (ISM-1181) | Default-deny NetworkPolicies with per-service allow-lists |
| Encryption in Transit (ISM-1781) | Internal TLS on all data services — no plaintext listeners |
| TLS Policy (ISM-1139) | TLS 1.2/1.3 with ISM-approved cipher suites (ECDHE + AES-GCM) |
| Security Headers (ISM-1369) | HSTS, CSP, X-Content-Type-Options, X-Frame-Options, Referrer-Policy |
| Classification Banner (ISM-0408) | PROTECTED banner on all web interfaces |
| Least Privilege (ISM-1469) | Dedicated ServiceAccounts, minimal RBAC, non-root containers |
| Audit Logging (ISM-0580) | Kubernetes API audit logging with Promtail shipping to Loki |
| Image Integrity (ISM-1443) | All images pinned to SHA256 digests |
| Secrets Encryption (ISM-1405) | etcd encryption at rest via k3s/RKE2 secrets-encryption |

See [docs/ism-compliance.md](docs/ism-compliance.md) for the full control mapping.

## Quick Start

### k3s (Single Node)

We use nginx instead of traefik, just to maintain consistency in config between single node and larger deployments.

```bash
# 1. Install k3s
curl -sfL https://get.k3s.io | sh -s - --disable=traefik

# 2. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Generate secrets
./scripts/generate-secrets.sh

# 4. Deploy the stack
helm upgrade --install cti-stack argocd/ \
  --namespace argocd \
  -f argocd/values.yaml \
  -f argocd/values-k3s.yaml \
  -f secrets-generated.yaml
```

See [docs/setup-k3s.md](docs/setup-k3s.md) for the full guide.

### RKE2 (Multi-Node)

See [docs/setup-rke2.md](docs/setup-rke2.md) for the full guide.

### Airgapped Environments

See [docs/airgap.md](docs/airgap.md) for the complete airgap workflow.

## Repository Structure

```
cti-stack/
|-- argocd/                    # App-of-apps Helm chart (ArgoCD orchestrator)
|   |-- Chart.yaml
|   |-- values.yaml            # Base configuration (baseDomain, repoURL, toggles)
|   |-- values-k3s.yaml        # k3s profile overrides
|   |-- values-rke2.yaml       # RKE2 profile overrides
|   +-- templates/             # ArgoCD Application CRs with sync waves
|
|-- charts/                    # Individual Helm charts for each component
|   |-- cert-manager/          # TLS certificate automation
|   |-- ingress-nginx/         # Ingress controller
|   |-- cluster-issuer/        # Self-signed CA chain
|   |-- postgresql/            # CloudNativePG PostgreSQL cluster
|   |-- opensearch/            # Search and analytics engine
|   |-- kafka/                 # Strimzi Kafka cluster
|   |-- redis/                 # Redis cache
|   |-- rabbitmq/              # RabbitMQ message broker
|   |-- minio/                 # S3-compatible object storage
|   |-- keycloak/              # Identity and access management
|   |-- monitoring/            # Prometheus + Grafana + Loki
|   |-- azul-prereqs/          # Azul secrets and prerequisites
|   |-- azul/                  # Azul values overlay (multi-source)
|   |-- opencti-prereqs/       # OpenCTI secrets and prerequisites
|   |-- opencti/               # OpenCTI platform
|   |-- mobsf-prereqs/         # MobSF secrets and prerequisites
|   +-- mobsf/                 # Mobile Security Framework
|
|-- scripts/                   # Operational scripts
|   |-- generate-secrets.sh    # Generate random secrets for all CHANGE_ME values
|   |-- airgap-bundle.sh       # Pull all images + package charts for offline transfer
|   |-- airgap-push.sh         # Push bundled images to a Docker registry (offline)
|   +-- validate.sh            # Lint and template all charts
|
+-- docs/                      # Documentation
    |-- architecture.md        # Architecture overview, sync waves, resource budgets
    |-- setup-k3s.md           # k3s deployment guide
    |-- setup-rke2.md          # RKE2 deployment guide
    |-- airgap.md              # Airgap deployment workflow
    |-- secrets.md             # Secrets management strategy
    +-- keycloak-sso.md        # Keycloak SSO configuration
```

## Configuration

### Base Domain

All services are exposed at `<service>.<baseDomain>`. Set this in `argocd/values.yaml`:

```yaml
global:
  baseDomain: cti.example.com
```

Default subdomains: `azul`, `opencti`, `mobsf`, `keycloak`, `grafana`.

### Cluster Profile

Choose between `k3s` and `rke2` by passing the appropriate values file:

| Profile | Storage Class | Replicas | Use Case |
|---------|--------------|----------|----------|
| k3s | `local-path` | Single | Standalone analyst workstation, lab |
| rke2 | `longhorn` | Multiple | Team deployment, production |

### Component Toggles

Disable individual components in `argocd/values.yaml`:

```yaml
components:
  azul: true
  opencti: true
  mobsf: true
```

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| [Azul](https://github.com/AustralianCyberSecurityCentre/azul-app) | upstream main | Malware analysis platform (ACSC) |
| [OpenCTI](https://github.com/OpenCTI-Platform/opencti) | 1.2.6 (chart) | Threat intelligence platform |
| [MobSF](https://github.com/MobSF/Mobile-Security-Framework-MobSF) | 4.1.3 | Mobile app security analysis |
| [Keycloak](https://www.keycloak.org/) | 26.0 | SSO / Identity provider |
| [PostgreSQL](https://cloudnative-pg.io/) | 16.4 | Relational database (CloudNativePG) |
| [OpenSearch](https://opensearch.org/) | latest | Search and analytics |
| [Kafka](https://strimzi.io/) | 3.8.0 | Event streaming (Strimzi) |
| [Redis](https://redis.io/) | 7.4 | In-memory cache |
| [RabbitMQ](https://www.rabbitmq.com/) | 3.13 | Message broker |
| [MinIO](https://min.io/) | latest | S3-compatible object storage |
| [cert-manager](https://cert-manager.io/) | 1.17.1 | TLS certificate automation |
| [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) | 4.12.0 | Ingress controller |
| [Prometheus + Grafana](https://prometheus.io/) | 67.4.0 (kube-prometheus-stack) | Metrics and dashboards |
| [Loki](https://grafana.com/oss/loki/) | 6.24.0 | Log aggregation |

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | System design, sync waves, resource budgets, network topology |
| [k3s Setup](docs/setup-k3s.md) | Step-by-step k3s deployment guide (incl. audit logging, secrets encryption) |
| [RKE2 Setup](docs/setup-rke2.md) | Step-by-step RKE2 deployment guide (incl. audit logging, secrets encryption) |
| [Airgap Guide](docs/airgap.md) | Deploying in disconnected environments |
| [Secrets](docs/secrets.md) | Secrets strategy, inventory, and production alternatives |
| [Keycloak SSO](docs/keycloak-sso.md) | SSO configuration, realm setup, user management |
| [ISM Compliance](docs/ism-compliance.md) | ISM control mapping, verification commands, residual risks |

## Validation

Lint and template all charts:

```bash
./scripts/validate.sh
```

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Individual components (Azul, OpenCTI, MobSF, etc.) are subject to their own licenses.
