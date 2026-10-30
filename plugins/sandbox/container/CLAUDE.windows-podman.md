### Windows host under Podman: URLs for the user

**Give the user `$SANDBOX_HOST_IP` in URLs, not the `localhost` shown in "Sharing the URL with the user" above.** On this host the host-side mirror of a published port, WSL2's `wslrelay.exe`, is unreliable: it sometimes registers only an IPv6 listener, so IPv4 connects from Firefox or Chrome fail silently while the container is healthy. The launcher puts the WSL distro's own IPv4 address in `$SANDBOX_HOST_IP`, and that address always reaches the published port:

```bash
HOST=${SANDBOX_HOST_IP:-localhost}
PORT=$(echo "$SANDBOX_OPEN_PORTS" | cut -d- -f1)
echo "Open http://${HOST}:${PORT}"
```

The value is fixed when the container is created. After `wsl --shutdown` or a reboot the WSL address can change while this container keeps the old one; if a URL built from it stops answering, tell the user, and a rebuild of the sandbox picks up the new address.
