# No connection details on purpose: the provider discovers the ambient
# controller through the local juju CLI (live discovery, backed by
# `juju show-controller --show-password`), so a working Juju environment
# on the runner is all this test case needs. No JUJU_* variables involved.

provider "juju" {}