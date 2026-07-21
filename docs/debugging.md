# Debugging the container

Troubleshooting a running Openfire container (Podman). For debugging a
Kubernetes/OpenShift **deployment** (init container, probes, secrets), see
[openfire-gitops › debugging](https://gitlab.com/mkoese/openfire-gitops/-/blob/main/docs/debugging.md).

## Logs

The image routes all Openfire logging to **stdout** (container log4j2 config), so
the container log is the single source of truth:

```bash
podman logs -f openfire
```

First-boot autosetup, schema creation/migration, and startup errors all appear
here. To raise verbosity, set the debug property (via mounted `openfire.xml` or
the admin console): `<log><debug><enabled>true</enabled></debug></log>`.

## Shell into the container

```bash
podman exec -it openfire sh
ls -l /opt/openfire/{conf,lib,plugins,resources/security,embedded-db}
cat /opt/openfire/conf/openfire.xml     # note: rewritten to <setup>true</setup> after first boot
```

## Common failures

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Build: `openfire_<v>.tar.gz not found in build context` | tarball not downloaded / wrong version | run the fetch step; check `OPENFIRE_VERSION` matches the filename |
| Build: `sha256sum: WARNING: 1 computed checksum did NOT match` | wrong/updated pin in `plugins.txt`/`lib.txt` | recompute and update the pinned sha256 |
| `CrashLoopBackOff` / cannot write `embedded-db` under a random UID | `embedded-db`/`logs` not group-0 writable | ensure the builder pre-creates them (already fixed here); see [security.md](security.md#runs-as-an-arbitrary-non-root-uid) |
| Admin console never comes up | autosetup failed / DB unreachable | check logs for the setup/schema step; verify DB connectivity |
| `HEALTHCHECK` shows unhealthy but app works | probing before startup completes | increase `--start-period`; on K8s use the chart's startup probe instead |
| Missing JDBC driver / auth provider at runtime | JAR not in `lib.txt` or wrong destination | it must be in `lib/` (→ `/opt/openfire/lib`), not `plugins/` |

## Inspect the built image

```bash
skopeo inspect --override-os linux --override-arch amd64 \
  docker://quay.io/mikailkose/openfire-oci:5.1.1        # labels, digest, created
podman run --rm openfire-oci:5.1.1 java -version         # confirm JDK 17
podman run --rm openfire-oci:5.1.1 id                    # confirm uid=1001 gid=0
podman history openfire-oci:5.1.1                        # layer breakdown
```

## Verify supply-chain pins

Reproduce the CI verification locally — any mismatch means a tampered or wrong
artifact:

```bash
for list in plugins lib; do
  while IFS='|' read -r name url sha256; do
    [ -z "$name" ] && continue
    curl -fsSL -o "/tmp/${name}.jar" "$url"
    echo "${sha256}  /tmp/${name}.jar" | shasum -a 256 -c -
  done < "${list}.txt"
done
```

## JVM diagnostics

```bash
podman exec openfire sh -c 'jcmd 1 VM.flags'            # effective JVM flags
podman exec openfire sh -c 'jcmd 1 GC.heap_info'        # heap usage
podman exec openfire sh -c 'jcmd 1 Thread.print' | head # thread dump
```

`java` is PID 1 (exec-form entrypoint), so `jcmd 1 …` targets the server.
