# k3d `kubectl logs -f` Failure: inotify Instance Exhaustion

## Symptom

Following pod logs in the local k3d cluster unexpectedly terminated
with:

``` text
failed to create fsnotify watcher: too many open files
stream closed: EOF
```

The issue was first seen in k9s while following an Istio waypoint, but
the waypoint was healthy (`Running`, zero restarts). The same failure
occurred with plain `kubectl logs -f` and with unrelated pods such as
CoreDNS. `kubectl logs` without `-f` worked normally.

This isolated the problem to the Kubernetes log-follow path rather than
k9s, Istio, Envoy, or a specific workload.

## Environment

``` text
macOS
  ↓
Colima VM
  ↓
Docker
  ↓
k3d / k3s server container
  ↓
Kubernetes workloads
```

The k3d containers share the Linux kernel provided by the Colima VM.

## Diagnosis

The macOS shell initially had:

``` sh
ulimit -n
```

``` text
256
```

Increasing that to `4096` did not fix the problem.

The k3d server itself had a very high file descriptor limit:

``` sh
docker exec k3d-uds-server-0 sh -c 'ulimit -n'
```

``` text
1048576
```

Because the error specifically referenced an `fsnotify watcher`, Linux
inotify limits were checked:

``` sh
colima ssh -- sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances
```

``` text
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 128
```

The watch limit was high, but only 128 separate inotify instances were
allowed.

Counting from the general Colima process namespace showed only a few
instances, but k3d has its own PID namespace. Counting from inside the
k3d server exposed the problem:

``` sh
docker exec k3d-uds-server-0 sh -c   'find /proc/*/fd -lname "anon_inode:inotify" 2>/dev/null | wc -l'
```

``` text
129
```

The environment was trying to use 129 inotify instances while the kernel
limit was 128.

## Root Cause

``` text
Active inotify instances visible to k3d: 129
fs.inotify.max_user_instances:          128
```

When `kubectl logs -f` attempted to establish a streaming log follow,
the runtime could not create another filesystem watcher and returned:

``` text
failed to create fsnotify watcher: too many open files
```

The message is somewhat misleading: the exhausted resource was the
inotify instance limit, not the normal per-process file descriptor
limit.

## Fix

Increase the inotify instance limit in the Colima VM:

``` sh
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=1024
```

After this change, `kubectl logs -f` immediately worked normally,
confirming the diagnosis.

For this development environment, a larger ceiling such as `8192` is
reasonable:

``` sh
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=8192
```

The existing watch limit can remain:

``` text
fs.inotify.max_user_watches = 1048576
```

Increasing `max_user_instances` only raises the allowed maximum; it does
not preallocate thousands of watchers.

## Persistence

The setting belongs at the Colima VM/kernel layer because k3d shares
Colima's Linux kernel:

``` text
Colima Linux kernel
  └── inotify limits
        ↓
      k3d
        ↓
      k3s/containerd
        ↓
      Kubernetes log streaming
```

A runtime `sysctl -w` change may not survive a Colima restart. The
setting should therefore be persisted through the Colima VM
configuration/provisioning mechanism.

## Quick Diagnostic

If k9s or `kubectl logs -f` starts failing with:

``` text
failed to create fsnotify watcher: too many open files
```

check the limit:

``` sh
docker exec k3d-uds-server-0   sysctl fs.inotify.max_user_instances
```

Then count current instances:

``` sh
docker exec k3d-uds-server-0 sh -c   'find /proc/*/fd -lname "anon_inode:inotify" 2>/dev/null | wc -l'
```

If the count is at or above `fs.inotify.max_user_instances`, increase
the limit in Colima.

## Summary

The problem was not an unhealthy workload, Istio failure, k9s-specific
issue, or ordinary file descriptor exhaustion.

The root cause was:

``` text
129 active inotify instances
128 maximum allowed
```

Increasing `fs.inotify.max_user_instances` resolved the log-follow
failures.
