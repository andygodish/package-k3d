# K3D Lab

Deploy a [uds-k3d](https://github.com/defenseunicorns/uds-k3d) cluster tailored to your development environment. 

## UDS CLI & Maru

Maru tasks are used to pull in the upstream K3D package via the `uds run` alias built into the UDS CLI tool defined in the tasks.yaml file. 

## Variable Overrides via Config Files

[Zarf Docs](https://docs.zarf.dev/ref/config-files/#config-file-examples)

Create a default config file in your pwd by running `zarf dev generate-config`