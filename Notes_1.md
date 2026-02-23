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

## Q4: Explain the YAML files for the management and edge1 clusters

Each cluster has **two files**: an `env` file (shell variables) and a `cluster.yaml` (KinD config template). The YAML files are **templates** — the `$VARIABLES` get replaced via `envsubst` before being passed to `kind create cluster`.

---

### Management Cluster

**`platforms/kind/clusters/management/env`:**

```bash
CLUSTER_NAME=management
CLUSTER_DISPLAY_NAME=Management

API_PORT=31000
DASHBOARD_PORT=32000
```

**`platforms/kind/clusters/management/cluster.yaml` (template):**

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

name: $CLUSTER_NAME                        # → "management"
networking:
  apiServerAddress: $API_ADDRESS            # → "127.0.0.1" (default from kind/start)
  apiServerPort: $API_PORT                  # → 31000
  podSubnet: 10.97.0.0/16                  # Custom pod CIDR
  serviceSubnet: 10.197.0.0/16             # Custom service CIDR
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: $DASHBOARD_CONTAINER_PORT  # → 30000 (default from kind/start)
    hostPort: $DASHBOARD_PORT                 # → 32000
  - containerPort: 32100                      # Gitea NodePort (hardcoded)
    hostPort: 32100                           # Same port on host
```

**Line-by-line explanation:**

| Field | Value | Meaning |
|---|---|---|
| `kind: Cluster` | — | This is a KinD cluster configuration (not a Kubernetes resource) |
| `apiVersion: kind.x-k8s.io/v1alpha4` | — | KinD config API version |
| `name` | `management` | The KinD cluster will be named "management". kubectl context becomes `kind-management` |
| `apiServerAddress` | `127.0.0.1` | The K8s API server binds to localhost |
| `apiServerPort` | `31000` | The K8s API server is exposed on host port 31000 |
| `podSubnet` | `10.97.0.0/16` | Custom IP range for Pods (avoids overlap with edge1's `10.98.0.0/16`) |
| `serviceSubnet` | `10.197.0.0/16` | Custom IP range for Services (avoids overlap with edge1's `10.198.0.0/16`) |
| `nodes[0].role` | `control-plane` | Single-node cluster — this node acts as both control plane and worker |
| `extraPortMappings[0]` | `30000 → 32000` | Maps the **dashboard's** container NodePort (30000) to host port 32000 |
| `extraPortMappings[1]` | `32100 → 32100` | Maps **Gitea's** NodePort (32100) straight through to host port 32100 |

---

### Edge1 Cluster

**`platforms/kind/clusters/edge1/env`:**

```bash
CLUSTER_NAME=edge1
CLUSTER_DISPLAY_NAME='Edge 1'

API_PORT=31001
DASHBOARD_PORT=32001
```

**`platforms/kind/clusters/edge1/cluster.yaml` (template):**

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

name: $CLUSTER_NAME                        # → "edge1"
networking:
  apiServerAddress: $API_ADDRESS            # → "127.0.0.1"
  apiServerPort: $API_PORT                  # → 31001
  podSubnet: 10.98.0.0/16                  # Different from management!
  serviceSubnet: 10.198.0.0/16             # Different from management!
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: $DASHBOARD_CONTAINER_PORT  # → 30000
    hostPort: $DASHBOARD_PORT                 # → 32001
```

**Key differences from management:**

| Aspect | Management | Edge1 |
|---|---|---|
| `name` | `management` | `edge1` |
| `apiServerPort` | `31000` | `31001` |
| `podSubnet` | `10.97.0.0/16` | `10.98.0.0/16` |
| `serviceSubnet` | `10.197.0.0/16` | `10.198.0.0/16` |
| `DASHBOARD_PORT` | `32000` | `32001` |
| **Gitea port mapping** | ✅ Yes (32100) | ❌ None |

---

### Why different subnets?

Since both clusters run on the **same Docker network** on your host machine, they need **non-overlapping IP ranges**. If both used the default `10.96.0.0/16` pods and `10.96.0.0/12` services, there would be IP conflicts. So each cluster gets its own CIDR block:

```
Management:  Pods → 10.97.x.x    Services → 10.197.x.x
Edge1:       Pods → 10.98.x.x    Services → 10.198.x.x
```

### Why does edge1 have NO Gitea port mapping?

Because **Gitea only runs on the management cluster**. Edge1 doesn't need to expose port 32100 since it doesn't host a Git server — it only runs Config Sync which *pulls from* Gitea over the Docker network.

### How `envsubst` works here

The `kind/start` script runs:

```bash
CLUSTER_NAME="$CLUSTER_NAME" API_ADDRESS="$API_ADDRESS" API_PORT="$API_PORT" \
DASHBOARD_PORT="$DASHBOARD_PORT" DASHBOARD_CONTAINER_PORT="$DASHBOARD_CONTAINER_PORT" \
envsubst < "$HERE/clusters/$CLUSTER/cluster.yaml" > "$HERE/work/$CLUSTER-cluster.yaml"
```

This reads the template YAML, replaces all `$VARIABLE` placeholders with actual values, and writes the result to `work/management-cluster.yaml` or `work/edge1-cluster.yaml`. That generated file is then passed to `kind create cluster --config=...`.

### What the resulting port layout looks like on your host

```
Host Machine (localhost)
├── Port 31000 → management cluster K8s API
├── Port 31001 → edge1 cluster K8s API
├── Port 32000 → management cluster Dashboard (Web View)
├── Port 32001 → edge1 cluster Dashboard (Web View)
└── Port 32100 → management cluster Gitea (Git server)
```

---

## Q5: How to open the Gitea dashboard in my browser when running on a remote Azure VM?

### The Problem

The KinD cluster config has `apiServerAddress: $API_ADDRESS` which defaults to `127.0.0.1`. This means the ports (including Gitea's 32100) are only bound to **localhost on the Azure VM** — they're not accessible from outside the VM.

---

### Option 1: SSH Port Forwarding (Recommended — simplest & most secure)

From **your local machine**, run:

```bash
ssh -L 32100:localhost:32100 -L 32000:localhost:32000 -L 32001:localhost:32001 <your-azure-user>@<azure-vm-public-ip>
```

This tunnels the remote ports to your local machine. Then open in your **local browser**:

- **Gitea**: `http://localhost:32100`
- **Management Dashboard**: `http://localhost:32000`
- **Edge1 Dashboard**: `http://localhost:32001`

**Breakdown of the flags:**
| Flag | Meaning |
|---|---|
| `-L 32100:localhost:32100` | Forward local port 32100 → remote VM's localhost:32100 (Gitea) |
| `-L 32000:localhost:32000` | Forward local port 32000 → remote VM's localhost:32000 (Mgmt dashboard) |
| `-L 32001:localhost:32001` | Forward local port 32001 → remote VM's localhost:32001 (Edge1 dashboard) |

**If you're already SSH'd into the VM**, you can set up the tunnel separately:
```bash
ssh -N -L 32100:localhost:32100 <your-azure-user>@<azure-vm-public-ip>
```
(`-N` means don't execute a remote command, just forward ports)

---

### Option 2: `kubectl port-forward` (Works without changing KinD config)

SSH into the Azure VM first, then:

```bash
# Switch to management cluster
kubectl config use-context kind-management

# Port-forward Gitea service to all interfaces (0.0.0.0)
kubectl port-forward svc/gitea-http --namespace=gitea --address=0.0.0.0 8080:3000 &
```

Then open: `http://<azure-vm-public-ip>:8080`

> ⚠️ **Note:** You'll need to open port 8080 in your Azure NSG (Network Security Group) for this to work.

---

### Option 3: Change `apiServerAddress` to `0.0.0.0` (Binds to all interfaces)

Before creating the clusters, modify the KinD config so ports bind to all network interfaces instead of just localhost. Create/edit `_override` at the project root:

```bash
# In the project root, create _override file
echo 'API_ADDRESS=0.0.0.0' > _override
```

This makes `apiServerAddress: 0.0.0.0` in the generated cluster YAML, so **all ports** (31000, 31001, 32000, 32001, 32100) become accessible on the VM's public IP.

Then open: `http://<azure-vm-public-ip>:32100`

> ⚠️ **Security Warning:** This exposes your K8s API and all services to the internet. You **must** ensure your Azure NSG only allows traffic from your IP.

**Azure NSG rule to add:**

```bash
az network nsg rule create \
  --resource-group <your-rg> \
  --nsg-name <your-nsg> \
  --name AllowKindPorts \
  --priority 1000 \
  --source-address-prefixes <your-local-ip>/32 \
  --destination-port-ranges 31000-32100 \
  --access Allow \
  --protocol Tcp
```

---

### Recommendation

| Method | Pros | Cons |
|---|---|---|
| **SSH Tunnel** ✅ | No config changes, secure, no NSG changes | Need to keep SSH session open |
| **kubectl port-forward** | Flexible, works per-service | Need NSG change, runs in foreground |
| **0.0.0.0 binding** | Most convenient, all ports accessible | Least secure, need NSG changes, need to recreate clusters |

**SSH tunneling is the best option** — zero config changes, zero security risk, and works immediately.

---

## Q6: How to add the PEM key to the SSH tunnel command?

Use the **`-i`** flag to specify the private key file:

```bash
ssh -i /path/to/your-key.pem \
  -L 32100:localhost:32100 \
  -L 32000:localhost:32000 \
  -L 32001:localhost:32001 \
  <your-azure-user>@<azure-vm-public-ip>
```

| Flag | Meaning |
|---|---|
| `-i /path/to/your-key.pem` | Use this private key file for authentication |
| `-L ...` | Port forwarding (same as before) |

**Common example for Azure:**

```bash
ssh -i ~/.ssh/myAzureVM.pem \
  -L 32100:localhost:32100 \
  -L 32000:localhost:32000 \
  -L 32001:localhost:32001 \
  azureuser@20.123.45.67
```

> **Tip:** Make sure the PEM file has correct permissions: `chmod 400 /path/to/your-key.pem` — SSH will refuse to use it if it's too open.

---

## Q7: How to sign in to the Gitea dashboard?

The deploy scripts create **two users**. Use either set of credentials on the Gitea sign-in page:

### Admin User (created by `workloads/gitea/deploy`)

| Field | Value |
|---|---|
| **Username** | `administrator` |
| **Password** | `administrator` |
| **Source** | `workloads/gitea/_env` |
| **Role** | Admin (full access — can manage all users, repos, settings) |

### Demo User (created by `environments/config-sync-demo/start`)

| Field | Value |
|---|---|
| **Username** | `config-sync-developer` |
| **Password** | `config-sync` |
| **Source** | `environments/config-sync-demo/_env` |
| **Role** | Regular user (owns the `config-sync-demo` repo) |

### Steps

1. Open `http://localhost:32100` (via SSH tunnel) or `http://<hostname>:32100`
2. Click **"Sign In"** (top right)
3. Enter username and password from either user above
4. Click **"Sign In"**

> **Use `administrator` / `administrator`** if you want full admin access to see all settings and manage users. Use `config-sync-developer` / `config-sync` if you just want to work with the demo repo.

---

## Q8: "Username or password is incorrect" when trying to sign in as administrator — why and how to fix?

### Root Cause

The user was **never actually created**. The `create-user` script (`workloads/gitea/admin/gitea`) runs:

```bash
kubectl exec statefulset/gitea --container=gitea --namespace=gitea --quiet -- \
  su git -c "gitea --quiet admin user create ..."
```

But as we saw in Q3, **there is no `statefulset/gitea`** in the newer chart — Gitea runs as a **Deployment** now. So this `kubectl exec` command **failed**, but the `|| true` in the deploy script swallowed the error silently.

### How to fix — Create the admin user manually

**Step 1:** Find the Gitea pod name:

```bash
kubectl get pods --namespace=gitea
```

Look for a pod named something like `gitea-<random-hash>` (the Deployment pod).

**Step 2:** Exec into it and create the admin user:

```bash
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  su git -c "gitea admin user create \
    --username administrator \
    --password administrator \
    --email administrator@gitea \
    --admin \
    --must-change-password=false"
```

> **If the password `administrator` is rejected** (newer Gitea versions require minimum 8 chars with complexity), use a stronger password:

```bash
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  su git -c "gitea admin user create \
    --username administrator \
    --password 'Admin123!' \
    --email administrator@gitea \
    --admin \
    --must-change-password=false"
```

**Step 3:** Also create the demo user:

```bash
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  su git -c "gitea admin user create \
    --username config-sync-developer \
    --password config-sync \
    --email config-sync-developer@gitea \
    --must-change-password=false"
```

**Step 4:** Create the demo repo (via API):

```bash
curl -X POST "http://localhost:32100/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -u "config-sync-developer:config-sync" \
  -d '{"name": "config-sync-demo", "default_branch": "main"}'
```

### Why this happened — summary

The `workloads/gitea/admin/gitea` script has the same stale reference to `statefulset/gitea` that we fixed in the deploy script. It should be updated to `deployment/gitea` as well for the newer chart version.

---

## Q9: "su: must be suid to work properly" error when creating user

### Why it happens

The older `create-user` script uses `su git -c "gitea ..."` to switch to the `git` user before running the Gitea CLI. But in newer Gitea container images, the `su` binary doesn't have the suid bit set (for security hardening). However, the container **already runs as the `git` user**, so `su` is unnecessary.

### Fix — run `gitea` directly without `su`

```bash
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  gitea admin user create \
    --username administrator \
    --password administrator \
    --email administrator@gitea \
    --admin \
    --must-change-password=false
```

If the password `administrator` is rejected (password complexity), try:

```bash
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  gitea admin user create \
    --username administrator \
    --password 'Admin@1234' \
    --email administrator@gitea \
    --admin \
    --must-change-password=false
```

Then create the demo user:

```bash
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  gitea admin user create \
    --username config-sync-developer \
    --password config-sync \
    --email config-sync-developer@gitea \
    --must-change-password=false
```

### Verify who the container runs as

You can check what user the container runs as:

```bash
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- whoami
```

This should output `git`, confirming `su` is not needed.

---
