# NAS-backed persistence in uds-k3d (k3d/k3s on macOS)

This repo’s `uds-k3d` dev cluster normally provisions PVs using the **local-path** provisioner (a `hostPath`-backed StorageClass inside the k3d server node).

If you want PV data to live on a NAS (QNAP, etc.) via NFS **without rebuilding the k3d node image**, the reliable pattern on macOS is:

1. **Mount NFS via a Docker volume** (Docker Desktop’s Linux VM does the NFS mount).
2. **Bind-mount that Docker volume into the k3d server node** at the directory(ies) the local-path provisioner uses.
3. Optionally create a **named StorageClass** (e.g. `nfs-client`) to make intent explicit.

This avoids the common k3d issue where the k3s node container does **not** include `mount.nfs` / `nfs-utils`, which breaks “in-cluster” NFS provisioners/CSI drivers.

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
  --opt device=:/uds-local \
  uds-local-nfs

docker volume inspect uds-local-nfs
```

### 2) Mount the Docker NFS volume into the k3d server node

Edit `configs/uds-dev.yaml` and extend `K3D_EXTRA_ARGS`:

```yaml
package:
  deploy:
    set:
      K3D_EXTRA_ARGS: "--k3s-arg --tls-san=192.168.1.61@server:* \
        --volume uds-local-nfs:/var/lib/rancher/k3s/storage@server:* \
        --volume uds-local-nfs:/opt/local-path-provisioner-rwx@server:*"
```

Why mount both paths?
- `/var/lib/rancher/k3s/storage` is the conventional k3s local-path location.
- This uds-k3d dev stack uses a directory like `/opt/local-path-provisioner-rwx` for PV data, so you must ensure *that* path is on NFS too.

### 3) Recreate/redeploy the cluster

```sh
uds run deploy --set CONFIG_FILE=configs/uds-dev.yaml
```

Verify from inside the server node:

```sh
SERVER_NODE=$(k3d node list -o json | jq -r '.[] | select(.role=="server") | .name' | head -n1)

docker exec "$SERVER_NODE" sh -lc 'mount | grep -E "(/var/lib/rancher/k3s/storage|/opt/local-path-provisioner-rwx)"'
docker exec "$SERVER_NODE" sh -lc 'df -h /var/lib/rancher/k3s/storage /opt/local-path-provisioner-rwx'
```

You should see `:/uds-local` mounted at both paths.

---

## Optional: create a named StorageClass (`nfs-client`)

Even though the provisioner is still `rancher.io/local-path`, having a specific StorageClass name is useful:
- Makes charts/values files explicit ("this PVC is intended to persist on NAS")
- Lets you change defaults later without editing every workload

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
