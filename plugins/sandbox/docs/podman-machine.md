# Operating the podman machine

The sandbox runs its containers through podman, which on Windows and macOS keeps them inside a
small Linux VM, the *podman machine*. These are the facts about operating that VM on each host.

## Windows (WSL2 backend)

- **`podman machine set --disk-size` fails on WSL machines** (exit 125). Grow via WSL instead:
  `wsl --shutdown`, then `wsl --manage podman-machine-default --resize <bytes>` (grow only; it runs
  `e2fsck`/`resize2fs` itself). Verify with `df -h /` inside the machine; `podman machine list`
  keeps reporting the creation-time size and is not the truth.
- **The WSL VM's memory cap is a real failure mode.** `~/.wslconfig`'s `memory=` is what `vmmem`
  will consume; when the host runs low on commit, Windows terminates the VM and every container in
  it dies at once, with no reap record. A missing `.launcher/last-reap.txt` is the signature of a
  hard kill rather than a graceful reap.

## macOS (Apple Hypervisor backend)

- **Create it with the resources the sandbox needs:** `podman machine init --cpus 6 --memory 12288`.
  CPUs and memory can be changed later only while it is stopped:
  `podman machine stop`, `podman machine set --cpus N --memory MiB`, `podman machine start`.
- **The disk is a sparse file** under `~/.local/share/containers/podman/machine/applehv/`. Its
  size limit (100 GB by default) is not what it occupies: `du -sh` on the `.raw` file shows the
  real usage, which grows as images are built.
- **The machine runs as your user** and needs no admin rights on the Mac. *Rootless* (the default)
  and *rootful* describe the user containers run as inside the VM, not on the Mac.
- **A rootless image build cannot create device nodes.** The image's worker-jail skeleton then has
  no real `/dev/null`, `/dev/zero`, `/dev/random` or `/dev/urandom` (the build leaves
  `/opt/bp-jail-skel/dev/.no-device-nodes` saying so), and butler's jailed workers get empty-file
  stand-ins for them.
- **The VM sees your home folder.** Podman's default machine shares `/Users`, `/private` and
  `/var/folders` read-write with the VM; containers see only what the launcher mounts, but a
  process that escaped a container into the VM would see those folders. The launcher refuses a
  project outside the machine's shares before starting anything.
- **The machine keeps running** (and holding its memory) until `podman machine stop`.
