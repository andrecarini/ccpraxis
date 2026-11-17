### Host: Windows

**The `/project` bind mount is slow per file.** It reaches the Windows filesystem through WSL2's 9p filesystem, and every per-file syscall on it costs an order of magnitude more than on the container's own overlay filesystem. Keep trees of many small files (`node_modules`, package-manager stores, build caches) on container-native storage; for pnpm, `bp-fast-store.sh` does that in one command (butler's coordinator protocol, "Fast test I/O").
