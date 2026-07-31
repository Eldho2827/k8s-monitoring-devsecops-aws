# Monitoring Documentation
## Capstone 3 — Enterprise Observability & DevSecOps Platform

**Author:** Eldho Sabu
**Repository:** [k8s-monitoring-devsecops-aws](https://github.com/Eldho2827/k8s-monitoring-devsecops-aws)

---

## 1. Overview

This document describes the monitoring, alerting, and DevSecOps implementation built for Capstone 3. It maps every requirement in the project brief to the actual configuration delivered, explains the one deliberate substitution made and why, and records the operational details needed to reproduce or extend the platform.

---

## 2. Architecture

```
AWS (ap-south-1)
│
├── Kubernetes Cluster (kubeadm, 3× t3.small, Ubuntu 24.04)
│   ├── k8s-master      — control plane
│   ├── k8s-worker-1     — application + monitoring workloads
│   ├── k8s-worker-2     — application + monitoring workloads
│   │
│   ├── Networking: Calico CNI
│   │
│   ├── monitoring namespace
│   │   ├── Prometheus (kube-prometheus-stack)
│   │   ├── Grafana
│   │   ├── AlertManager
│   │   ├── Node Exporter (DaemonSet)
│   │   └── kube-state-metrics
│   │
│   └── demo-app namespace
│       └── demo-app deployment (2 replicas, custom nginx-based image)
│
├── Jenkins (dedicated t3.small EC2)
│   ├── Jenkins Controller
│   ├── SonarQube Scanner CLI
│   ├── Trivy
│   ├── Gitleaks
│   ├── OWASP Dependency-Check
│   ├── Docker Engine
│   ├── kubectl
│   └── Node Exporter (host metrics, scraped by cluster Prometheus)
│
└── SonarQube (dedicated c7i-flex.large EC2)
    └── SonarQube Community Edition (Docker)
```

**Design rationale:** SonarQube and Jenkins run on their own dedicated EC2 instances rather than inside the Kubernetes cluster. SonarQube's bundled Elasticsearch is memory-intensive and would not fit comfortably alongside the cluster's own workloads on `t3.small` nodes, so it was given its own memory-optimized instance (`c7i-flex.large`). Keeping CI/CD tooling (Jenkins) outside the cluster it deploys to is also a common real-world pattern, avoiding a circular dependency where the deployment pipeline depends on the availability of the cluster it's shipping to.

---

## 3. Monitoring Stack

| Component | Purpose | Status |
|---|---|---|
| Prometheus | Metrics collection and storage | ✅ Installed via kube-prometheus-stack, exposed via NodePort |
| Grafana | Visualization | ✅ Installed, exposed via NodePort, default dashboards + 2 imported community dashboards |
| Node Exporter | Host-level metrics (cluster nodes + Jenkins EC2) | ✅ DaemonSet in-cluster; standalone binary on the Jenkins instance |
| kube-state-metrics | Kubernetes object state metrics (deployments, pods, nodes) | ✅ Installed |

All four components were verified with live PromQL queries (CPU, memory, pod, and node-exporter metrics) confirming real data collection, not just successful pod startup.

---

## 4. Dashboards

The default kube-prometheus-stack Grafana installation ships a partial dashboard set — it did not include dedicated views for Deployment Status, Pod Health, or Namespace-level resource utilization. Two additional community dashboards were imported to close this gap:

| Brief category | Dashboard(s) covering it |
|---|---|
| CPU Usage | Node Exporter / Nodes, Node Exporter / USE Method |
| Memory Usage | Node Exporter / Nodes, Node Exporter / USE Method |
| Disk Utilization | Node Exporter / Nodes, Kubernetes / Persistent Volumes |
| Network Traffic | Kubernetes / Networking (Cluster, Namespace, Pod, Workload) |
| Pod Health | **Kubernetes / Views / Pods** (imported, Grafana.com ID 15760) |
| Node Health | Node Exporter / Nodes |
| Deployment Status | **Kubernetes Cluster (Prometheus)** (imported, Grafana.com ID 315) |
| Namespace Utilization | Kubernetes Cluster (Prometheus) (ID 315) + Kubernetes / Networking / Namespace |

Both imported dashboards were verified against live cluster data (not left in a default/empty state) — confirmed showing real deployment replica counts, pod resource usage, and node counts for the `demo-app` namespace specifically, not just the monitoring stack's own pods.

---

## 5. Alerting

Seven alert rules were required. Six map directly to the brief's naming; the seventh required a documented substitution.

| Brief requirement | Implemented as | Notes |
|---|---|---|
| High CPU | `HighCPUUsage` | Node-level, >80% for 5m |
| High Memory | `HighMemoryUsage` | Node-level, >85% for 5m |
| Pod CrashLoopBackOff | `PodCrashLoopBackOff` | Verified firing (see §7) |
| Node Not Ready | `NodeNotReady` | Node condition-based |
| Disk Space | `LowDiskSpace` | <15% available |
| Application Down | `ApplicationDown` | Deployment replica availability; verified firing |
| High Error Rate | **`HighPodRestartRate`** (substitution) | See below |

### Substitution rationale: High Error Rate → HighPodRestartRate

A literal "High Error Rate" alert requires an application that exposes HTTP-level metrics (e.g. a `http_requests_total` counter with a status-code label). The demo application deployed for this project is unmodified `nginx` serving static content, with no application-level instrumentation. Rather than fabricate a metric the application doesn't actually produce, `HighPodRestartRate` (`increase(kube_pod_container_status_restarts_total[15m]) > 3`) was implemented as an honest proxy: it detects the same underlying signal — the application repeatedly failing — using metrics the platform genuinely exposes. If application-level instrumentation is added in a future iteration, a literal error-rate alert against `http_requests_total{status=~"5.."}` would be the direct upgrade path.

All alert rules were validated as loading without syntax errors, and three (`PodCrashLoopBackOff`, `ApplicationDown`, `HighPodRestartRate`) were explicitly triggered and confirmed reaching `firing` state in both Prometheus and AlertManager.

---

## 6. DevSecOps Pipeline

| Requirement | Tool | Status |
|---|---|---|
| SonarQube | SonarQube Community Edition (standalone EC2) | ✅ |
| Quality Gates | Default SonarQube Quality Gate | ✅ Enforced — pipeline aborts on `ERROR` status |
| Dependency Scanning | OWASP Dependency-Check | ✅ Non-blocking (see note below) |
| Container Image Scanning | Trivy | ✅ Hard-blocking on CRITICAL severity |
| Secret Detection | Gitleaks | ✅ Blocking |

**Dependency-Check is intentionally non-blocking.** In this lab environment, Dependency-Check's National Vulnerability Database (NVD) sync frequently fails or times out due to NVD's public API rate limits, which is a known, common issue in ephemeral CI environments without a persisted, pre-warmed vulnerability database. The pipeline stage is wrapped in a try/catch so a failed NVD sync doesn't block otherwise-passing builds; the scan still runs and reports when the database is reachable. In a persistent production environment, this would typically be resolved with a scheduled, cached NVD database refresh and the stage would then be made blocking.

**Quality Gate was proven to actually enforce, not just run:** a real SonarQube Security Hotspot (container running as root) and a real accessibility bug (missing `lang` attribute) were both caught during development and required actual code fixes before the pipeline could proceed — not simulated failures.

**Trivy was proven to actually block, not just scan:** an initial build using `nginx:latest` was deliberately tested and correctly failed the pipeline after Trivy found 5 CRITICAL CVEs. The base image was then pinned to `nginx:stable-alpine`, which scans clean at 0 vulnerabilities, and the pipeline was confirmed to pass.

---

## 7. Jenkins Pipeline

The brief specified 8 stages; Secret Detection was added as an additional stage ahead of the scanning stages, for 9 total.

```
Checkout
    ↓
Secret Detection (Gitleaks)
    ↓
Dependency Scanning (OWASP Dependency-Check, non-blocking)
    ↓
SonarQube Scan
    ↓
Quality Gate
    ↓
Docker Build
    ↓
Image Scan (Trivy, blocking on CRITICAL)
    ↓
Push Registry (Docker Hub)
    ↓
Deploy to Kubernetes
    ↓
Rollout Verification
```

Each build produces a uniquely-tagged image (`eldho10/capstone3-demo-app:<build-number>`), so every deployment is traceable to the exact pipeline run that produced it.

**Verified failure-mode behavior (not just the happy path):**
- Quality Gate correctly aborted the pipeline when a real SonarQube issue and Security Hotspot were present, and correctly passed once fixed.
- Image Scan correctly aborted the pipeline against a vulnerable base image, and correctly passed against a clean one.
- Dependency Scanning correctly continued past an infrastructure-level failure (NVD unreachable) without masking the underlying issue in logs.

---

## 8. Production Monitoring

The brief requires monitoring of Jenkins, Kubernetes, Docker, application, and infrastructure metrics — not Kubernetes alone.

| Target | Method |
|---|---|
| Kubernetes | Native kube-prometheus-stack scraping (kubelet, cAdvisor, kube-state-metrics) |
| Jenkins (host) | Node Exporter installed directly on the Jenkins EC2 instance |
| Jenkins (build/pipeline) | Jenkins Prometheus plugin, exposing `/prometheus` with per-job and per-stage build metrics |
| Docker | Covered by the Jenkins host's Node Exporter (Docker runs on the same instance) |
| Application | `demo-app` deployment metrics via kube-state-metrics + custom alert rules |
| Infrastructure | Node Exporter across all cluster nodes + the Jenkins instance |

Both Jenkins-related scrape targets (`jenkins-node-exporter`, `jenkins-metrics`) were added to the cluster's Prometheus via an `additionalScrapeConfigs` Secret and confirmed `UP` on the Prometheus targets page.

---

## 9. Deliverables Checklist

| Deliverable | Status | Location |
|---|---|---|
| Prometheus Configuration | ✅ | `monitoring/` in repo; additional scrape configs applied via kubectl |
| Grafana Dashboards | ✅ | Default kube-prometheus-stack set + 2 imported (IDs 315, 15760) |
| Jenkins Pipeline | ✅ | `jenkins/Jenkinsfile` |
| SonarQube Integration | ✅ | Quality Gate enforced, webhook-driven (no polling delay) |
| Alert Rules | ✅ | `monitoring/custom-alert-rules.yaml` (7 rules, 1 documented substitution) |
| Monitoring Documentation | ✅ | This document |

---

## 10. Screenshot Index

| # | Description |
|---|---|
| 01–07 | AWS infrastructure, Kubernetes cluster bring-up (kubeadm, Calico, node readiness) |
| 08–16 | Monitoring stack installation, Grafana/Prometheus access, PromQL validation |
| 17–20 | Custom alert rules applied, demo app deployed, alert firing proof, AlertManager receipt |
| 21–23 | SonarQube dashboard, Trivy scan output, Trivy blocking a vulnerable build |
| 24–27 | Jenkins pipeline evolution (5-stage → 8-stage), Docker Hub image push |
| 28–29 | Grafana Deployment Status and Pod Health dashboards, scoped to demo-app |
| 30 | Final complete 9-stage pipeline, all stages passing |

---

## 11. Known Limitations

- **Dependency-Check** does not reliably complete NVD synchronization in this lab network environment; the stage is non-blocking by design rather than masking the issue.
- **HighPodRestartRate** substitutes for a literal HTTP error-rate alert, since the demo application has no instrumented `/metrics` endpoint. Documented in §5.
- Several AWS security group rules remain open to `0.0.0.0/0` rather than scoped to a single administrator IP; this is a known cleanup item, not yet addressed, and does not affect the functional deliverables above.
