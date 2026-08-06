# Phase 2 Talos Evidence

## Status

Phase 2 completed on 2026-07-12. It created the fresh Talos identity and
declarative Talhelper sources, rendered all three control-plane configs, and
validated them locally. No Talos or Kubernetes API was contacted and no machine
configuration was applied.

## Declarative Inputs

- Cluster: `nuc-cluster`
- Talos: `v1.13.6`
- Kubernetes: `v1.35.6`
- API endpoint and VIP: `192.168.90.20`
- Nodes: `nuc1` through `nuc3`, all schedulable control planes
- NIC: DHCP on `enp88s0`; router reservations retain stable node addresses
- Install disk: `/dev/nvme0n1`, with install wipe enabled
- Networking bootstrap: no CNI and kube-proxy disabled for the later Cilium phase
- Local API and DNS: KubePrism on port `7445` and host DNS forwarding enabled

The fresh secret bundle is fully encrypted at `talos/talsecret.sops.yaml` to the
repository age recipient. The original plaintext temporary file was removed.

## Secure Boot Schematic

Schematic ID:

```text
a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79
```

Both artifacts use that ID and Talos `v1.13.6`:

```text
https://factory.talos.dev/image/a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79/v1.13.6/metal-amd64-secureboot.iso
factory.talos.dev/metal-installer-secureboot/a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79:v1.13.6
```

The schematic contains `intel-ucode`, `i915`, `iscsi-tools`, and
`util-linux-tools` from `siderolabs`.

## Disk Policy

- STATE uses LUKS2 with TPM slot 0, PCR 7 plus the signed PCR 11 policy, and a
  Secure Boot enrollment check.
- EPHEMERAL uses the same TPM policy, is locked to STATE, and is capped at
  `150GiB`.
- The unencrypted XFS `longhorn` user volume selects the system disk, requires at
  least `700GiB`, grows into the remaining available space, and mounts by Talos at
  `/var/mnt/longhorn`.

## Verification

- `talhelper validate talconfig talos/talconfig.yaml` passed.
- Talhelper rendered `nuc1.yaml`, `nuc2.yaml`, and `nuc3.yaml` into the ignored
  `clusterconfig/` directory and installed the generated Talos client credential
  at ignored `.talos/config`.
- `talosctl validate --mode metal --strict` passed for all three machine configs.
- `just talos validate` asserted every locked Phase 2 machine, network, image,
  CNI, encryption, and volume value in the rendered output.
- The root Justfile now dispatches to namespaced repository, Talos, bootstrap,
  and Kubernetes modules; no flat compatibility commands remain.
- The hostname documents are the only per-node machine-policy difference; DHCP
  reservations remain the source of each node's address.
- The encrypted identity is trackable, while generated machine configs and
  `.talos/config` remain ignored.
- The repository secret scans passed without exposing or tracking identity
  plaintext.
