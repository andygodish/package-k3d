# Ephemeral UDS Dev Cluster Persistence and Blue/Green Migration

## Purpose

The UDS k3d development clusters are intentionally ephemeral. Kubernetes
nodes and cluster infrastructure are not upgraded in place. When a
Kubernetes, k3s, UDS, or other significant platform upgrade is required,
a new cluster is created and the old cluster is eventually destroyed.

Long-term persistence should therefore **not depend on the lifetime of a
particular k3d cluster, Kubernetes PV, PVC UUID, or node filesystem**.

The persistence model is:

-   `uds-dev` and `uds-dev-2` are disposable working environments.
-   `uds-dev-backups` is the durable backup location.
-   Stateful application data is backed up from whichever environment is
    currently live.
-   A replacement cluster is built from scratch and restored from the
    durable backup.
-   The old and new clusters coexist during validation and rollback.
-   Only after the replacement is verified is the old cluster destroyed.

This is effectively a small blue/green infrastructure model for the
homelab.

------------------------------------------------------------------------

## Storage Layout

The QNAP provides separate shares for the two working environments and
for backups:

``` text
QNAP
├── dev/
│   ├── uds-dev/
│   └── uds-dev-2/
│
└── backups/
    └── uds-dev-backups/
```

The working environment storage and backup storage should reside on
different physical disks/storage pools where practical.

### Roles

  Location            Purpose
  ------------------- --------------------------------------------------
  `uds-dev`           One disposable UDS/k3d environment
  `uds-dev-2`         Second disposable UDS/k3d environment
  `uds-dev-backups`   Durable, version-independent application backups

At any given time, either `uds-dev` or `uds-dev-2` can be the live
environment. The names do not imply which one is primary.

------------------------------------------------------------------------

## Design Principle

Treat the Kubernetes clusters as **cattle**, not as the durable copy of
the data.

A cluster can be deleted completely:

``` text
k3d nodes
Kubernetes resources
PVs
PVCs
cluster-generated UUIDs
```

and rebuilt without losing important data, provided the required
application data has been backed up independently.

The desired relationship is:

``` text
                    Durable Storage

                 uds-dev-backups
                       │
             ┌─────────┴─────────┐
             │                   │
          restore             backup
             │                   │
             ▼                   ▼
        uds-dev-2             uds-dev
          NEXT                 LIVE
```

After cutover, the roles reverse during the next rebuild.

------------------------------------------------------------------------

## Upgrade / Rebuild Lifecycle

### 1. Operate the Current Live Environment

Assume `uds-dev` is currently live.

Applications write to their normal Kubernetes storage and external
services. Important state is periodically backed up to:

``` text
uds-dev-backups/
```

The backup process should eventually be automated and application-aware.

------------------------------------------------------------------------

### 2. Build the Replacement Environment

Create `uds-dev-2` from scratch using the desired versions of:

-   k3d/k3s
-   Kubernetes
-   UDS
-   Zarf
-   application packages
-   Helm charts
-   supporting infrastructure

Do not attempt to carry Kubernetes PV/PVC objects from the old cluster
into the new cluster.

The replacement cluster should create its own Kubernetes objects
normally.

For example:

``` text
OLD:

PVC: minio
  ↓
PV: pvc-a44219c7-...
  ↓
old filesystem


NEW:

PVC: minio
  ↓
PV: pvc-cb6bf334-...
  ↓
new filesystem
```

The UUIDs are implementation details and do not need to match.

------------------------------------------------------------------------

### 3. Take a Final Backup

Before final cutover, quiesce applications that own important state.

The goal is to prevent writes while the final backup is being captured.

For example:

``` text
LIVE uds-dev
     │
     │ stop/quiesce writes
     ▼
final backup
     │
     ▼
uds-dev-backups
```

This final backup becomes the recovery point used for the replacement
environment.

------------------------------------------------------------------------

### 4. Restore Into the Replacement Environment

Restore application data into `uds-dev-2`.

There are two useful restore patterns.

#### Pattern A - Restore Into a Newly Provisioned PVC

Allow Kubernetes to dynamically create the new PVC/PV and then populate
the backing filesystem with restored data.

This is simple, but ties the restore procedure somewhat closely to the
dynamically provisioned storage path.

#### Pattern B - Create an Explicit Restore Location and Static PV

This is useful for understanding and controlling the storage
relationship.

Example:

``` text
/restored-storage/minio/
├── .minio.sys/
├── loki-admin/
├── loki-chunks/
├── loki-ruler/
├── uds/
└── zarf-registry/
```

Create a static PV whose `hostPath` points to that directory:

``` yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: restored-minio
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /opt/restored-storage/minio
    type: Directory
```

Then create a PVC bound to that PV:

``` yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-restored
  namespace: uds-dev-stack
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: ""
  volumeName: restored-minio
```

The application/Helm chart is then configured to use the existing PVC.

Conceptually:

``` text
MinIO Deployment
       │
       ▼
PVC: minio-restored
       │
       ▼
PV: restored-minio
       │
       ▼
/opt/restored-storage/minio
       │
       ▼
restored MinIO data
```

The application does not need to know the filesystem path. Kubernetes
provides that abstraction.

------------------------------------------------------------------------

## MinIO Backup Model

MinIO is object storage. Its PVC contains both MinIO internal state and
the objects applications have stored in MinIO.

An example MinIO filesystem may contain:

``` text
.minio.sys/
loki-admin/
loki-chunks/
loki-ruler/
uds/
zarf-registry/
```

The directories other than `.minio.sys` correspond to S3 buckets.

For example:

``` text
Zarf Registry
      │
      │ S3 API
      ▼
    MinIO
      │
      ▼
zarf-registry bucket
      │
      ▼
MinIO persistent storage
```

There does not need to be a separate Zarf PVC containing another copy of
the same registry objects. If the registry is configured to use MinIO as
its storage backend, MinIO contains the durable registry object data.

Likewise, Loki may use both:

-   MinIO/S3 buckets for durable object data.
-   Loki-specific PVCs for local component state.

These are different storage responsibilities and should not be assumed
to contain duplicate data.

------------------------------------------------------------------------

## Long-Term Backup Format

Raw PVC directory copies are useful for:

-   learning the Kubernetes storage mechanics;
-   short-term migration experiments;
-   recovering an identical or compatible application version;
-   maintaining a filesystem-level fallback.

They should not be the only long-term backup mechanism.

Where possible, backups should become application-aware.

### MinIO

Prefer a MinIO-supported object-level backup mechanism such as
`mc mirror` or replication.

The durable backup should ideally represent the buckets and objects
rather than a particular Kubernetes PVC UUID.

Example:

``` text
uds-dev-backups/
└── minio/
    ├── loki-admin/
    ├── loki-chunks/
    ├── loki-ruler/
    ├── uds/
    └── zarf-registry/
```

### PostgreSQL

Prefer database-native backups such as:

``` text
pg_dump
pg_dumpall
```

rather than relying exclusively on a live filesystem copy of the
PostgreSQL data directory.

Example:

``` text
uds-dev-backups/
└── postgres/
    └── database.sql
```

### Filesystem-Based Applications

For applications whose persistent state is safely represented as files,
use an appropriate filesystem backup such as:

``` text
rsync
tar
```

The application should be stopped or otherwise made consistent if
required.

------------------------------------------------------------------------

## Suggested Backup Organization

Maintain multiple recovery points instead of continually overwriting one
backup.

For example:

``` text
uds-dev-backups/
├── 2026-09-19/
│   ├── minio/
│   │   ├── loki-admin/
│   │   ├── loki-chunks/
│   │   ├── loki-ruler/
│   │   ├── uds/
│   │   └── zarf-registry/
│   ├── postgres/
│   │   └── dump.sql
│   └── manifest.json
│
├── 2026-09-12/
└── 2026-09-05/
```

A future backup process can maintain:

-   periodic recovery points;
-   a final pre-cutover recovery point;
-   retention limits;
-   checksums;
-   application/version metadata;
-   backup success/failure status.

------------------------------------------------------------------------

## Blue/Green Cutover Procedure

Assume:

``` text
uds-dev   = LIVE
uds-dev-2 = NEXT
```

### Phase 1 - Prepare

1.  Confirm recent backups exist.
2.  Build `uds-dev-2`.
3.  Verify the new cluster is healthy.
4.  Deploy required applications.
5.  Verify storage and networking.

### Phase 2 - Final Backup

1.  Stop or quiesce stateful applications on `uds-dev`.
2.  Capture the final application-aware backups.
3.  Verify the backup completed successfully.
4.  Record the backup timestamp and relevant application versions.

### Phase 3 - Restore

1.  Restore MinIO buckets/data.
2.  Restore databases.
3.  Restore any other required persistent application state.
4.  Start applications in the replacement cluster.
5.  Validate restored data.

### Phase 4 - Validate

Verify at minimum:

-   MinIO buckets and expected objects exist.
-   Zarf Registry can access its existing image data.
-   PostgreSQL databases contain expected data.
-   Loki can access whatever historical data is expected to survive.
-   applications start normally;
-   ingress/networking works;
-   no unexpected storage errors occur.

### Phase 5 - Cut Over

Move normal usage to `uds-dev-2`.

At this point:

``` text
uds-dev   = OLD / ROLLBACK
uds-dev-2 = LIVE
```

Do not immediately destroy `uds-dev`.

Keep it available for a defined rollback period.

### Phase 6 - Retire

After the replacement has operated successfully for the desired period:

1.  Confirm a current backup of the new live environment exists.
2.  Destroy the old `uds-dev` cluster.
3.  Reclaim its working storage when appropriate.

On the next major rebuild, `uds-dev` becomes the NEXT environment and
the process repeats.

------------------------------------------------------------------------

## Failure and Rollback Model

The old environment remains intact during validation.

If the new environment fails validation:

``` text
uds-dev-2
   │
   └── abandon/debug/rebuild

uds-dev
   │
   └── remains available as previous known-good environment
```

The backup system provides another independent recovery path:

``` text
uds-dev-backups
       │
       └── restore into either environment
```

This avoids making successful migration dependent on a single
destructive operation.

------------------------------------------------------------------------

## Storage Redundancy

Keeping `uds-dev-backups` on a different physical disk/storage pool from
`uds-dev` and `uds-dev-2` provides useful protection against failure of
the working storage.

However, all three locations remain on the same QNAP.

Therefore this protects against some storage failures, but not against:

-   total NAS failure;
-   theft;
-   fire;
-   major filesystem corruption affecting the appliance;
-   destructive administrative mistakes affecting all shares;
-   ransomware or another compromise with access to both working and
    backup data.

If the homelab data becomes genuinely irreplaceable, maintain an
additional backup outside the QNAP.

A longer-term model would be:

``` text
Working storage
    │
    ▼
QNAP uds-dev-backups
    │
    ▼
Second independent/off-NAS backup
```

------------------------------------------------------------------------

## Desired End State

The final objective is that the following operation is safe:

``` text
DELETE THE ENTIRE K3D CLUSTER
```

No important long-term data should depend solely on:

-   a k3d node container;
-   its Docker overlay filesystem;
-   a Kubernetes PV UUID;
-   a Kubernetes PVC UUID;
-   the current Kubernetes version;
-   the current UDS deployment.

A replacement environment should be reproducible from:

``` text
Infrastructure / deployment configuration
                +
       uds-dev-backups
                =
       recovered environment
```

This makes the disposable nature of the development clusters an
intentional design property rather than a risk to persistent data.

------------------------------------------------------------------------

## Future Implementation Work

The next iteration should automate the process rather than relying on
manual PVC copies.

Primary tasks:

1.  Inventory every stateful workload and classify its persistence
    requirements.
2.  Define which state actually needs to survive cluster replacement.
3.  Implement MinIO object-level backup and restore.
4.  Implement PostgreSQL-native backup and restore.
5.  Determine whether Loki local PVC state needs to survive or whether
    restored object storage is sufficient.
6.  Implement filesystem backups for any remaining stateful services.
7.  Create timestamped backup sets under `uds-dev-backups`.
8.  Add backup verification/checksums.
9.  Create a scripted final-backup procedure.
10. Create a scripted restore procedure.
11. Document the blue/green cutover and rollback checks.
12. Add retention and cleanup rules.
13. Add an independent off-QNAP backup if the data warrants it.

The current manual MinIO restore exercise can be retained as a low-level
recovery procedure and as documentation of how PV, PVC, and underlying
filesystem storage relate.
