# Colima Networking Requirement for NAS-Backed MinIO Storage

When running the `uds-k3d` development cluster on macOS with Colima, the Colima VM must be able to reach the NAS directly for Docker-managed NFS volumes to work correctly.

## Problem

The cluster may appear healthy while MinIO operations hang or eventually fail. For example:

```sh
mc ls local/zarf-registry
mc mb local/zarf-registry
```

may take several seconds and eventually return an error similar to:

```text
mc: <ERROR> Unable to make bucket `local/zarf-registry`.
Resource requested is unwritable, please reduce your request rate
```

Meanwhile, the MinIO pod itself can misleadingly appear healthy:

```text
uds-dev-stack   minio-...   1/1   Running
```

and the MinIO readiness endpoint may still return HTTP 200:

```sh
curl http://127.0.0.1:9000/minio/health/ready
```

## Root Cause

Check the MinIO logs:

```sh
kubectl logs -n uds-dev-stack deploy/minio --tail=100
```

A storage connectivity problem appears as errors such as:

```text
no online disks found in (set:0 pool:0)
Read failed. Insufficient number of drives online
```

In this setup, the MinIO PVC uses the `local-path` StorageClass:

```text
MinIO /export
    ↓
PVC: minio
    ↓
local-path PV
    ↓
/opt/local-path-provisioner-rwx/...
    ↓
Docker volume: uds-dev-nfs
    ↓
NFS
    ↓
QNAP NAS
```

The Docker volume is configured similarly to:

```sh
docker volume create --driver local \
  --opt type=nfs \
  --opt o=addr=192.168.1.55,nfsvers=4,rw \
  --opt device=:/uds-dev \
  uds-dev-nfs
```

and is mounted into the k3d server with:

```yaml
K3D_EXTRA_ARGS: "--volume uds-dev-nfs:/opt/local-path-provisioner-rwx@server:*"
```

Docker runs inside the Colima Linux VM, so **Colima—not macOS—is the machine actually performing the NFS mount**.

The NAS can therefore be reachable from macOS:

```sh
nc -vz 192.168.1.55 2049
```

while being unreachable from Colima:

```sh
colima ssh -- bash -c 'echo >/dev/tcp/192.168.1.55/2049'
```

This results in a stalled NFS filesystem. Commands that touch it may even hang:

```sh
docker exec k3d-uds-server-0 \
  df -h /opt/local-path-provisioner-rwx
```

## Colima Fix

By default, Colima may be configured with:

```yaml
network:
  address: false
  mode: shared
```

For this NAS-backed configuration, enable a reachable network address for the Colima VM.

Restart Colima with:

```sh
colima stop
colima start --network-address
```

The corresponding persistent Colima configuration should have:

```yaml
network:
  address: true
  mode: shared
```

The configuration is located at:

```text
~/.colima/default/colima.yaml
```

## Verify

First verify that Colima can reach NFS on the NAS:

```sh
colima ssh -- bash -c \
  'echo >/dev/tcp/192.168.1.55/2049 && echo "NFS reachable"'
```

Expected:

```text
NFS reachable
```

Then verify that the k3d node sees the NFS filesystem:

```sh
docker exec k3d-uds-server-0 \
  df -h /opt/local-path-provisioner-rwx
```

Example healthy output:

```text
Filesystem     Size  Used Avail Use% Mounted on
:/uds-dev      1.8T  205M  1.8T   1% /opt/local-path-provisioner-rwx
```

You can also determine the actual MinIO PV path:

```sh
VOL=$(kubectl get pvc -n uds-dev-stack minio -o jsonpath='{.spec.volumeName}')
kubectl get pv "$VOL" -o jsonpath='{.spec.hostPath.path}{"\n"}'
```

Example:

```text
/opt/local-path-provisioner-rwx/pvc-a44219c7-d095-4560-866c-d879764c35bc_uds-dev-stack_minio
```

Finally, MinIO bucket operations should work normally:

```sh
mc mb local/zarf-registry
```

and the complete setup task should succeed:

```sh
uds run setup-zarf-registry-minio-backend
```

## Troubleshooting Notes

During troubleshooting, `mc` operations such as:

```sh
mc ls local/zarf-registry
```

appeared to hang. This initially looked like a MinIO Client, terminal, pager, or UDS task-runner problem.

However, debugging the MinIO Client showed that it could successfully connect to MinIO and receive HTTP responses. The actual failure became clear from the MinIO server logs:

```text
no online disks found in (set:0 pool:0)
Read failed. Insufficient number of drives online
```

The MinIO Client was waiting/retrying because MinIO could not access its backing storage.

Another useful diagnostic was:

```sh
docker exec k3d-uds-server-0 \
  df -h /opt/local-path-provisioner-rwx
```

When the NFS connection was broken, this command itself hung. That immediately indicated a filesystem/storage problem below Kubernetes and MinIO.

The Docker NFS volume configuration could still look completely correct:

```sh
docker volume inspect uds-dev-nfs
```

Example:

```json
{
  "Driver": "local",
  "Name": "uds-dev-nfs",
  "Options": {
    "device": ":/uds-dev",
    "o": "addr=192.168.1.55,nfsvers=4,rw",
    "type": "nfs"
  }
}
```

Likewise, Kubernetes could report the MinIO PVC as healthy:

```sh
kubectl get pvc -n uds-dev-stack minio -o wide
```

with:

```text
NAME    STATUS   CAPACITY   ACCESS MODES   STORAGECLASS
minio   Bound    50Gi       RWO            local-path
```

A `Bound` PVC only means Kubernetes successfully associated the PVC with a PV. It does **not** prove the filesystem behind that PV is operational.

## Testing NAS Connectivity

The Mac itself could successfully reach NFS:

```sh
nc -vz 192.168.1.55 2049
```

Result:

```text
Connection to 192.168.1.55 port 2049 [tcp/nfsd] succeeded!
```

But the same connection from Colima failed:

```sh
colima ssh -- bash -c \
  'echo >/dev/tcp/192.168.1.55/2049 && echo "NFS reachable"'
```

with:

```text
connect: Connection refused
```

This distinction is important because Docker is running inside Colima. Testing connectivity only from macOS is insufficient.

Colima's route itself appeared valid:

```sh
colima ssh -- ip route get 192.168.1.55
```

Example:

```text
192.168.1.55 via 192.168.5.2 dev eth0 src 192.168.5.1
```

Colima could also reach other LAN systems, proving that general LAN connectivity was functional.

The issue was resolved by enabling Colima's reachable network address:

```sh
colima stop
colima start --network-address
```

Afterward, the NFS connectivity test succeeded:

```text
NFS reachable
```

and the k3d server immediately saw the NAS-backed filesystem:

```text
:/uds-dev       1.8T  205M  1.8T   1% /opt/local-path-provisioner-rwx
```

The MinIO setup task then completed successfully.

## Important Diagnostic Lesson

A Kubernetes PVC being `Bound`, a MinIO pod being `Running`, and even the MinIO readiness endpoint returning `200 OK` **do not prove that MinIO's backing storage is usable**.

For this architecture, the complete storage path is:

```text
macOS
  ↓
Colima VM
  ↓
Docker Engine
  ↓
Docker NFS volume (uds-dev-nfs)
  ↓
QNAP NFS export (:/uds-dev)
  ↓
k3d server mount (/opt/local-path-provisioner-rwx)
  ↓
local-path PV
  ↓
MinIO PVC
  ↓
MinIO /export
```

When MinIO reports `no online disks`, verify this path from the bottom up.

A particularly useful first check is:

```sh
docker exec k3d-uds-server-0 \
  df -h /opt/local-path-provisioner-rwx
```

If that command hangs, investigate the **Colima-to-NAS NFS connection** before debugging MinIO, Kubernetes PVCs, the MinIO Client, or UDS tasks.

For this setup, verify that Colima has:

```yaml
network:
  address: true
  mode: shared
```

or start it explicitly with:

```sh
colima start --network-address
```