# linuxvm: Linux containers on air/OS

air/OS runs Docker containers from Haiku images natively. Containers from
**Linux images** run in a small Linux virtual machine, the way Docker Desktop
does it on macOS and Windows. They get what Linux gives a container: their
own PID, mount, network, UTS and IPC namespaces, cgroup v2 limits, seccomp,
capabilities, and their own networks.

This repository builds the VM itself and packages it as `linuxvm`:

| File in the package | What it is |
| --- | --- |
| `lib/linuxvm/qemu-system-x86_64` | QEMU 10.2, headless, with the [patches](qemu/patches) for air/OS: NVMM acceleration and a virtio-9p server on BFS |
| `data/linuxvm/vmlinuz` | Linux 6.18 configured by [kernel/linuxvm.config](kernel/linuxvm.config): virtio, 9p, overlayfs, namespaces, cgroup v2, nftables, bridges and veths, all built in |
| `data/linuxvm/initramfs.img` | Alpine's busybox, runc and iptables, with `containerd-linuxvm-agent` as `/init` |
| `data/linuxvm/firmware/` | SeaBIOS and the option ROMs QEMU boots the kernel with |

The code that runs Linux containers lives in
[airos-works/containerd](https://github.com/airos-works/containerd) (see its
`docs/airos.md`), and the Engine's part in
[airos-works/moby](https://github.com/airos-works/moby).

## How a Linux container runs

```
docker run alpine ──▶ dockerd ──▶ containerd ──▶ containerd-shim-runc-v2 (haiku shim)
                                                      │  Linux image? forward it
                                                      ▼
                         containerd-linuxvm  ◀── Unix socket, one stream per request
                         (starts QEMU on demand,       │
                          multiplexes the VM's         ▼  virtio-serial
                          one serial channel)    containerd-linuxvm-agent (PID 1 in the VM)
                                                      │  runc
                                                      ▼
                                              the container, root filesystem and
                                              volumes on BFS over virtio-9p
```

- The Engine pulls Linux images into its usual store and builds a Linux OCI
  spec for them (Docker's capabilities, resources, read-only root, tmpfs
  mounts, sysctls), with annotations for what is resolved in the VM: the
  user (from the image's `/etc/passwd`), the networks and their aliases, and
  the published ports.
- The haiku shim sees the `works.airos.platform=linux` annotation and
  forwards containerd's TaskService to the agent over ttrpc. It carries the
  container's stdio between the Engine's FIFOs and agent streams, publishes
  exits, and listens on the host for published ports.
- `containerd-linuxvm` boots the VM on the first Linux container (about a
  second with NVMM) and keeps it running. It owns the VM's single
  virtio-serial channel and multiplexes it: every connection to
  `/var/run/containerd-linuxvm.sock` becomes one stream to the agent. It also
  sets the VM's clock from the host's every minute.
- The agent runs each container with runc. Every Docker network is a Linux
  bridge with its own subnet (`bridge` is `docker0`, 172.17.0.0/16), NAT to
  the outside, isolation from the other networks, and a DNS server on its
  gateway that answers container names and aliases (Compose service names)
  and forwards everything else to the host's DNS servers.
- The host's root directory is shared with the VM twice over virtio-9p:
  `/host` without caching beyond mmap, so what changes on BFS shows at once
  (bind-mounted source trees), and `/hostc` with the page cache in front of it
  for root filesystems and volumes, which only containers change. The agent
  syncs `/hostc` when a container stops, so `docker cp`, `commit` and
  `export` read what it wrote.

## What works

`docker run` with `-i`, `-t` (window size, ^C), `-d`, `-p` (TCP and UDP),
`-v` (host paths and named volumes, `:ro`), `--tmpfs`, `-u`, `--network`
(user networks with name resolution, `host`, `none`, `container:`),
`--privileged`, `--cap-add/--cap-drop`, `--memory`, `--cpus`, `--pids-limit`,
`--read-only`, `--sysctl`, `--ulimit`; `docker exec` (with `-u` and `-t`),
`logs`, `stop` (with the image's stop signal), `kill -s`, `top`, `stats`,
`pause`/`unpause`, `update`; `docker build` (the classic builder: `FROM` a
Linux image, `RUN`, `COPY`, `USER`...), `commit`, `save`; `docker compose`
stacks. Unix sockets and FIFOs work on 9p (PostgreSQL's socket, for one).
`containerd-linuxvm status` and `containerd-linuxvm stop` ask the running
supervisor; Docker Desktop's settings have a Linux VM tab for the same and
for the VM's memory and processors.

## Limits

- **Speed.** Code runs at native speed, but anything that exits to QEMU costs
  more than under KVM: Haiku's NVMM has no in-kernel APIC, so timer
  interrupts and inter-processor interrupts go through QEMU, and every 9p
  request is a round trip to it. Starting a process from a 9p root file
  system takes about 10 ms (about 4 ms under KVM). `fsync` costs what it
  costs on BFS (about 11 ms on an NVMe drive) plus the round trip.
- **arm64** runs the VM under emulation (TCG): Haiku has no hypervisor on
  arm64. The package carries QEMU's own GLib and libslirp (built from
  source with HaikuPorts' patches; arm64 has no HaikuPorts repository) in
  `lib/linuxvm/lib`, and the guest is an ARMv8.2 core (`neoverse-n1`), which
  spares the guest kernel SVE and SME state on every context switch. It
  works, but expect code in containers to run several times slower than on
  the host. Verified so far in an emulated arm64 air/OS (QEMU's code
  generator works on Haiku arm64 and boots the VM); not yet on a board.
- **BFS** has no hard links (extraction copies the file) and no device nodes.
- `docker cp` into a running container may not show in it until the page
  cache drops the file; files a running container writes reach BFS within
  about 30 seconds, and at once when it stops.

## Building

On the air/OS build server (it needs the air/OS cross SDK under
`/data1/airos/sdk` and airos-ci's `deps/haikuports.py`):

```sh
export ARCH=x86_64
tools/build-qemu.sh                     # QEMU for air/OS, NVMM and virtio-9p
tools/build-kernel.sh                   # the VM's kernel
tools/build-agent.sh ../containerd      # the agent, from airos-works/containerd
tools/build-initramfs.sh                # Alpine userland + agent
tools/package-haiku-cross.sh            # artifacts/linuxvm-*.hpkg
```

## Settings

`~/config/settings/docker_linuxvm` holds `key value` lines:

```
memory 4096   # MiB (default: a quarter of the host's, 1-8 GiB)
cpus 4        # (default: half the host's, at most 8)
```

`containerd-linuxvm` reads it when it boots the VM. Logs:
`/var/run/containerd-linuxvm/console.log` (the VM's console) and `qemu.log`.
