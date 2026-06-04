# Use the system `ssh` CLI; drop swift-nio-ssh

Supersedes the SSH decision in [[0003-monolithic-swiftui-pure-swift-ssh]].

## Context

The pure-Swift SSH stack (swift-nio-ssh) could only do ed25519/ECDSA keys — no
RSA, no ssh-agent, no `~/.ssh/config`, no certificates, no encrypted keys. Real
profiles hit all of these (e.g. an ECDSA *certificate* key, agent-based auth).
The system `ssh` handles every one of them.

## Decision

SSH is the **system `/usr/bin/ssh`** via a ControlMaster socket (`CLISSHTransport`):
connect (`-M -N -f`), exec (`-S`), local forward (`-O forward`/`cancel`),
disconnect (`-O exit`). A profile key uses `-i`; otherwise ssh-agent / ssh_config
decide; a password is fed via `SSH_ASKPASS`. Host-key checking defaults to lenient
(re-imaged LAN boxes), with a per-profile strict toggle.

**swift-nio-ssh and its whole dependency tree (swift-nio, swift-crypto,
swift-asn1, swift-atomics, swift-collections, swift-system) are removed**, along
with the hand-rolled OpenSSH key parser and the NIO port-forwarder. The app now
builds with **zero external Swift packages**.

## Consequences

- Gains: agent, ssh_config, ProxyJump, all key types incl. certificates,
  known_hosts — for free. Much smaller/faster build, no dependency maintenance.
- Loses: the NX tunnel byte-counter (the ssh master owns the forward), so the
  window title/dashboard show quality + "connected" instead of live MB/s.
- `ssh` is a system binary (always present on macOS), not bundled — consistent
  with already shelling out to the bundled nxproxy/Xvfb.
