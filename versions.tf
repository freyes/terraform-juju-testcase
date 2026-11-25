terraform {
  required_providers {
    juju = {
      source  = "juju/juju"
      version = "1.3.1" # bumped to 2.3.1 by run_upgrade_test.sh during the upgrade phase
    }
  }
}