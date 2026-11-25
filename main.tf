# A minimal Juju deployment written against terraform-provider-juju v1.3.1,
# using the charmhub "ubuntu" charm as the single application:
# https://charmhub.io/ubuntu
#
# Every argument below exists in BOTH the 1.3.1 and the 2.3.1 provider
# schema, so this file stays a valid configuration across the upgrade.
# (The runner, run_upgrade_test.sh, exercises the version bump itself.)

variable "model_name" {
  type        = string
  default     = "tf-provider-upgrade-test"
  description = "Juju model name. The e2e phase overrides this for per-run uniqueness."
}

resource "juju_model" "upgrade_test" {
  name = var.model_name

  config = {
    "default-base" = "ubuntu@22.04"
  }
}

resource "juju_application" "ubuntu" {
  model_uuid = juju_model.upgrade_test.uuid
  name       = "ubuntu"

  charm {
    name    = "ubuntu"
    channel = "latest/stable"
    base    = "ubuntu@22.04"
  }

  units = 1
}