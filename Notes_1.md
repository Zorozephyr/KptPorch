# Notes — Config Sync Demo Environment

---

## Q1: What happens step by step when I run `environments/config-sync-demo/start`?

This script sets up a **two-cluster demo environment** using KinD (Kubernetes in Docker), deploys **Gitea** (self-hosted Git server) on the management cluster, and deploys **Config Sync** on the edge1 cluster.

### Phases

**Phase 0 — Initialization (Lines 1–8):**
- `set -e` — fail-fast on any error.
- Sources root `_env` (version constants, helper functions like `m`, `envsubst_dir`, `browse_url`), `_trap` (success/failure message with elapsed time on exit), and demo `_env` (Git credentials: `config-sync-developer` / `config-sync`).

**Phase 1 — Prepare Assets (Lines 9–11):**
- Cleans `work/` directory. Copies `assets/` → `work/` with `envsubst` replacing `$GIT_HOST`, `$GIT_USERNAME`, `$GIT_REPO` in templates (notably `root-sync.yaml` which points Config Sync at the Gitea repo).

**Phase 2 — Create KinD Clusters (Line 13):**
- Runs `platforms/kind/start management edge1` — creates two KinD clusters with separate ports and subnets, each with a Kubernetes Web View dashboard.

**Phase 3 — Set Up Management Cluster (Lines 15–21):**
- Switches to `kind-management` context.
- Deploys Gitea via Helm (NodePort 32100).
- Creates admin user (`administrator`/`administrator`) and demo user (`config-sync-developer`/`config-sync`).
- Creates Git repo `config-sync-demo` for the demo user.

**Phase 4 — Set Up Edge1 Cluster (Lines 23–27):**
- Switches to `kind-edge1` context.
- Deploys Config Sync (v1.16.1) via `kubectl apply` from GitHub manifest.
- Waits for `reconciler-manager` Deployment to be available.

**Phase 5 — Trap Exit:**
- Prints success (green) or failure (red) with elapsed time.

### Summary Diagram

```
┌────────────────────────────────────────────────────────────┐
│              environments/config-sync-demo/start           │
├────────────────────────────────────────────────────────────┤
│  1. Source env files & set up trap handlers                 │
│  2. envsubst assets → work/ (template substitution)        │
│  3. kind create cluster "management" (31000/32000)         │
│     └── Deploy Kubernetes Web View dashboard               │
│  4. kind create cluster "edge1" (31001/32001)              │
│     └── Deploy Kubernetes Web View dashboard               │
│  5. Switch to management cluster                           │
│     ├── Deploy Gitea (Helm, NodePort 32100)                │
│     ├── Create admin + demo users                          │
│     └── Create repo (config-sync-demo)                     │
│  6. Switch to edge1 cluster                                │
│     └── Deploy Config Sync (v1.16.1)                       │
│  7. Print success/failure with elapsed time                 │
└────────────────────────────────────────────────────────────┘
```

### End Result

| Component | Cluster | Access |
|---|---|---|
| **Kubernetes Web View** | management | `http://localhost:32000` |
| **Kubernetes Web View** | edge1 | `http://localhost:32001` |
| **Gitea** (Git server) | management | `http://<hostname>:32100` |
| **Config Sync** | edge1 | Watches the Gitea repo for changes |

**The idea:** Push Kubernetes manifests to the Gitea repo → Config Sync on edge1 automatically applies them.

---

## Q2: Gitea Helm Chart Version & Breaking Changes

### Which version gets installed?

The deploy script has **no `--version` flag**, so Helm installs the **latest stable chart**. The chart version ≠ the Gitea app version.

| Command | What it tells you |
|---|---|
| `helm search repo gitea-charts/gitea` | Latest chart + app version available |
| `helm search repo gitea-charts/gitea --versions` | All available versions |
| `helm list --namespace=gitea` | What's currently installed |

To pin a version (recommended): `helm install gitea gitea-charts/gitea --version=9.6.1 ...`

### What changed in newer chart versions (v12+)?

| Aspect | Old chart (≤ v9.x) | New chart (v12+) |
|---|---|---|
| **Gitea app** | `StatefulSet` named `gitea` | **`Deployment`** |
| **Database** | Standalone PostgreSQL | **PostgreSQL HA** (3 replicas, StatefulSet) |
| **Cache/Session** | Redis or Memcached | **Valkey Cluster** (Redis fork, 3 replicas) |

This means `kubectl get statefulsets --namespace=gitea` shows only:
- `gitea-postgresql-ha-postgresql` (3/3)
- `gitea-valkey-cluster` (3/3)

**No `statefulset/gitea`** — the Gitea app itself is now a Deployment.

---

## Q3: Script Fixes Required for Newer Gitea Chart

### Problem 1: `statefulset/gitea` → `deployment/gitea`

Multiple scripts had `statefulset/gitea` hardcoded. All needed changing to `deployment/gitea`:

| File | Status |
|---|---|
| `workloads/gitea/deploy` | ✅ Fixed |
| `workloads/gitea/admin/gitea` | ✅ Fixed |
| `workloads/gitea/admin/api` | ✅ Fixed |
| `workloads/gitea/admin/access-token` | ✅ Fixed |
| `workloads/gitea/shell` | ✅ Fixed |
| `workloads/gitea/git-init-internal` | ✅ Fixed |

### Problem 2: `su git` no longer works

The `gitea` CLI wrapper (`workloads/gitea/admin/gitea`) used `su git -c "gitea ..."` which fails with `"su: must be suid to work properly"` in newer containers. The container already runs as the `git` user, so `su` is unnecessary.

**Fix:** Changed `su git -c "gitea --quiet $*"` → `gitea $*` ✅

### Problem 3: `|| true` hides failures

The start script uses `|| true` on user/repo creation commands, so failures are silently swallowed. This meant all user creation and repo creation silently failed during initial runs.

### Script dependency chain

```
create-user ──────────→ gitea (CLI wrapper)     ← needed statefulset fix + su fix
create-user-repository → api → access-token     ← needed statefulset fix
create-org ────────────→ api → access-token      ← needed statefulset fix
create-org-repository ─→ api → access-token      ← needed statefulset fix
```

---

## Q4: Cluster YAML Files (management & edge1)

Each cluster has an `env` file and a `cluster.yaml` template. Variables get substituted via `envsubst` before passing to `kind create cluster`.

### Key differences

| Aspect | Management | Edge1 |
|---|---|---|
| API port | `31000` | `31001` |
| Dashboard port | `32000` | `32001` |
| Pod CIDR | `10.97.0.0/16` | `10.98.0.0/16` |
| Service CIDR | `10.197.0.0/16` | `10.198.0.0/16` |
| Gitea port (32100) | ✅ Yes | ❌ No |

- **Different ports** — both clusters run on the same host.
- **Different subnets** — both share the same Docker network, need non-overlapping CIDRs.
- **Gitea only on management** — edge1 just runs Config Sync which pulls from Gitea.

### Host port layout

```
localhost:31000 → management K8s API
localhost:31001 → edge1 K8s API
localhost:32000 → management Dashboard
localhost:32001 → edge1 Dashboard
localhost:32100 → management Gitea
```

---

## Q5: Accessing Gitea on a Remote Azure VM

KinD binds ports to `127.0.0.1` by default — not accessible from outside the VM.

### Recommended: SSH Port Forwarding

```bash
ssh -i /path/to/your-key.pem \
  -L 32100:localhost:32100 \
  -L 32000:localhost:32000 \
  -L 32001:localhost:32001 \
  <your-azure-user>@<azure-vm-public-ip>
```

Then open in your local browser:
- **Gitea**: `http://localhost:32100`
- **Management Dashboard**: `http://localhost:32000`
- **Edge1 Dashboard**: `http://localhost:32001`

> **Tip:** PEM file needs `chmod 400` permissions.

### Other options

| Method | Pros | Cons |
|---|---|---|
| **SSH Tunnel** ✅ | No config changes, secure | Keep SSH session open |
| **kubectl port-forward** | Per-service, flexible | Need Azure NSG change |
| **0.0.0.0 binding** (`_override`) | All ports accessible | Least secure, need NSG changes, recreate clusters |

---

## Q6: Gitea Sign-In Credentials

| User | Username | Password | Role | Source |
|---|---|---|---|---|
| Admin | `administrator` | `administrator` | Full admin | `workloads/gitea/_env` |
| Demo | `config-sync-developer` | `config-sync` | Regular user | `environments/config-sync-demo/_env` |

> **Note:** Due to the script issues (Q3), these users may have been auto-created by the Helm chart with different passwords. If login fails, reset passwords manually:

```bash
kubectl config use-context kind-management

# Reset admin password
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  gitea admin user change-password --username administrator --password administrator

# Reset demo user password
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  gitea admin user change-password --username config-sync-developer --password config-sync
```

### Creating users manually (if they don't exist)

```bash
# Admin user
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  gitea admin user create --username administrator --password administrator \
  --email administrator@gitea --admin --must-change-password=false

# Demo user
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  gitea admin user create --username config-sync-developer --password config-sync \
  --email config-sync-developer@gitea --must-change-password=false
```

### Creating the repo manually

```bash
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  curl --silent --fail "http://localhost:3000/api/v1/user/repos" \
  --user "config-sync-developer:config-sync" --request POST \
  --header 'Content-Type: application/json' \
  --data '{"name": "config-sync-demo", "default_branch": "main"}'
```

Or create it from the Gitea UI: Sign in → **"+"** → **"New Repository"** → Name: `config-sync-demo`, Branch: `main`.

---

## Q7: What Config Sync Installs

Config Sync is **not a Helm chart** — it's a single `kubectl apply` of a manifest YAML:

```bash
kubectl apply -f "https://github.com/GoogleContainerTools/kpt-config-sync/releases/download/v1.16.1/config-sync-manifest.yaml"
```

### Resources created on edge1

| Category | Resources |
|---|---|
| **Namespaces** | `config-management-system`, `config-management-monitoring`, `resource-group-system` |
| **CRDs (6)** | `RootSync`, `RepoSync`, `ClusterSelector`, `NamespaceSelector`, `ResourceGroup`, `Cluster` |
| **Deployments** | `reconciler-manager` (core), `otel-collector` (telemetry), `resource-group-controller-manager` |
| **RBAC** | ServiceAccounts, Roles, ClusterRoles, and bindings |
| **ConfigMaps** | OTel configs, reconciler manager config |
| **Other** | OTel service, container limit ranges |

### How it works

```
RootSync CR (points to Git repo)
    → reconciler-manager sees it
    → spawns a reconciler pod
    → pod polls the Git repo
    → applies/deletes K8s resources to match Git
    → resource-group-controller tracks what was applied
```

**Config Sync** is a GitOps tool by Google. In this demo: push YAML to the Gitea repo on management → Config Sync on edge1 automatically applies it.

---

## Q8: How exactly does Config Sync sync the Git repo to the edge1 cluster?

There are **two separate scripts** that work together. The `start` script sets up infrastructure; the `deploy` script does the actual syncing:

```
environments/config-sync-demo/start   ← Sets up clusters, Gitea, Config Sync (infrastructure)
environments/config-sync-demo/deploy  ← Pushes content to Git repo + tells Config Sync to sync it
```

### Step 1: `start` creates the infrastructure (already covered in Q1)

After `start` finishes, you have:
- **Management cluster**: Gitea running, empty repo `config-sync-demo` created
- **Edge1 cluster**: Config Sync installed (reconciler-manager running), but **no RootSync/RepoSync exists yet** — so Config Sync is idle, doing nothing

### Step 2: `deploy` does the actual syncing

**`environments/config-sync-demo/deploy`:**
```bash
#!/bin/bash
set -e

# ... env setup ...

# Step 2a: Push content to the Gitea repo
"$ROOT/workloads/gitea/git-init" "$GIT_USERNAME" "$GIT_PASSWORD" "$GIT_NAME" "$GIT_EMAIL" \
  "$HERE/work/deployment-repository" "$GIT_USERNAME" "$GIT_REPO"

# Step 2b: Tell Config Sync what to sync
"$ROOT/platforms/kind/use" edge1
kubectl apply -f "$HERE/work/root-sync.yaml"
```

---

### Step 2a: Push content to the Git repo (`git-init`)

The `git-init` script takes the `assets/deployment-repository/` folder (already templated into `work/deployment-repository/`) and pushes it as the initial commit to Gitea.

**`workloads/gitea/git-init`:**
```bash
TEMP_DIR=$(mktemp --directory)
cp --recursive "$DIR"/* "$TEMP_DIR/"       # Copy deployment-repository content
git -C "$TEMP_DIR" init --initial-branch=main
git -C "$TEMP_DIR" config user.name "$NAME"
git -C "$TEMP_DIR" config user.email "$EMAIL"
git -C "$TEMP_DIR" add .
git -C "$TEMP_DIR" commit --message='Initial commit'
git -C "$TEMP_DIR" remote add origin \
  "http://config-sync-developer:config-sync@<hostname>:32100/config-sync-developer/config-sync-demo.git"
git -C "$TEMP_DIR" push --force --set-upstream origin main
rm --recursive --force "$TEMP_DIR"
```

This is a standard `git init && commit && push` — it pushes from the **host machine** (Azure VM) to Gitea via the NodePort on 32100.

**What gets pushed** — the repo structure:

```
config-sync-demo (Gitea repo on management cluster)
├── root/
│   └── network-function.yaml      ← Namespace + RepoSync + RoleBinding
└── namespaces/
    └── network-function/
        └── deployment.yaml        ← An nginx Deployment
```

---

### Step 2b: Apply the RootSync to edge1 (`kubectl apply`)

After pushing content to the repo, the script switches to the edge1 cluster and applies:

**`work/root-sync.yaml`** (after envsubst):
```yaml
apiVersion: configsync.gke.io/v1beta1
kind: RootSync

metadata:
  name: config-sync-demo
  namespace: config-management-system    # RootSync MUST be in this namespace

spec:
  sourceFormat: unstructured
  git:
    repo: http://<hostname>:32100/config-sync-developer/config-sync-demo.git
    dir: /root                           # Only sync the /root directory
    branch: main
    auth: none                           # No Git authentication needed
```

This tells Config Sync: **"Watch the `/root` directory of this Git repo on the `main` branch, and apply whatever YAML files you find there to this cluster."**

---

### Step 3: What Config Sync does automatically (on edge1)

Once the RootSync CR exists, Config Sync takes over:

**3a. reconciler-manager sees the RootSync**

The `reconciler-manager` Deployment (installed by `config-sync/deploy`) watches for RootSync and RepoSync resources. When it sees the new `config-sync-demo` RootSync, it **spawns a new reconciler pod** specifically for this RootSync.

**3b. The reconciler pod polls `/root` in the Git repo**

The reconciler pod clones `http://<hostname>:32100/config-sync-developer/config-sync-demo.git` and looks at the `/root` directory. It finds one file:

**`root/network-function.yaml`** — which contains THREE resources:

```yaml
# Resource 1: A Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: network-function

---

# Resource 2: A RepoSync (tells Config Sync to also watch /namespaces/network-function/)
apiVersion: configsync.gke.io/v1beta1
kind: RepoSync
metadata:
  name: repo-sync
  namespace: network-function
spec:
  sourceFormat: unstructured
  git:
    repo: http://<hostname>:32100/config-sync-developer/config-sync-demo.git
    dir: /namespaces/network-function    # Watch THIS subdirectory too
    branch: main
    auth: none

---

# Resource 3: A RoleBinding (gives Config Sync permission to manage network-function namespace)
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: ns-reconciler-network-function
  namespace: network-function
subjects:
- kind: ServiceAccount
  name: ns-reconciler-network-function
  namespace: config-management-system
roleRef:
  kind: ClusterRole
  name: admin
  apiGroup: rbac.authorization.k8s.io
```

**3c. Config Sync applies these resources to edge1:**

1. ✅ Creates the `network-function` namespace
2. ✅ Creates the `RepoSync` in that namespace
3. ✅ Creates the `RoleBinding` to grant permissions

**3d. The RepoSync triggers a SECOND reconciler**

The `reconciler-manager` now sees the new `RepoSync` (in the `network-function` namespace) and spawns **another reconciler pod** to watch `/namespaces/network-function/` in the same Git repo.

**3e. The second reconciler syncs the namespace-level content**

It finds `namespaces/network-function/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: network-function
  namespace: network-function
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: network-function
  template:
    metadata:
      labels:
        app.kubernetes.io/name: network-function
    spec:
      containers:
      - name: nginx
        image: nginx:latest
```

Config Sync applies this → an nginx pod runs in the `network-function` namespace on edge1.

---

### The complete flow diagram

```
                 MANAGEMENT CLUSTER                    EDGE1 CLUSTER
                 ─────────────────                    ──────────────

    git-init pushes content to Gitea
                 │
                 ▼
    ┌──────────────────────────┐
    │  Gitea Git Repo          │
    │  config-sync-demo        │
    │  ├── root/               │         kubectl apply root-sync.yaml
    │  │   └── network-        │◄─────────────────────────────────────┐
    │  │       function.yaml   │                                      │
    │  └── namespaces/         │                                      │
    │      └── network-        │         ┌────────────────────────┐   │
    │          function/       │         │ RootSync CR            │───┘
    │          └── deploy-     │         │ (watches /root)        │
    │              ment.yaml   │         └──────────┬─────────────┘
    └──────────────────────────┘                    │
                 ▲                                  ▼
                 │                    reconciler-manager spawns pod
                 │                                  │
                 │                                  ▼
                 │                    Reconciler clones repo,
                 │                    reads /root directory
                 │                                  │
                 │                                  ▼
                 │                    Applies network-function.yaml:
                 │                    ├── Namespace "network-function"
                 │                    ├── RepoSync (watches /namespaces/network-function)
                 │                    └── RoleBinding
                 │                                  │
                 │                                  ▼
                 │                    reconciler-manager sees RepoSync,
                 │                    spawns SECOND reconciler pod
                 │                                  │
                 │◄─────────────────────────────────┘
                 │  clones repo again,
                 │  reads /namespaces/network-function
                 │
                 └──────────────────────────────────┐
                                                    │
                                                    ▼
                                      Applies deployment.yaml:
                                      └── Deployment "network-function"
                                          (nginx pod running!)
```

### Key concepts

| Concept | What it means |
|---|---|
| **RootSync** | Cluster-scoped sync — can create any resource anywhere (namespaces, cluster roles, etc.) |
| **RepoSync** | Namespace-scoped sync — can only create resources within ONE namespace |
| **`sourceFormat: unstructured`** | Treat the Git directory as a flat collection of YAML files (vs hierarchical) |
| **`dir: /root`** | Only sync files from this subdirectory of the repo |
| **`auth: none`** | Don't authenticate with the Git server (Gitea allows anonymous read in this setup) |
| **Two-level sync** | The RootSync creates a RepoSync, which triggers a second reconciler — this is the "multi-repo" pattern |

### How to verify it worked

After running `deploy`, wait a few minutes, then:

```bash
# Switch to edge1
platforms/kind/use edge1

# Check if the namespace was created
kubectl get namespace network-function

# Check if the nginx pod is running
kubectl get pods --namespace=network-function

# Check Config Sync status
kubectl get rootsyncs --namespace=config-management-system
kubectl get reposyncs --namespace=network-function
```

### Ongoing sync

After the initial sync, Config Sync **keeps polling the Git repo** (default: every 15 seconds). If you push new YAML files to the repo, Config Sync will automatically apply them. If you delete files from the repo, Config Sync will delete the corresponding resources from the cluster. That's GitOps!

---

## Q9: Gitea Fatal Error — `cache.Init failed: dial tcp 10.97.0.19:6379: i/o timeout`

### Context

When running `environments/porch-demo/start`, Gitea crashes with:

```
gitea routers/init.go:66:mustInit() [F] code.gitea.io/gitea/modules/cache.Init failed: dial tcp 10.97.0.19:6379: i/o timeout
```

### Root Cause

The `[F]` means **Fatal** — Gitea crashed at startup because it couldn't connect to its **Valkey (Redis fork) cluster** at `10.97.0.19:6379`.

In newer Gitea Helm chart versions (v12+), the cache/session backend changed from standalone Redis to **Valkey Cluster** (3 replicas as a StatefulSet). The IP `10.97.0.19` is the ClusterIP Service for Valkey. The `i/o timeout` means the Valkey pods haven't started yet — this is a **dependency ordering issue** where Gitea comes up before its cache backend is ready.

### How to fix

**Option 1 — Wait for Valkey to become ready (most common fix):**

Kubernetes will keep restarting the Gitea pod. Once Valkey is up, Gitea will connect on the next restart:

```bash
kubectl get pods --namespace=gitea --watch
kubectl get statefulsets --namespace=gitea
```

You should eventually see `gitea-valkey-cluster` at 3/3 replicas, then Gitea will start successfully.

**Option 2 — Investigate if Valkey pods are stuck:**

```bash
kubectl describe pod -l app.kubernetes.io/name=valkey-cluster --namespace=gitea
kubectl logs -l app.kubernetes.io/name=valkey-cluster --namespace=gitea --tail=50
```

Common reasons: insufficient CPU/memory in KinD cluster, PVC issues, image pull errors.

**Option 3 — Pin Gitea Helm chart to v9.6.1 (avoids Valkey entirely):**

Add `--version=9.6.1` to the `helm install` command in `workloads/gitea/deploy`. The old chart uses an embedded cache — no Redis/Valkey dependency, simpler for KinD environments.

```bash
helm install gitea gitea-charts/gitea --version=9.6.1 --namespace=gitea \
  --set=service.http.type=NodePort \
  --set=service.http.nodePort=32100
```

### Key takeaway

| Helm chart version | Cache backend | Dependency risk |
|---|---|---|
| ≤ v9.x | Embedded / SQLite | None — Gitea is self-contained |
| v12+ | Valkey Cluster (3 replicas) | Gitea crashes if Valkey isn't ready |

---

## Q10: Valkey Error — `Cluster is currently down: I am part of a minority partition`

### Context

Valkey (Redis fork) starts successfully — it loads config, reads RDB, and prints `Ready to accept connections tcp`. But then immediately reports:

```
Cluster is currently down: I am part of a minority partition.
```

This causes Gitea to fail with `dial tcp 10.97.0.19:6379: i/o timeout` (Q9).

### Root Cause

Valkey is deployed in **cluster mode** with 3 nodes. For the cluster to serve requests, a **majority quorum** (at least 2 out of 3 nodes) must be online and communicating. When a node can't reach the other nodes, it considers itself in a "minority partition" and **refuses all client connections** — even though the Valkey process itself is running fine.

```
Valkey Cluster (3 nodes)
├── Node 0: Running ✅, but alone → "minority partition" → refuses requests ❌
├── Node 1: Not yet ready / can't be reached
└── Node 2: Not yet ready / can't be reached
```

### Why this happens in KinD

1. **Other pods aren't ready yet** — still pulling images or initializing. Once all 3 are up, the cluster self-heals.
2. **Cluster topology never bootstrapped** — the Helm chart includes an init job that runs `CLUSTER MEET` to introduce nodes to each other. If this job failed, the nodes stay isolated.
3. **Resource pressure** — KinD nodes have limited CPU/memory; pods may be stuck in `Pending`.

### How to diagnose

```bash
# Check if all 3 Valkey pods are running
kubectl get pods -l app.kubernetes.io/name=valkey-cluster --namespace=gitea

# Check for init/bootstrap jobs
kubectl get jobs --namespace=gitea

# Check logs of the other Valkey nodes
kubectl logs gitea-valkey-cluster-1 --namespace=gitea --tail=20
kubectl logs gitea-valkey-cluster-2 --namespace=gitea --tail=20
```

### How to fix

- **Wait** — if other pods are still starting, the cluster will form once all nodes are up.
- **Pin Helm chart to v9.6.1** — eliminates Valkey entirely (recommended for KinD, see Q9 Option 3).

---

## Q11: Fixing Valkey Cluster — `cluster_known_nodes:1`, No Slots Assigned

### Diagnosis

All 3 Valkey pods are Running but **0/1 READY**. Checking from inside a pod:

```
$ valkey-cli cluster info
cluster_state:fail
cluster_slots_assigned:0
cluster_known_nodes:1        ← Each node only knows itself
cluster_size:0

$ valkey-cli cluster nodes
09033f... 10.97.0.22:6379 myself,master - 0 0 0 connected   ← Alone
```

**Cause:** The Helm chart's cluster initialization Job never ran (0 Jobs in namespace). The 3 Valkey nodes started independently but were never introduced to each other via `CLUSTER MEET`, and hash slots were never distributed.

### Fix: Manually bootstrap the cluster

```bash
# 1. Get current pod IPs (they may change if pods restarted)
kubectl get pods -l app.kubernetes.io/name=valkey-cluster --namespace=gitea -o wide

# 2. Use those IPs to create the cluster (replace IPs if different)
kubectl exec gitea-valkey-cluster-0 --namespace=gitea -- valkey-cli --cluster create \
  <NODE0_IP>:6379 \
  <NODE1_IP>:6379 \
  <NODE2_IP>:6379 \
  --cluster-yes
```

What `--cluster create` does:
1. Runs `CLUSTER MEET` to introduce all nodes to each other
2. Distributes all **16384 hash slots** evenly across the 3 nodes (~5461 slots each)
3. `--cluster-yes` auto-confirms without prompting

### Verify

```bash
# Should show cluster_state:ok, cluster_known_nodes:3, cluster_slots_assigned:16384
kubectl exec gitea-valkey-cluster-0 --namespace=gitea -- valkey-cli cluster info

# Pods should become 1/1 READY (readiness probe checks cluster_state)
kubectl get pods -l app.kubernetes.io/name=valkey-cluster --namespace=gitea

# Gitea should stop crash-looping after its next restart
kubectl get pods -l app.kubernetes.io/name=gitea --namespace=gitea --watch
```

### Why the init Job was missing

The Bitnami Valkey Cluster Helm chart normally includes an init Job (`gitea-valkey-cluster-cluster-create`) that runs after installation. Possible reasons it's missing:
- Helm hook failed silently (chart uses `post-install` hook, which runs only once)
- `|| true` in the deploy script swallowed the error
- Chart version incompatibility

---

## Q12: Porch Demo — Complete Flow

### What is this demo?

The porch-demo environment demonstrates **Porch** (a kpt package orchestration server) working with **Config Sync** (GitOps). It shows how kpt packages can be stored in Git repos, managed through Porch's lifecycle (Draft → Proposed → Published), and deployed to clusters via Config Sync.

### Architecture

```
┌─────────────────── MANAGEMENT CLUSTER ───────────────────┐    ┌──── EDGE1 CLUSTER ────┐
│                                                           │    │                        │
│  Gitea (Git server)          Porch (package server)       │    │  Config Sync           │
│  ├── blueprints repo         ├── Watches Git repos        │    │  ├── Watches Git repo  │
│  ├── edge1 (deployment) repo │  via Repository CRs        │    │  │   via RootSync CR   │
│  └── NodePort :32100         │ ├── PackageRevisions       │    │  └── Applies resources │
│                              │ └── PackageVariants        │    │                        │
└──────────────────────────────────────────────────────────┘    └────────────────────────┘
```

### `start` script — Step by step

| Step | What it does |
|---|---|
| **1. Source env** | Loads `_env` files: `GIT_USERNAME=porch-developer`, `GIT_PASSWORD=porch`, repos = `edge1`, `blueprints` |
| **2. Template assets** | `envsubst` copies `assets/` → `work/`, substituting `$GIT_HOST`, `$GIT_USERNAME`, etc. |
| **3. Create KinD clusters** | `platforms/kind/start management edge1` — two clusters with separate ports/subnets |
| **4. Deploy Gitea** | Helm chart on management cluster, NodePort 32100 |
| **5. Create Git user** | `porch-developer` / `porch` |
| **6. Create repos** | `edge1` (deployment) + `blueprints` (package store) |
| **7. Init repos** | Push initial content so Porch can use them (requires ≥1 commit) |
| **8. Deploy Porch** | Downloads blueprint from GitHub, `kubectl apply` on management cluster |
| **9. Register repos with Porch** | Creates 3 `Repository` CRs in `porch-demo` namespace |
| **10. Deploy Config Sync** | On edge1 cluster |

### Three `Repository` CRs registered with Porch

| Repository | Git source | Purpose |
|---|---|---|
| `edge1` | `gitea-http.gitea:3000/porch-developer/edge1.git` | **Deployment** repo (Config Sync syncs from here) |
| `blueprints` | `gitea-http.gitea:3000/porch-developer/blueprints.git` | **Internal blueprints** (reusable package templates) |
| `external-blueprints` | `github.com/nephio-project/free5gc-packages.git` | **External blueprints** (read-only, from Nephio) |

### Post-start scripts (run separately)

**`create-blueprint`** — Publishes a kpt package to the blueprints repo:
```
init draft → push content → propose → approve
  (Draft)      (Draft)      (Proposed)  (Published, tagged v1)
```

**`deploy-blueprint`** — Deploys a blueprint to edge1:
```
pull blueprint → mutate (set-namespace) → init new package in edge1 repo
→ push → propose → approve → apply RootSync on edge1
```

**`deploy-blueprint-variant`** — Uses `PackageVariantSet` for declarative deployment:
```
apply PackageVariantSet → Porch auto-creates PackageVariant → auto-creates draft
→ mutate → push → propose → approve → apply RootSync on edge1
```

### Porch package lifecycle

```
   ┌──────────┐     propose     ┌──────────┐     approve     ┌───────────┐
   │  Draft   │ ──────────────► │ Proposed  │ ──────────────► │ Published │
   └──────────┘                 └──────────┘                  └───────────┘
   Git branch:                  Git branch:                   Merged to main,
   drafts/pkg/v1               proposed/pkg/v1               tagged pkg/v1
```

### How Porch connects to Gitea (internal access)

Porch runs **inside** the management cluster, so it uses the **in-cluster Service DNS** (`gitea-http.gitea:3000`) — not the NodePort. This is why the `porch-repositories.yaml` uses `gitea-http.gitea:3000` while running scripts from the host use `localhost:32100`.

---

## Q13: Git Push 403 — Repos Never Created (Cascading Failure)

### Error

```
CreateUser: user already exists [name: porch-developer]
command terminated with exit code 22  (×4)
remote: Push to create is not enabled for users.
fatal: unable to access 'http://Nephio:32100/porch-developer/edge1.git/': The requested URL returned error: 403
```

### Root Cause — Cascading failure chain

```
Helm auto-created porch-developer user (different password)
  → access-token script tries basic auth with password "porch" → 401 Unauthorized
    → api script fails (exit 22) → repo creation never happens
      → git-init pushes to non-existent repo → "Push to create not enabled" → 403
```

The `create-user` returned "already exists" because the Helm chart pre-created the user. But the password doesn't match `porch` (from `_env`). The `create-user-repository` script uses `access-token` → `api` which authenticates with `porch-developer:porch` — that fails with HTTP 401/422, and `|| true` swallows it.

### About `Nephio:32100`

`HOST=$(hostname)` in the root `_env` — so `Nephio` is the Azure VM hostname. Changing to `localhost:32100` **won't fix the 403** — the real issue is the repos don't exist. The hostname is fine as long as it resolves on the VM.

### Fix

```bash
# 1. Reset password to match what scripts expect
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  gitea admin user change-password --username porch-developer --password porch

# 2. Create repos directly (using basic auth, bypasses token flow)
kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  curl --silent --fail "http://localhost:3000/api/v1/user/repos" \
  --user "porch-developer:porch" --request POST \
  --header 'Content-Type: application/json' \
  --data '{"name": "edge1", "default_branch": "main"}'

kubectl exec deployment/gitea --container=gitea --namespace=gitea -- \
  curl --silent --fail "http://localhost:3000/api/v1/user/repos" \
  --user "porch-developer:porch" --request POST \
  --header 'Content-Type: application/json' \
  --data '{"name": "blueprints", "default_branch": "main"}'

# 3. Then re-run git-init or the full start script
```

### The script dependency chain (with failure points)

```
start script
├── create-user "porch-developer" "porch"   → "already exists" (Helm created it) ← || true
├── create-user-repository                  → calls api → calls access-token
│   └── access-token tries --user "porch-developer:porch" → WRONG PASSWORD → exit 22 ← || true
├── git-init → git push to non-existent repo → "Push to create not enabled" → 403 ← CRASH
```

---

## Q14: Porch Server — What It Deploys & Timeout Error

### How `workloads/porch/deploy` works

```bash
# Downloads blueprint tarball from GitHub (once, cached in blueprint/)
URL=https://github.com/kptdev/kpt/releases/download/porch/v0.0.23/deployment-blueprint.tar.gz

kubectl apply -f "$HERE/blueprint/"    # Apply all YAMLs from tarball
kubectl wait deployment porch-server --for=condition=Available --namespace=porch-system
```

**Yes, it creates a `deployment/porch-server`** in `porch-system` namespace. The blueprint contains:

| Resource | Namespace | Purpose |
|---|---|---|
| `Namespace` | `porch-system` | Porch's namespace |
| `Deployment/porch-server` | `porch-system` | Porch API server (K8s extension API server) |
| `Deployment/porch-controllers` | `porch-system` | PackageVariant / PackageVariantSet controllers |
| `Deployment/function-runner` | `porch-system` | Executes kpt functions in containers |
| `Service/porch-server` | `porch-system` | Service for the API server |
| `APIService` | cluster-scoped | Registers Porch with K8s API aggregation layer |
| CRDs | cluster-scoped | `Repository`, `PackageRevision`, `PackageVariant`, etc. |

### The timeout error

```
error: timed out waiting for the condition on deployments/porch-server
```

`kubectl wait` has a **default 30-second timeout** — often insufficient for Porch to pull images and start on a KinD cluster.

### Diagnostic commands

```bash
kubectl get pods --namespace=porch-system
kubectl describe pod -l app=porch-server --namespace=porch-system
kubectl logs -l app=porch-server --namespace=porch-system --tail=30
kubectl get events --namespace=porch-system --sort-by='.lastTimestamp' | tail -20
```

### Common causes

1. **Image pull delay** — Porch images are large, KinD needs to download them from gcr.io
2. **cert-manager missing** — Porch may require cert-manager for TLS certificates
3. **Resource pressure** — Gitea + PostgreSQL HA + Valkey Cluster are already consuming a lot

---

## Q15: Porch Demo — What Is Deployed Where and Why

### The Big Picture

The porch-demo creates a **GitOps pipeline** using two clusters:

```
MANAGEMENT CLUSTER                         EDGE1 CLUSTER
(the "brain" — stores, manages,            (the "worker" — runs actual
 and orchestrates packages)                 workloads synced from Git)

┌─────────────────────────────┐           ┌─────────────────────────┐
│  Gitea        (Git server)  │           │  Config Sync            │
│  Porch        (pkg server)  │──Git──────│  (GitOps agent)         │
│  Repositories (3 CRs)      │           │                         │
│  Secret       (Git creds)   │           │  [workloads appear here │
│                             │           │   after deploy scripts] │
└─────────────────────────────┘           └─────────────────────────┘
```

---

### Management Cluster — Line by Line

#### 1. Gitea — Git Server (Line 19)

```bash
"$ROOT/workloads/gitea/deploy"
```

**What it deploys (namespace: `gitea`):**

| Resource | Details |
|---|---|
| `Deployment/gitea` | Gitea app (v1.25.4), NodePort 32100 |
| `StatefulSet/gitea-postgresql-ha-postgresql` | PostgreSQL HA (3 replicas) — Gitea's database |
| `Deployment/gitea-postgresql-ha-pgpool` | Connection pooler for PostgreSQL |
| `StatefulSet/gitea-valkey-cluster` | Valkey Cluster (3 replicas) — Gitea's cache/session store |
| PVCs (7 total) | Storage for PostgreSQL (3×10Gi) + Valkey (3×8Gi) + Gitea shared (10Gi) |

**Why:** Gitea is the **central Git server** where all kpt packages are stored. Both Porch (management cluster) and Config Sync (edge1 cluster) read from / write to these Git repos. It's the single source of truth.

#### 2. Create User + Repos (Lines 20–22)

```bash
"$ROOT/workloads/gitea/admin/create-user" "$GIT_USERNAME" "$GIT_PASSWORD" "$GIT_EMAIL" || true
"$ROOT/workloads/gitea/admin/create-user-repository" "$GIT_USERNAME" "$GIT_PASSWORD" "$GIT_DEPLOYMENT_REPO" || true
"$ROOT/workloads/gitea/admin/create-user-repository" "$GIT_USERNAME" "$GIT_PASSWORD" "$GIT_BLUEPRINTS_REPO" || true
```

**What it creates in Gitea:**

| Item | Value | Purpose |
|---|---|---|
| User | `porch-developer` / `porch-developer` | Identity for Git operations |
| Repo | `porch-developer/edge1` | **Deployment repo** — approved packages land here; Config Sync reads from here |
| Repo | `porch-developer/blueprints` | **Blueprints repo** — reusable package templates stored here |

**Why:** Porch needs Git repos to store packages. The "edge1" repo is a **deployment repo** (Config Sync will sync it to edge1). The "blueprints" repo is a **template library** (reusable packages that get cloned and customized for deployments).

#### 3. Git Init — Push Initial Commits (Lines 24–26)

```bash
"$ROOT/workloads/gitea/git-init" ... "$HERE/work/deployment-repository" ... "$GIT_DEPLOYMENT_REPO"
"$ROOT/workloads/gitea/git-init" ... "$HERE/work/blueprints-repository" ... "$GIT_BLUEPRINTS_REPO"
```

**What it pushes:**

- **edge1 repo** ← `assets/deployment-repository/root/` — contains placeholder YAMLs for Config Sync (RootSync watches `/root` directory)
- **blueprints repo** ← `assets/blueprints-repository/README.md` — just a README (needs ≥1 commit for Porch to work)

**Why:** Porch **refuses to register a completely empty Git repo** — it needs at least one commit to detect the branch. The deployment repo also needs the `/root` directory structure for Config Sync's RootSync to watch.

#### 4. Porch — Package Orchestration Server (Line 28)

```bash
"$ROOT/workloads/porch/deploy"
```

**What it deploys (namespace: `porch-system`):**

| Resource | Purpose |
|---|---|
| `Deployment/porch-server` | **The Porch API server** — extends K8s API with `PackageRevision`, `Repository`, etc. |
| `Deployment/porch-controllers` | **PackageVariant controller** + **PackageVariantSet controller** — automate package lifecycle |
| `Deployment/function-runner` | **Function runner** — executes kpt functions (set-namespace, etc.) in isolated containers |
| `APIService` | Registers Porch with K8s API aggregation layer so `kubectl get packagerevisions` works |
| CRDs | `Repository`, `PackageRevision`, `PackageRevisionResources`, `PackageVariant`, `PackageVariantSet` |
| RBAC | ServiceAccounts, ClusterRoles, Bindings |

**Why:** Porch is the **core of the demo**. It provides a Kubernetes-native API for managing kpt packages. Instead of manually running `git clone`, editing YAMLs, and `git push`, you interact with packages as Kubernetes resources (`kubectl get packagerevision`, `porchctl rpkg pull/push/propose/approve`). Porch handles the Git operations behind the scenes.

#### 5. Namespace + Secret + Repository CRs (Lines 31–39)

```bash
kubectl create namespace porch-demo || true

kubectl create secret generic gitea \
    --namespace=porch-demo \
    --type=kubernetes.io/basic-auth \
    --from-literal=username="$GIT_USERNAME" \
    --from-literal=password="$GIT_PASSWORD" || true

kubectl apply -f "$HERE/work/porch-repositories.yaml"
```

**What it creates (namespace: `porch-demo`):**

| Resource | Purpose |
|---|---|
| `Namespace/porch-demo` | Working namespace for this demo |
| `Secret/gitea` | Git credentials so Porch can read/write to Gitea repos |
| `Repository/edge1` | Tells Porch: "watch `gitea-http.gitea:3000/porch-developer/edge1.git`, it's a **deployment** repo" |
| `Repository/blueprints` | Tells Porch: "watch `gitea-http.gitea:3000/porch-developer/blueprints.git`, it's a **blueprints** repo" |
| `Repository/external-blueprints` | Tells Porch: "watch `github.com/nephio-project/free5gc-packages.git`, it's a **blueprints** repo (read-only)" |

**Why:**
- The **Secret** is needed because the Gitea repos require authentication (unlike the external GitHub repo which is public).
- The **Repository CRs** are how you "register" Git repos with Porch. Once registered, Porch polls them and creates a `PackageRevision` for every kpt package (every directory with a `Kptfile`) it finds. The `deployment: true` flag on the `edge1` repo tells Porch this is where finalized, ready-to-deploy packages go.
- The **external-blueprints** repo (Nephio's free5gc-packages) provides real-world blueprints you can pull from and customize.

---

### Edge1 Cluster — Line by Line

#### 6. Config Sync — GitOps Agent (Line 45)

```bash
"$ROOT/workloads/config-sync/deploy"
```

Which runs:
```bash
kubectl apply -f "https://github.com/GoogleContainerTools/kpt-config-sync/releases/download/v1.16.1/config-sync-manifest.yaml"
kubectl wait deployment/reconciler-manager --namespace=config-management-system --for=condition=Available --timeout=1h
```

**What it deploys (multiple namespaces):**

| Resource | Namespace | Purpose |
|---|---|---|
| `Deployment/reconciler-manager` | `config-management-system` | Core controller — watches RootSync/RepoSync, spawns reconciler pods |
| `Deployment/otel-collector` | `config-management-monitoring` | Telemetry collector (optional) |
| `Deployment/resource-group-controller-manager` | `resource-group-system` | Tracks which K8s resources were synced from Git |
| CRDs (6) | cluster-scoped | `RootSync`, `RepoSync`, `ClusterSelector`, `NamespaceSelector`, `ResourceGroup`, `Cluster` |
| RBAC, ConfigMaps, LimitRanges | various | Supporting infrastructure |

**Why:** Config Sync is the **GitOps delivery mechanism**. Once a package is approved in Porch and published to the `edge1` Git repo, someone needs to **actually apply those YAMLs to the edge1 cluster**. Config Sync does this automatically:

1. A `RootSync` CR is applied (later, by `deploy-blueprint` script) pointing at the `edge1` Git repo
2. Config Sync's reconciler-manager spawns a reconciler pod
3. The reconciler polls the Git repo every 15 seconds
4. Any YAML it finds gets `kubectl apply`'d to edge1
5. Any YAML removed from Git gets deleted from edge1

**Note:** Config Sync is idle after `start` finishes — no RootSync exists yet. It only starts syncing after you run `deploy-blueprint` or `deploy-blueprint-variant`.

---

### Why Two Clusters?

This simulates a **real production GitOps architecture:**

| | Management Cluster | Edge1 Cluster |
|---|---|---|
| **Role** | Control plane — stores packages, manages lifecycle | Data plane — runs actual workloads |
| **Analogy** | The "headquarters" | The "factory floor" |
| **Who writes** | Platform engineers (via Porch) | Nobody (Config Sync applies automatically) |
| **Who reads** | Porch reads/writes Git repos | Config Sync reads Git repo |
| **Key insight** | **Never runs user workloads** | **Never manages packages** |

In production (e.g., Nephio/5G), you'd have 1 management cluster and **hundreds** of edge clusters, each with Config Sync watching a different deployment repo (or different directory of the same repo).

### Complete resource map

```
MANAGEMENT CLUSTER (kind-management)
├── Namespace: gitea
│   ├── Deployment/gitea                        ← Git server
│   ├── StatefulSet/gitea-postgresql-ha (×3)    ← Database
│   ├── Deployment/gitea-postgresql-ha-pgpool   ← DB connection pool
│   ├── StatefulSet/gitea-valkey-cluster (×3)   ← Cache/session
│   └── PVCs (×7)                               ← Persistent storage
├── Namespace: porch-system
│   ├── Deployment/porch-server                 ← Package API server
│   ├── Deployment/porch-controllers            ← Package lifecycle automation
│   └── Deployment/function-runner              ← kpt function executor
├── Namespace: porch-demo
│   ├── Secret/gitea                            ← Git credentials
│   ├── Repository/edge1                        ← Deployment repo registration
│   ├── Repository/blueprints                   ← Internal blueprints registration
│   └── Repository/external-blueprints          ← Nephio blueprints registration
└── CRDs: Repository, PackageRevision, PackageVariant, etc.

EDGE1 CLUSTER (kind-edge1)
├── Namespace: config-management-system
│   └── Deployment/reconciler-manager           ← Core GitOps controller
├── Namespace: config-management-monitoring
│   └── Deployment/otel-collector               ← Telemetry
├── Namespace: resource-group-system
│   └── Deployment/resource-group-controller    ← Resource tracking
├── CRDs: RootSync, RepoSync, etc.
└── [empty until deploy-blueprint runs]
```

---

## Q16: Why are there so many Package Revisions and what do the columns mean?

### The Output Explained

When you ran `environments/porch-demo/start`, you saw a huge list of `PackageRevisions`. Even though you only saw 2 repos ("edge1" and "blueprints") in your local Gitea instance, **Porch registered a third repository that points to the public internet**.

Look closely at the `REPOSITORY` column in your output:
```
NAMESPACE    NAME                                          PACKAGE             ...  REPOSITORY
porch-demo   external-blueprints-00b6673...                pkg-example-smf-bp  ...  external-blueprints
porch-demo   external-blueprints-3bd78e...                 pkg-example-smf-bp  ...  external-blueprints
...
```

**ALL of those packages came from the `external-blueprints` repository.**

### Where did `external-blueprints` come from?

In the `start` script, it applied `assets/porch-repositories.yaml`, which contained **three** `Repository` resources:

1. `edge1` (internal Gitea)
2. `blueprints` (internal Gitea)
3. **`external-blueprints`** (external GitHub)

Here is the exact YAML that was applied for the third one:
```yaml
apiVersion: config.porch.kpt.dev/v1alpha1
kind: Repository
metadata:
  name: external-blueprints
  namespace: porch-demo
spec:
  description: External blueprints
  content: Package
  deployment: false
  type: git
  git:
    repo: https://github.com/nephio-project/free5gc-packages.git
    directory: /
    branch: main
```

**What happened:** Porch connected to that public GitHub repo (`nephio-project/free5gc-packages`), scanned it, and found numerous Kpt packages (with different versions/tags like `v1`, `v2`, `main`). For *every single version* of *every single package* it found in that Github repo, Porch created a `PackageRevision` object in your cluster. That's why your list is so long!

### Understanding the Columns

When you run `kubectl get packagerevision` (or `porchctl rpkg get`), here is what the columns mean:

#### 1. `REPOSITORY`
This is the **name of the `Repository` Custom Resource** in Porch that points to the actual Git URL.
- E.g., `external-blueprints` points to `https://github.com/nephio-project/free5gc-packages.git`.

#### 2. `PACKAGE`
This is the **name of the kpt package** as defined inside the `Kptfile` of that directory.
- A single Git repository can contain *many* different packages in different subdirectories.
- E.g., `pkg-example-smf-bp`, `free5gc-operator`, `free5gc-upf`.

#### 3. `FILES`
This is the **number of YAML files** contained inside that specific version of the kpt package.
- When Porch reads the Git repo, it counts the configuration files that make up that package.
- E.g., `17` means there are 17 separate YAML files (deployments, services, configmaps, etc.) that define that specific blueprint.

### Summary
You didn't accidentally deploy these to your cluster's workloads. Porch just **indexed** them. They are sitting in Porch's database as available "blueprints" that you *could* choose to clone, mutate, and deploy to your `edge1` repo later if you wanted to.

---

## Q17: Explaining the Porch CLI commands from the README

You asked about these three lines from `environments/porch-demo/README.md`:

```bash
BLUEPRINT=$(workloads/porch/package-revision-name porch-demo external-blueprints free5gc-operator)
kubectl get packagerevisionresources "$BLUEPRINT" --namespace=porch-demo --output=jsonpath="{range .spec.resources.*}{'---\n'}{@}{end}"
porchctl rpkg pull "$BLUEPRINT" --namespace=porch-demo
```

These commands demonstrate how to interact with Porch to find a package, view its actual YAML contents (without downloading it), and then finally download it locally.

### 1. Finding the exact PackageRevision name

```bash
BLUEPRINT=$(workloads/porch/package-revision-name porch-demo external-blueprints free5gc-operator)
```

**What it does:** Looks up the auto-generated Kubernetes resource name for a specific kpt package and saves it in the `BLUEPRINT` variable.

**Why it's needed:** When Porch discovers packages in Git, it generates long unique IDs for them (e.g., `external-blueprints-9fee880e8fa...`). Since you can't guess that string, the helper script `package-revision-name` queries the Kubernetes API using field selectors to say:
*"Find the `PackageRevision` in the `porch-demo` namespace, originating from the `external-blueprints` repository, where the package name is `free5gc-operator`, and grab the name of its latest available version (the `kpt.dev/latest-revision=true` label)."*

### 2. Viewing the YAMLs stored inside Porch

```bash
kubectl get packagerevisionresources "$BLUEPRINT" --namespace=porch-demo --output=jsonpath="{range .spec.resources.*}{'---\n'}{@}{end}"
```

**What it does:** Prints the actual raw YAML contents of the package directly to your terminal.

**How it works:** `PackageRevisionResources` is a special API endpoint provided by the Porch extension server. It doesn't just hold metadata; it holds the *actual file contents* of the package as a map of `filename: yaml-content`. 
The magical-looking `--output=jsonpath` part loops through every file inside `spec.resources`, prints a `---` separator, and then prints the YAML content. This lets you inspect the blueprints without ever installing `kpt` or using git.

### 3. Pulling the package locally

```bash
porchctl rpkg pull "$BLUEPRINT" --namespace=porch-demo
```

**What it does:** Downloads the kpt package from Porch into a local directory on your machine.

**Why:** Once you've inspected the `PackageRevisionResources` and decided you want to use or edit this package, `porchctl rpkg pull` fetches all the YAML files and saves them to a local `free5gc-operator/` folder. This is the equivalent of doing a `git clone`, but routed entirely through the Kubernetes/Porch API instead of talking to the Git server directly.

---

## Q18: What is the difference between a "Blueprint" and "Deployment" repository?

In the Porch / Config Sync ecosystem, repositories serve two entirely different purposes. Think of them as the **"Library"** vs the **"Execution Plan."**

### 1. Blueprint Repository (The "Library")

- **Purpose:** To store raw, reusable kpt package templates (the blueprints).
- **Contents:** YAML manifests with placeholders, configuration options (`Kptfile`), and generic settings. These packages are **not ready to be deployed** to a cluster yet.
- **Analogy:** It's like an architecture blueprint or a cookie cutter. You don't live in the blueprint, you use it to build houses.
- **Deployment Status:** In `porch-repositories.yaml`, these have `deployment: false`.
- **Examples in Demo:** 
  - `blueprints` (Internal Gitea) - where you author and save your own packages.
  - `external-blueprints` (Public GitHub) - where you pull pre-written packages from open-source projects (like Nephio).

### 2. Deployment Repository (The "Execution Plan")

- **Purpose:** To hold the localized, production-ready, customized versions of packages that correspond to a specific Kubernetes cluster.
- **Contents:** Concrete YAML manifests where all the blanks have been filled in, IP addresses set, specific namespaces assigned (e.g., via the `set-namespace` kpt function), and site-specific values configured.
- **Analogy:** It is the actual baked cookie, ready to be eaten.
- **Deployment Status:** In `porch-repositories.yaml`, these have `deployment: true`.
- **Who reads it:** **Config Sync** (the GitOps agent on the edge cluster). Config Sync watches this repository and continuously runs `kubectl apply` on everything inside it.
- **Example in Demo:** 
  - `edge1` (Internal Gitea) - This repo maps 1:1 to the `edge1` KinD cluster. Whatever goes in here, runs on edge1.

### The Workflow Connecting Them

The entire Porch workflow is about moving packages from the Blueprint repo to the Deployment repo:

1. **Pull** a generic template from the Blueprint repo.
2. **Mutate** it for your specific target (e.g., change the namespace to `network-function-a`, set resource limits).
3. **Push/Propose/Approve** the customized package into the Deployment repo (e.g., `edge1`).
4. **Deploy:** Config Sync sees the new package in the Deployment repo and instantly applies it to the cluster.

If you tried to make Config Sync watch a Blueprint repository directly, it would fail or deploy broken services because the templates aren't fully configured yet.

---
