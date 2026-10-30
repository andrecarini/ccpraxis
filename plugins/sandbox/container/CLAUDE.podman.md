### Runtime: Podman

This container runs under Podman.

**Host services** are at `host.containers.internal`, which Podman adds to the container's `/etc/hosts`. A Postgres instance listening on the host's port 5432 is `host.containers.internal:5432`.
