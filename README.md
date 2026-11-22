# CirCI on Docker: Terraform module

Runs a released [CirCI](https://circi.dev) on one Docker host: the app, Postgres unless you give your own, and Caddy
for TLS and hosted sites when you ask for it.

```hcl
provider "docker" {
  host = "ssh://ubuntu@ci.acme.io" # or unix:///var/run/docker.sock on the host itself
}

module "circi" {
  source  = "cir-ci/circi/docker"
  version = "X.Y.Z" # a CirCI release

  circi_version      = "X.Y.Z" # the same release: the image the module runs
  better_auth_secret = var.better_auth_secret # openssl rand -base64 32; keep it stable
  postgres_password  = var.postgres_password
}
```

Every input, updating, Amazon RDS and private registries are on the website:
[circi.dev/self-hosting/terraform](https://circi.dev/self-hosting/terraform/).

## About this repository

This repository is a generated mirror of [`deploy/terraform`](https://github.com/cir-ci/repo/tree/main/deploy/terraform)
in [cir-ci/repo](https://github.com/cir-ci/repo), pushed on each CirCI release so the module can be published on the
Terraform Registry. Version `vX.Y.Z` here is CirCI release `X.Y.Z`. Don't open issues or pull requests here: they go
to [cir-ci/repo](https://github.com/cir-ci/repo/issues), and changes made here are overwritten by the next release.
