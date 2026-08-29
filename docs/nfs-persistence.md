# NAS-backed persistence in uds-k3d (k3d/k3s on macOS)

This repo’s `uds-k3d` dev cluster normally provisions PVs using the **local-path** provisioner (a `hostPath`-backed StorageClass inside the k3d server node).

If you want PV data to live on a NAS (QNAP, etc.) via NFS **without rebuilding the k3d node image**, the reliable pattern on macOS is:

1. **Mount NFS via a Docker volume** (on this machine: **Colima’s Linux VM** performs the NFS mount).
2. **Bind-mount that Docker volume into the k3d server node** at the directory the local-path provisioner uses for PV directories.

This approach keeps Kubernetes using the existing `rancher.io/local-path` provisioner, but swaps the underlying filesystem for NAS-backed storage.

Optional:
- Create a **named StorageClass** (e.g. `nfs-client`) to make intent explicit (but it is not required if everything can just keep using the default `local-path`).

This avoids the common k3d issue where the k3s node container does **not** include `mount.nfs` / `nfs-utils`, which breaks “in-cluster” NFS provisioners/CSI drivers. Instead, the NFS mount is performed by the container runtime (Colima VM) and presented to the k3d node as a ready-to-use filesystem.

---

## Why not `nfs-subdir-external-provisioner`?

`nfs-subdir-external-provisioner` is a Helm chart that can dynamically create subdirectories on an NFS share and provision PVs.

In k3d/k3s, it often fails because **the node needs to perform an NFS mount** and the node image frequently lacks the required mount helper.

Instead, we let Docker handle the NFS mount and keep Kubernetes using local-path.

---

## Step-by-step

### 1) Create the Docker NFS volume (NAS mount)

Example (QNAP at `192.168.1.55`, export `:/uds-local`, NFSv4):

```sh
docker volume create --driver local \
  --opt type=nfs \
  --opt o=addr=192.168.1.55,nfsvers=4,rw \
  --opt device=:/uds-dev \
  uds-dev-nfs

docker volume inspect uds-dev-nfs
```

### 2) Mount the Docker NFS volume into the k3d server node

Edit `configs/uds-dev.yaml` and extend `K3D_EXTRA_ARGS`.

**Recommended (current uds-k3d behavior): mount the path that the local-path provisioner actually uses.**

This dev stack configures the local-path provisioner with:

- `sharedFileSystemPath: /opt/local-path-provisioner-rwx`

So mount your NAS-backed Docker volume there:

```yaml
package:
  deploy:
    set:
      K3D_EXTRA_ARGS: "--k3s-arg --tls-san=192.168.1.61@server:* \
        --volume uds-local-nfs:/opt/local-path-provisioner-rwx@server:*"
```

Optional: you *can* also mount `/var/lib/rancher/k3s/storage` if you want to keep compatibility with the conventional k3s location, but it is not required for this repo’s default local-path configuration.

### 3) Recreate/redeploy the cluster

```sh
uds run deploy --set CONFIG_FILE=configs/uds-dev.yaml
```

Verify from inside the server node:

```sh
SERVER_NODE=$(k3d node list -o json | jq -r '.[] | select(.role=="server") | .name' | head -n1)

docker exec "$SERVER_NODE" sh -lc 'mount | grep -E "(/opt/local-path-provisioner-rwx)"'
docker exec "$SERVER_NODE" sh -lc 'df -h /opt/local-path-provisioner-rwx'
```

You should see the NFS export (e.g. `:/uds-local`) mounted at `/opt/local-path-provisioner-rwx`.

---

## Optional: create a named StorageClass (`nfs-client`)

**You do not need a second StorageClass** if your goal is simply: “make the default `local-path` persistent via the NAS mount”. Once `/opt/local-path-provisioner-rwx` is backed by NFS, the default `local-path` StorageClass will place PV data on the NAS automatically.

However, creating a second StorageClass can still be useful as a semantic label:
- makes charts/values files explicit ("this PVC is intended to persist on NAS")
- gives you an easy switch later (e.g., if you ever re-introduce a truly-local/non-NFS backing path)

Important: with the current `sharedFileSystemPath` configuration, both `local-path` and `nfs-client` will still provision under `/opt/local-path-provisioner-rwx` unless you run a second provisioner with a different config.

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
```

---

## Migrating a Helm-managed app (example: MinIO) to a different StorageClass

### Key rule: you generally cannot change `spec.storageClassName` on an existing PVC

So for many charts you must:
1. Stop the workload (scale to 0)
2. Delete the PVC (data loss unless you backed it up / moved it)
3. Upgrade Helm values to request the new StorageClass
4. Start the workload again

Example for MinIO (dev):

```sh
# stop the workload
kubectl -n uds-dev-stack scale deploy/minio --replicas=0
kubectl -n uds-dev-stack rollout status deploy/minio

# delete the old claim (WARNING: deletes stored data)
kubectl -n uds-dev-stack delete pvc minio

# ensure repo exists
helm repo add minio https://charts.min.io/
helm repo update

# set storage class explicitly
helm -n uds-dev-stack upgrade minio minio/minio \
  --reuse-values \
  --set persistence.storageClass=nfs-client

# restart
kubectl -n uds-dev-stack scale deploy/minio --replicas=1
kubectl -n uds-dev-stack rollout status deploy/minio

kubectl -n uds-dev-stack get pvc minio -o wide
```

### Verify it’s on the NAS

```sh
VOL=$(kubectl -n uds-dev-stack get pvc minio -o jsonpath='{.spec.volumeName}')
PV_PATH=$(kubectl get pv "$VOL" -o jsonpath='{.spec.hostPath.path}')

SERVER_NODE=$(k3d node list -o json | jq -r '.[] | select(.role=="server") | .name' | head -n1)

docker exec "$SERVER_NODE" sh -lc "df -h '$PV_PATH'"
```

If `df` reports the NFS filesystem (`:/uds-local`) at that path, the PV is NAS-backed.

---

## Operational notes / safety

- **Scaling to 0 before deleting a PVC** prevents the app from writing while you’re swapping the claim and avoids race conditions.
- Prefer **`Delete` reclaimPolicy** only for dev; for anything you care about, consider `Retain` and explicit cleanup.
- For real migration (no data loss), you need a data-copy step (rsync/job) or an app-level backup/restore.

---

## Colima NFS Routing: `preferredRoute` Is Required

Enabling a reachable Colima network address with:

```sh
colima start --network-address
```

or:

```yaml
network:
  address: true
```

is not sufficient by itself for reliable access to the NAS-backed NFS storage.

### Symptom

After initially fixing Colima-to-NAS connectivity, NFS became unreachable again:

```sh
colima ssh -- bash -c 'echo >/dev/tcp/192.168.1.55/2049 && echo "NFS reachable"'
```

returned:

```text
connect: Connection refused
```

The NFS-backed filesystem inside the k3d node consequently stalled:

```sh
docker exec k3d-uds-server-0 df -h /opt/local-path-provisioner-rwx
```

This propagated upward into MinIO:

```text
no online disks found in (set:0 pool:0)
Read failed. Insufficient number of drives online
```

and eventually caused the Zarf registry's S3 storage health checks to fail:

```text
storage driver health check: s3aws: InternalError
cause(listPathRaw: 0 drives provided)
status code: 500
```

This prevented Zarf from successfully bootstrapping the final registry.

### Root Cause

With `network.address: true`, Colima had two network interfaces:

```text
eth0   192.168.5.1/24
col0   192.168.64.2/24
```

`col0` is the additional reachable interface created by enabling the Colima network address.

However, the Colima configuration still contained:

```yaml
network:
  address: true
  mode: shared
  preferredRoute: false
```

Checking the route to the NAS showed that Colima was still sending the traffic through the original shared/NAT interface:

```sh
colima ssh -- ip route get 192.168.1.55
```

Result:

```text
192.168.1.55 via 192.168.5.2 dev eth0 src 192.168.5.1
```

Therefore, although `col0` existed, it was not being used for traffic to the NAS.

### Fix

Configure Colima to use the reachable interface as its preferred route:

```yaml
network:
  address: true
  mode: shared
  interface: en0
  preferredRoute: true
```

The configuration is stored at:

```text
~/.colima/default/colima.yaml
```

After making the change, restart Colima:

```sh
colima restart
```

### Verify the Route

Check the route to the NAS:

```sh
colima ssh -- ip route get 192.168.1.55
```

The healthy route should now use `col0`:

```text
192.168.1.55 via 192.168.64.1 dev col0 src 192.168.64.2
```

rather than:

```text
192.168.1.55 via 192.168.5.2 dev eth0 src 192.168.5.1
```

### Verify NFS

Test NFS connectivity directly from Colima:

```sh
colima ssh -- bash -c \
  'echo >/dev/tcp/192.168.1.55/2049 && echo "NFS reachable"'
```

Expected:

```text
NFS reachable
```

Then verify the NFS-backed filesystem from inside the k3d server:

```sh
docker exec k3d-uds-server-0 \
  df -h /opt/local-path-provisioner-rwx
```

Expected:

```text
Filesystem      Size  Used Avail Use% Mounted on
:/uds-dev       1.8T  205M  1.8T   1% /opt/local-path-provisioner-rwx
```

### Final Colima Configuration

For this NAS-backed k3d environment, the important Colima settings are:

```yaml
network:
  address: true
  mode: shared
  interface: en0
  preferredRoute: true
```

The distinction between `address` and `preferredRoute` is important:

- `address: true` creates the additional reachable `col0` interface.
- `preferredRoute: true` causes Colima to actually prefer that interface for outbound traffic such as connections to the NAS.

Without `preferredRoute: true`, the correct interface can exist while NFS traffic continues to use the wrong route.

### Quick Diagnostic

If MinIO reports `no online disks` or Zarf registry S3 operations begin failing, check these two commands first:

```sh
colima ssh -- ip route get 192.168.1.55
```

and:

```sh
docker exec k3d-uds-server-0 \
  df -h /opt/local-path-provisioner-rwx
```

The NAS route should use `col0`, and the `df` command should immediately report the `:/uds-dev` NFS filesystem. If `df` stalls, troubleshoot Colima-to-NAS connectivity before debugging MinIO or Zarf.
