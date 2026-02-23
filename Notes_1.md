# Notes

---

## Q1: What happens step by step when I run `environments/config-sync-demo/start`?

This script sets up a **two-cluster demo environment** (a "management" cluster and an "edge1" cluster) using KinD (Kubernetes in Docker), deploys **Gitea** (a self-hosted Git server) on the management cluster, and deploys **Config Sync** on the edge1 cluster. Here's the step-by-step breakdown:

---

### Phase 0: Initialization & Environment Setup (Lines 1–8)

```bash
set -e                    # Exit immediately on any error
HERE=$(dirname ...)       # Resolves the script's own directory
. "$HERE/../../_env"      # Sources the ROOT-level _env
. "$ROOT/library/_trap"   # Sources the trap handlers
. "$HERE/_env"            # Sources the demo-specific _env
```

1. **`set -e`** — Makes the script fail-fast. Any command that returns a non-zero exit code will immediately terminate the script.

2. **`_env` (root level)** — Sets up:
   - `ROOT` variable (project root directory)
   - Sources `library/_functions` which defines helper functions like `m` (colored message printer), `envsubst_dir`, `browse_url`, `kubectl_wait_for_deployment`, `install_tool`, etc.
   - Defines version constants for all tools: `KIND_VERSION=0.20.0`, `CONFIG_SYNC_VERSION=1.16.1`, `PORCH_VERSION=0.0.23`, etc.
   - Sets `HOST=$(hostname)`, `WORKSPACE=workspace`, `TMPDIR`, etc.
   - Optionally sources `_override` if it exists (for local overrides).

3. **`_trap`** — Installs trap handlers:
   - **`trap_EXIT`**: On script exit, prints a success/failure message with elapsed time (in green or red).
   - **`trap_INT`**: On Ctrl+C interrupt, prints "Aborted" and exits.
   - Records `TRAP_START_TIME` so it can calculate duration at the end.

4. **`_env` (demo-specific)** — Sets Git-related environment variables for the demo:
   - `GIT_USERNAME=config-sync-developer`
   - `GIT_PASSWORD=config-sync`
   - `GIT_EMAIL=config-sync-developer@gitea`
   - `GIT_NAME='Config Sync Developer'`
   - `GIT_REPO=config-sync-demo`

---

### Phase 1: Prepare Working Assets (Lines 9–11)

```bash
rm --force --recursive "$HERE/work/"
GIT_HOST="http://$HOST:32100" GIT_USERNAME="$GIT_USERNAME" GIT_REPO="$GIT_REPO" \
  envsubst_dir "$HERE/assets" "$HERE/work"
```

1. **Cleans up** any previous `work/` directory.
2. **Copies `assets/` → `work/`** while performing **environment variable substitution** (`envsubst`) on every file. This means template placeholders like `$GIT_HOST`, `$GIT_USERNAME`, `$GIT_REPO` inside the asset files get replaced with their actual values.
   - The `assets/` directory contains:
     - **`root-sync.yaml`** — A `RootSync` custom resource (for Config Sync) that points to the Gitea Git repo:
       ```yaml
       spec:
         sourceFormat: unstructured
         git:
           repo: $GIT_HOST/$GIT_USERNAME/$GIT_REPO.git  # becomes http://<hostname>:32100/config-sync-developer/config-sync-demo.git
           dir: /root
           branch: main
           auth: none
       ```
     - **`deployment-repository/`** — Contains subdirectories `namespaces/` and `root/` (the initial content to push to the Git repo).

---

### Phase 2: Create KinD Clusters (Line 13)

```bash
"$ROOT/platforms/kind/start" management edge1
```

This calls the `kind/start` script with **two arguments**: `management` and `edge1`. The script loops over each cluster name and:

**For the `management` cluster:**
1. Sources `platforms/kind/clusters/management/env`:
   - `CLUSTER_NAME=management`, `CLUSTER_DISPLAY_NAME=Management`
   - `API_PORT=31000`, `DASHBOARD_PORT=32000`
2. Runs `envsubst` on `cluster.yaml` to generate a KinD config with the correct ports.
3. Runs **`kind create cluster`** with that config — creates a Docker-based Kubernetes cluster named "management".
4. Since `DASHBOARD_PORT` is set (32000), it also:
   - Switches kubectl context to the management cluster.
   - Deploys a **Kubernetes Web View** dashboard.
   - Opens `http://localhost:32000` in the browser (if `USE_BROWSER=true`).

**For the `edge1` cluster:**
1. Sources `platforms/kind/clusters/edge1/env`:
   - `CLUSTER_NAME=edge1`, `CLUSTER_DISPLAY_NAME='Edge 1'`
   - `API_PORT=31001`, `DASHBOARD_PORT=32001`
2. Creates a KinD cluster named "edge1".
3. Deploys a dashboard and opens `http://localhost:32001`.

After this step, you have **two local Kubernetes clusters** running inside Docker containers.

---

### Phase 3: Set Up Management Cluster (Lines 15–21)

```bash
m 'setting up management cluster...'
"$ROOT/platforms/kind/use" management
```

1. Prints the blue message "setting up management cluster...".
2. **Switches kubectl context** to the management cluster: `kubectl config use-context kind-management`.

```bash
"$ROOT/workloads/gitea/deploy"
```

3. **Deploys Gitea** (a lightweight self-hosted Git service) onto the management cluster:
   - Creates the `gitea` namespace.
   - Adds the Gitea Helm chart repo.
   - Runs `helm install gitea` with NodePort service on port **32100**.
   - Waits for the Gitea StatefulSet to be fully rolled out (up to 1 hour timeout).
   - Creates an **admin user** (`administrator` / `administrator`).
   - Opens Gitea in the browser at `http://<hostname>:32100`.

```bash
"$ROOT/workloads/gitea/admin/create-user" "$GIT_USERNAME" "$GIT_PASSWORD" "$GIT_EMAIL" || true
```

4. **Creates the demo user** in Gitea:
   - Username: `config-sync-developer`
   - Password: `config-sync`
   - Email: `config-sync-developer@gitea`
   - The `|| true` means it won't fail if the user already exists.

```bash
"$ROOT/workloads/gitea/admin/create-user-repository" "$GIT_USERNAME" "$GIT_PASSWORD" "$GIT_REPO" || true
```

5. **Creates a Git repository** for the demo user via the Gitea API:
   - Repo name: `config-sync-demo`
   - Default branch: `main`
   - Again, `|| true` so it's idempotent.

---

### Phase 4: Set Up Edge1 Cluster (Lines 23–27)

```bash
m 'setting up edge1 cluster...'
"$ROOT/platforms/kind/use" edge1
```

1. Prints "setting up edge1 cluster...".
2. **Switches kubectl context** to the edge1 cluster: `kubectl config use-context kind-edge1`.

```bash
"$ROOT/workloads/config-sync/deploy"
```

3. **Deploys Config Sync** (v1.16.1) onto the edge1 cluster:
   - Applies the Config Sync manifest directly from the GitHub releases URL.
   - Waits for the `reconciler-manager` Deployment in the `config-management-system` namespace to become available (up to 1 hour timeout).

---

### Phase 5: Trap Exit (Automatic)

When the script finishes (or fails), the **trap handler** runs automatically:
- Calculates total elapsed time.
- Prints either:
  - ✅ `"environments/config-sync-demo/start succeeded! HH:MM:SS"` (in green)
  - ❌ `"Oh no! environments/config-sync-demo/start failed! HH:MM:SS"` (in red)

---

### Summary Diagram

```
┌────────────────────────────────────────────────────────────┐
│              environments/config-sync-demo/start           │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  1. Source env files & set up trap handlers                 │
│  2. envsubst assets → work/ (template substitution)        │
│                                                            │
│  3. kind create cluster "management" (port 31000/32000)    │
│     └── Deploy Kubernetes Web View dashboard               │
│  4. kind create cluster "edge1" (port 31001/32001)         │
│     └── Deploy Kubernetes Web View dashboard               │
│                                                            │
│  5. Switch to management cluster                           │
│     ├── Deploy Gitea (Helm, NodePort 32100)                │
│     ├── Create admin user (administrator)                  │
│     ├── Create demo user (config-sync-developer)           │
│     └── Create repo (config-sync-demo)                     │
│                                                            │
│  6. Switch to edge1 cluster                                │
│     └── Deploy Config Sync (v1.16.1)                       │
│                                                            │
│  7. Print success/failure with elapsed time                 │
└────────────────────────────────────────────────────────────┘
```

### End Result

After running the script, you have:

| Component | Cluster | Access |
|---|---|---|
| **KinD cluster "management"** | management | API on port 31000 |
| **KinD cluster "edge1"** | edge1 | API on port 31001 |
| **Kubernetes Web View** | management | `http://localhost:32000` |
| **Kubernetes Web View** | edge1 | `http://localhost:32001` |
| **Gitea** (Git server) | management | `http://<hostname>:32100` |
| **Config Sync** | edge1 | Watches the Gitea repo for changes |
| **Git repo** | management (Gitea) | `config-sync-developer/config-sync-demo` |

The idea is: you push Kubernetes manifests to the Gitea repo on the management cluster, and **Config Sync on edge1 automatically syncs** those manifests to the edge1 cluster.

---

## Q2: Did the Gitea StatefulSet name change in later versions? How to know which version of Gitea is being downloaded?

### Part 1: Did the StatefulSet name change?

**Yes, it likely did in newer chart versions.** Here's the deal:

- In **older versions** of the Gitea Helm chart, the StatefulSet was named with a **static name** — simply `gitea` (matching what the deploy script expects: `statefulset/gitea`).
- In **newer versions** (especially post chart v9.x / v10.x), the chart switched to using the **`gitea.fullname` Helm template helper** to generate the StatefulSet name. This template typically produces a name like `<release-name>-<chart-name>`, e.g., **`gitea-gitea`** (since the Helm release name is `gitea` and the chart name is also `gitea`).

So the command in the deploy script:

```bash
kubectl rollout status statefulset/gitea --namespace=gitea --watch --timeout=1h
```

**May fail on newer chart versions** because the StatefulSet might now be named `gitea-gitea` instead of `gitea`.

**How to check after deployment:**

```bash
# List all StatefulSets in the gitea namespace to see the actual name
kubectl get statefulsets --namespace=gitea
```

If the name has changed, you'd need to update the script to:
```bash
kubectl rollout status statefulset/gitea-gitea --namespace=gitea --watch --timeout=1h
```

### Part 2: How to know which version is being downloaded?

The deploy script does **not** pin a specific chart version:

```bash
helm install gitea gitea-charts/gitea --namespace=gitea ...
```

There is **no `--version` flag**, which means **Helm installs the latest stable version** of the chart from the repo at the time you run it.

**Important distinction:** The **Helm chart version** ≠ the **Gitea application version**. Each chart version bundles a specific Gitea app version.

**How to find out what version you'll get (or got):**

| Command | What it tells you |
|---|---|
| `helm search repo gitea-charts/gitea` | Shows the **latest chart version** available and the **app version** it bundles |
| `helm search repo gitea-charts/gitea --versions` | Lists **all available chart versions** with their corresponding app versions |
| `helm list --namespace=gitea` | Shows the **installed chart version** (after deployment) |
| `helm get values gitea --namespace=gitea` | Shows the values used for the installed release |

**Example output of `helm search repo`:**

```
NAME                CHART VERSION   APP VERSION   DESCRIPTION
gitea-charts/gitea  11.0.0          1.22.3        Gitea Helm chart for Kubernetes
```

Here, chart version is `11.0.0` and the actual Gitea application version is `1.22.3`.

**To pin a specific version** (recommended for reproducibility), you would add `--version` to the helm install command:

```bash
helm install gitea gitea-charts/gitea --namespace=gitea --version=9.6.1 ...
```

### Summary

The deploy script has **two potential fragility issues**:
1. **No chart version pinned** → You get whatever the latest is, which could introduce breaking changes.
2. **Hardcoded StatefulSet name** (`statefulset/gitea`) → Newer chart versions may generate a different name (e.g., `gitea-gitea`), causing the `kubectl rollout status` command to fail.

---

## Q3: Why do I only see `gitea-postgresql-ha-postgresql` and `gitea-valkey-cluster` StatefulSets — where is the Gitea StatefulSet?

User observed output from `kubectl get statefulsets --namespace=gitea`:

```
gitea-postgresql-ha-postgresql     3/3     11m
gitea-valkey-cluster               3/3     11m
```

### What are these two StatefulSets?

These are **dependency sub-charts** that the Gitea Helm chart installs automatically:

| StatefulSet | What it is | Why it exists |
|---|---|---|
| `gitea-postgresql-ha-postgresql` | **PostgreSQL High Availability** (Bitnami sub-chart) | Gitea's database backend — stores users, repos, issues, etc. 3 replicas for HA. |
| `gitea-valkey-cluster` | **Valkey Cluster** (Bitnami sub-chart) | Valkey is a **Redis fork** — used by Gitea for caching and session storage. 3 replicas for HA. |

### Where is the Gitea app itself?

**In chart v12+ (which you're running since no `--version` was pinned), the Gitea app is deployed as a Deployment, NOT a StatefulSet.**

This is a **breaking change** from older chart versions. Previously, Gitea itself was a StatefulSet. Now:

- **Gitea app** → `Deployment` (not a StatefulSet anymore)
- **PostgreSQL HA** → `StatefulSet` (sub-chart dependency)
- **Valkey Cluster** → `StatefulSet` (sub-chart dependency, replaced the older Redis/Memcached)

### Why does this break the script?

The deploy script runs:
```bash
kubectl rollout status statefulset/gitea --namespace=gitea --watch --timeout=1h
```

This will **fail** because there is no StatefulSet named `gitea`. The Gitea app is now a Deployment. The correct command for the newer chart would be:

```bash
kubectl rollout status deployment/gitea --namespace=gitea --watch --timeout=1h
```

### How to check what's actually deployed:

```bash
# See all Deployments
kubectl get deployments --namespace=gitea

# See all StatefulSets
kubectl get statefulsets --namespace=gitea

# See everything at once
kubectl get all --namespace=gitea
```

### Summary of what changed across Gitea Helm chart versions:

| Aspect | Old chart (≤ v9.x) | New chart (v12+) |
|---|---|---|
| **Gitea app** | StatefulSet named `gitea` | **Deployment** (no more StatefulSet) |
| **Database** | Standalone PostgreSQL | **PostgreSQL HA** (3 replicas, StatefulSet) |
| **Cache/Session** | Redis or Memcached | **Valkey Cluster** (Redis fork, 3 replicas, StatefulSet) |
| **StatefulSet name** | `gitea` | `gitea-postgresql-ha-postgresql`, `gitea-valkey-cluster` |

---
