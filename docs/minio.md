# Minio

The uds-dev-stack helm chart that is installed as part of the uds-k3d package provides a standalone Minio instance for development.

## Using S3 as a Storage Backend for the Zarf Registry

## Prerequisites

- A deployed uds-k3d package
- mc
- uds

When deploying the Zarf Init package (not included in this repo) it will use a local-path PVC for the Zarf Registry by default. To use the Minio instance as the storage backend for the Zarf Registry, you need to precreate a bucket in Minio and then provide the necessary configuration to the Zarf Init package. Once the k3d package is installed, you run the following maru command to configure a zarf-registry bucket along with a user that has access to that bucket.

```bash
uds run setup-zarf-registry-minio-backend
```

This command will create a bucket named `zarf-registry` in the Minio instance along with a user named `zarf-registry` that has access to that bucket through the attachment of a policy [document](../zarf-registry-policy.json). You can verify access to this bucket by port-forwarding the Minio console and logging in using `zarf-registry-secret` as the password for the `zarf-registry` user.

These tasks are specific to the uds-k3d package. They expect certain resources to be present for lookup using kubectl.
