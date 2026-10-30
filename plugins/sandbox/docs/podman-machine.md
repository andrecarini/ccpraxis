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

### Set up and changed by `podman-machine.pl`

The machine is rootful and shares only the host folders the sandbox mounts. One script creates it and
keeps it that way; nothing here asks you to type `podman machine init` flags.

```bash
S=~/.claude/ccpraxis/plugins/sandbox/scripts/podman-machine.pl
perl $S plan                          # the current machine next to the desired one
perl $S apply --confirm               # create it, or recreate it to match
perl $S add-project ~/Projects/app --confirm      # share a project read-write, then apply
perl $S remove-project ~/Projects/app --confirm   # stop sharing it, then apply
perl $S test-scratch off --confirm    # drop the container-test folder (on by default)
```

Every command prints the plan first. Without `--confirm` nothing changes, the share list included.
`--cpus N`, `--memory MiB` and `--disk-size GiB` set resources for that run; otherwise the current
machine's are kept, and a new machine gets `--cpus 6 --memory 12288` and podman's 100 GiB disk. When
only resources differ, apply changes them in place with `podman machine set` and keeps every
container. A smaller disk needs a recreate.

The share list is `~/.claude/ccpraxis-podman-machine.json`: the project directories and whether the
test folder is shared. It starts empty. It sits in `~/.claude` because that folder is never shared
with the VM, is not a repository and is not exported by `/steward:backup`. A list inside a shared
folder would let the VM add shares to the next apply. A live install somewhere other than
`~/.claude/ccpraxis` (where the `claude-sandbox` shims run the launcher from) goes in its
`"install_root"` key, by hand.

### What it shares, and why

Each folder is mounted at its own path inside the VM, because podman hands a bind source to the VM as
written.

| mode | host folder | why |
|---|---|---|
| ro | `~/.claude/ccpraxis` | the live install: the `plugins/` marketplace, selected `skills/<name>`, `scripts/statusline.pl` and the backpack scripts, all bound read-only into every sandbox |
| ro | `~/.cache/ccpraxis/container-files` | host files a container reads. Today that is a copy of `~/.claude/almanac-global-counts.json`, which the launcher writes at each container create and before each start. `~/.claude` itself holds transcripts, credentials and the vault, so it is never shared |
| rw | `~/.cache/ccpraxis/container-test-scratch` | fixtures for ccpraxis's own container tests (`tests/lib/TestSandbox.pm`), nothing else. Those tests cannot run without it, so it is on by default; it holds only throwaway files the Mac never executes |
| rw | each directory added with `add-project` | the project, at `/project`, and its `.ccpraxis-local-data/claude-home` at `/root/.claude` |
| ro | any other `directory` marketplace in `~/.claude/plugins/known_marketplaces.json` | the launcher binds it read-only into every sandbox (`ccpraxis-local` is served from the live install; there is none other on a usual machine). One inside `~/.claude` is not shared, and the plan says every launch is refused while it stays registered |

Nothing else: not `/Users`, `/private`, `/var/folders`, or `~/.config/containers` (which podman 6
mounts at `/etc/containers` so its config can be edited from the Mac; the VM has its own). With no
project in the list, `claude-sandbox` refuses every launch before asking anything, and its message
gives the `add-project <dir>` command to run. It refuses the same way when a bind would need to write
through a folder the machine shares read-only.

`add-project` refuses your home folder and anything containing it, `~/.claude` and anything inside
it, the live install, `~/.cache/ccpraxis`, `~/.ssh`, `~/.gnupg`, `~/Library`, podman's own
`~/.config/containers` and `~/.local/share/containers`, a top-level folder, a path under one of the
VM's own system directories (`/usr`, `/opt`, `/var`, ...) and a path with a `:` or a `,`. The same
rules are checked against the list file before every plan, so a hand edit cannot get round them. A
folder renamed by case alone is fixed by running `add-project` on the new spelling: APFS calls the
two one folder, the VM does not.

`ro` is recorded, not enforced, on this provider. podman 6.1.4 stores `-v SRC:DST:ro` as the mount's
`ReadOnly` flag, but vfkit 0.6.4 has no read-only virtio-fs share and the VM's mount unit is
read-write, so a process that escaped into the VM could write an `ro` folder. A container's own
read-only binds are enforced. The mode is still recorded, so the launcher refuses a read-write bind
through a read-only share, and a provider that enforces it gets it for free.

### Rootful

Container root is root in the VM; there is no user namespace between them, and the VM is the
boundary. Image builds can create device nodes, so the bp-jail skeleton gets a real `/dev/null`,
`/dev/zero`, `/dev/random` and `/dev/urandom`. A rootless machine cannot make them: its build leaves
`/opt/bp-jail-skel/dev/.no-device-nodes`, and butler's jailed workers get empty-file stand-ins. The
machine still runs as your user and needs no admin rights on the Mac.

### What a recreate costs

`apply --confirm` recreates the machine when rootful or a share differs. It refuses first when a
listed folder is missing, or when the live install predates `podman-machine.pl` (its launcher would
bind `~/.claude/almanac-global-counts.json`, which this machine does not share): promote first.
Then, in order, it:

1. starts the machine if it is stopped, and refuses if any container is running, or if the VM holds
   a container the sandbox does not recreate (anything but its own, the test probes and the
   container lane) or any volume: remove those yourself first if they can go. It lists what will go
   with the machine, and the images it does not keep;
2. saves every `claude-sandbox*` image with `podman save` to `~/.cache/ccpraxis/podman-machine-images-<time>.tar`
   (written as `.tar.partial` and renamed once whole; the new machine starts with empty storage, so
   save and load are what carry them);
3. removes the machine (`podman machine rm -f`), which deletes every container in it. Sandbox
   containers are recreated by the next launch; each project's `claude-home` lives on the Mac and is
   kept;
4. creates the new one (`podman machine init --rootful ... --volume SRC:DST[:ro]`). podman downloads
   the machine OS image (about 1 GB) unless it has it cached;
5. starts it, makes its rootful connection the default (`podman system connection default
   <name>-root`) and checks podman reports `Rootless=false`, loads the saved images, checks each name
   came back and deletes the archive;
6. stops it again if it was stopped before.

If a step after the removal fails, the archive is kept and the message says where; `plan` lists it,
and the next `apply --confirm` creates the machine and loads it -- unless the machine already has
images under those names (a launch built a fresh one meanwhile), which it does not overwrite.
Images other than `claude-sandbox*` are not kept. Images carried over from a rootless machine were
built without the device nodes; take `claude-sandbox`'s rebuild offer, or `podman rmi` the image, to
build one on the rootful machine.

After a recreate, `podman machine ssh ls /etc/containers` should list the VM's own `policy.json`
and `registries.conf`, and `podman info --format '{{.Host.Security.Rootless}}'` should print `false`.

### Other facts

- **The disk is a sparse file** under `~/.local/share/containers/podman/machine/applehv/`. Its size
  limit is not what it occupies: `du -sh` on the `.raw` file shows the real usage, which grows as
  images are built.
- **A missing shared folder stops the machine from starting.** vfkit refuses a share whose folder is
  gone. The launcher recreates the two `~/.cache/ccpraxis` folders before it starts the machine, and
  for any other missing folder it stops with the folder's name and the `remove-project` command
  instead of trying. A start by hand (`podman machine start`, Podman Desktop) gets only vfkit's own
  error.
- **The machine keeps running** (and holding its memory) until `podman machine stop`.
