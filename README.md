# K3D Lab

Deploy a [uds-k3d](https://github.com/defenseunicorns/uds-k3d) cluster tailored to your development environment. 

## UDS CLI & Maru

Maru tasks are used to pull in the upstream K3D package via the `uds run` alias built into the UDS CLI tool defined in the tasks.yaml file. 

## Variable Overrides via Config Files

[Zarf Docs](https://docs.zarf.dev/ref/config-files/#config-file-examples)

Create a default config file in your pwd by running `zarf dev generate-config`

### Limitation

You can't override individual helm chart component values that are not explicitly defined as package variables using only zarf. You would need to incorporate a UDS bundle + configuration to drill down to that granular level. For example, the COREDNS_OVERRIDES found in the root zarf-config.toml: 

```toml
[package.deploy.set]
COREDNS_OVERRIDES = '''rewrite stop {
  name regex (.*\.admin\.uds\.local) admin-ingressgateway.istio-admin-gateway.svc.cluster.local answer auto
}
rewrite stop {
  name regex (.*\.uds\.local) tenant-ingressgateway.istio-tenant-gateway.svc.cluster.local answer auto
}'''
```

is valid because COREDNS_OVERRIDES is defined as a package variable in the package's `package.yaml` file:

```yaml
kind: ZarfPackageConfig
metadata:
  name: uds-k3d
components:
  - name: uds-dev-stack
      charts:
      - name: uds-dev-stack
        valuesFiles:
          - "values/dev-stack-values.yaml" <--- ## YOU CAN NOT MODIFY OTHER VALUES AT DEPLOY TIME USING JUST ZARF##
        variables:
          - name: COREDNS_OVERRIDES <--- ## EXPLICITLY DEFINED, YOU CAN MODIFY AT DEPLOY TIME ##
            path: coreDnsOverrides
```