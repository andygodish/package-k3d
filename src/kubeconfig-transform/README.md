# kubeconfig-transform

A small helper to make a k3d kubeconfig usable from another machine.

When k3d runs in Docker, the generated kubeconfig often points at a local bind like:

```yaml
server: https://0.0.0.0:6550
```

That works *on the host running k3d*, but not from your primary workstation.

This script copies a kubeconfig and rewrites that `server:` entry to use the host's LAN IP (e.g. `192.168.0.x`) while keeping the port (`6550`).

## Usage

```bash
./src/kubeconfig-transform/transform-kubeconfig.sh \
  --in ~/.kube/config \
  --out ./kubeconfig.lan.yaml
```

Override detection:

```bash
./src/kubeconfig-transform/transform-kubeconfig.sh --ip 192.168.0.42
```

## Notes

- Auto-detection:
  - macOS: determines the default-route interface via `route get default`, then uses `ipconfig getifaddr <iface>`.
  - Linux: uses `ip route get 1.1.1.1` and extracts the `src` address.
- The script fails fast if it can’t find `server: https://0.0.0.0:<port>` so we don’t produce a silently-wrong kubeconfig.
