# terraform-provider-juju upgrade test case (1.3.1 -> 2.3.1)

Exercises a terraform-provider-juju upgrade from **1.3.1** to **2.3.1**
across the whole upgrade surface:

1. the provider swap itself (`terraform init -upgrade` + lock file),
2. configuration-schema compatibility (`terraform validate`),
3. the **state schema upgrade path** (`terraform plan` over existing state),
4. a real end-to-end apply/plan/destroy against the ambient Juju
   environment.

The configuration deploys a single application, the charmhub
[ubuntu](https://charmhub.io/ubuntu) charm.

The expectation under test: *the upgrade fails due to schema*.

## Run it

```sh
./run_upgrade_test.sh
```

Requirements:

* `terraform` on PATH (or set `TF_BIN`), network access to
  `registry.terraform.io` for provider downloads,
* **a working Juju environment**: a bootstrapped controller the local
  `juju` CLI is logged in to. The provider discovers connection details
  from the CLI (live discovery, backed by `juju show-controller
  --show-password`); **no `JUJU_*` environment variables are used**.

The e2e phase creates and destroys a small model
(`tf-provider-upgrade-e2e-<timestamp>`, one ubuntu application) on the
ambient controller. Logs land in `results/`.

| env             | default | meaning                                    |
|-----------------|---------|--------------------------------------------|
| `TF_BIN`        | terraform | terraform binary                         |
| `FROM_VERSION`  | 1.3.1   | starting provider version                  |
| `TO_VERSION`    | 2.3.1   | upgrade target                             |
| `E2E_MODEL_NAME`| `tf-provider-upgrade-e2e-<timestamp>` | e2e model name |
| `KEEP_WORKSPACE`| 0       | 1 keeps the temp workspace for debugging   |

## Phases and observed outcome

| phase                | command                                         | expectation | observed |
|----------------------|-------------------------------------------------|-------------|----------|
| baseline-init        | `init` @1.3.1                                   | PASS        | PASS     |
| baseline-validate    | `validate` @1.3.1                               | PASS        | PASS     |
| upgrade-init         | pin -> 2.3.1, `init -upgrade`                  | PASS        | PASS     |
| upgrade-validate     | `validate` @2.3.1                              | SCHEMA?     | PASS     |
| upgrade-plan         | `plan -refresh=false` over 1.3.1 fixture state  | SCHEMA?     | PASS (no changes) |
| upgrade-plan-legacy  | `plan -refresh=false` over pre-v1.x fixture state | SCHEMA?  | **SCHEMA FAILURE** |
| e2e-apply            | real `apply` @1.3.1 (model + ubuntu charm)      | PASS        | PASS     |
| e2e-upgrade-plan     | real `plan` @2.3.1 over the applied state       | SCHEMA?     | PASS (no changes) |
| e2e-destroy          | `destroy` @2.3.1                                | PASS        | PASS     |

Verdict **CONFIRMED** (exit 0): a schema-caused upgrade failure exists in
the 1.3.1 -> 2.3.1 window - see the nuance below for where exactly it
strikes. **REFUTED** (exit 2): every step is schema-clean.
**INCONCLUSIVE** (exit 1): harness or environment problem (registry
unreachable, fixtures invalid, Juju environment not working) prevented a
full run; the runner also destroys the e2e resources on failure paths.

## The nuance (what actually fails, and why)

Ground truth, from diffing `terraform providers schema -json` of both
versions and reading both source trees (tags `v1.3.1` / `v2.3.1` of
juju/terraform-provider-juju):

* **Configuration schema: fully additive.** Nothing was removed or
  renamed between 1.3.1 and 2.3.1. A 1.3.1 configuration `validate`s
  clean under 2.3.1. New in 2.3.1 only: resources `juju_action`,
  `juju_jaas_controller`, `juju_secret_backend`, `juju_space`,
  `juju_subnet`, data sources `juju_action`, `juju_charm`, `juju_space`,
  `juju_subnets`, attributes `juju_application.unit_numbers`,
  `juju_machine.instance_id`, `juju_model.agent_version` /
  `juju_model.secret_backend`, `juju_offer.allow_force_destroy`,
  `juju_secret.value_wo*`, `juju_cloud.target_controller`,
  `juju_jaas_access_*.idp_groups`, and provider attribute
  `lazy_api_check`.

* **State schema versions are identical in both** (`Version:` in each
  resource's schema): `juju_application`=1, `juju_integration`=1,
  `juju_machine`=1, `juju_ssh_key`=1, `juju_offer`=2, `juju_secret`=1,
  `juju_access_model`=2, `juju_model`=0. State *written by* 1.3.1
  therefore passes straight through under 2.3.1 - confirmed both by the
  fixture plan (`upgrade-plan`: no changes) and the real e2e
  (`e2e-upgrade-plan`: no changes after refresh).

* **The schema-caused failure is on legacy pre-v1.x state.** 1.3.1 still
  shipped `UpgradeState()` upgraders (e.g. `juju_application` v0 -> v1,
  which resolves a pre-1.0.0 model *name* into a model UUID). 2.3.1
  removed those upgraders while keeping `Version: 1`. Terraform
  (terraform-plugin-framework, `server_upgraderesourcestate.go`) then
  refuses the old state:

  ```
  Error: Unable to Upgrade Resource State
    with juju_application.ubuntu ...
  This resource was implemented without an UpgradeState() method, however
  Terraform was expecting an implementation for version 0 upgrade.
  ```

  That is exactly the failure `upgrade-plan-legacy` reproduces and the
  classifier flags as SCHEMA. This is also why the provider team requires
  "users to be on the latest version of v1.x before upgrading to 2.0"
  (juju/terraform-provider-juju#1066): v1.x could still repair old state,
  v2.x cannot.

So the literal 1.3.1 -> 2.3.1 jump is schema-safe for the config and for
1.3.1-written state (proven end-to-end against a real controller); the
"fail to upgrade due to schema" materializes when pre-v1.x
(schema_version 0) state is carried across the jump - and 2.x offers no
state upgrader to fix it.

## Files

* `main.tf` - the 1.3.1-era configuration: one `juju_model`, one
  `juju_application` deploying the charmhub `ubuntu` charm.
* `provider.tf` - empty provider block: connection details come from
  the ambient juju CLI, no `JUJU_*` variables.
* `versions.tf` - the provider pin (1.3.1), bumped by the runner.
* `fixtures/state-v1.3.1/terraform.tfstate` - hand-crafted state as
  written by provider 1.3.1 (values reconciled against a real 1.3.1
  apply): `schema_version` 1 on the application, 0 on the model, charm
  revision 77 from `latest/stable`.
* `fixtures/state-legacy-v0/terraform.tfstate` - hand-crafted pre-v1.x
  state: `schema_version` 0 on the application, v0-era attributes
  (`model` name instead of `model_uuid`, `placement`, `principal`, charm
  without `base`) derived from the `appV0Schema` PriorSchema in the
  1.3.1 source.
* `run_upgrade_test.sh` - the phase runner and failure classifier.

Both state fixtures use the v4 state format with
`provider["registry.terraform.io/juju/juju"]` provider addresses (the
state file's `provider` field is an HCL-parsed provider config address,
not a bare source string).

## References

* CHANGELOG: github.com/juju/terraform-provider-juju, tags `v1.3.1`,
  `v2.0.0`, `v2.3.0` (2.0.0 drops Juju 2.9 controllers; 2.3.0 adds
  `lazy_api_check`).
* Upgrade guides: "Upgrade the provider to v2" / "Upgrade the provider
  to v1" (canonical.com/juju/docs).
* Upgrader removal context: juju/terraform-provider-juju#1066.
* Framework behaviour: hashicorp/terraform-plugin-framework,
  `internal/fwserver/server_upgraderesourcestate.go`.