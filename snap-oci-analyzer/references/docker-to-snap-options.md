# docker-to-snap Options Reference

Reference for preparing and invoking `docker-to-snap` to extract a Docker/OCI
tarball into the `rootfs/`, `config.json`, `snapcraft.yaml`, and `build_scripts/`
artifacts needed by the `snap-oci-container` skill workflow.

The tool is located in the current working directory (the docker-to-snap repository root).

**Always use `--suppress-build`** when invoking from this skill — the build and
confinement iteration are handled by `snap-iteration-workflow` in Phase 5.

---

## Required parameters

| Parameter | Flag | Notes |
|---|---|---|
| Tarball path | `--tarball <path>` | Path to the `.tar` file from `docker save` or OCI export |

---

## Optional parameters — prompt the user

Prompt for these if the tarball filename does **not** follow the `<name>_<version>.tar`
convention, or if the user has specific requirements:

| Parameter | Flag | Default / inference | Prompt condition |
|---|---|---|---|
| Application name | `--application-name <name>` | Inferred from tarball filename (`myapp_1.2.tar` → `myapp`) | Prompt if filename does not match `name_version.tar` pattern, or if user wants to override |
| Application version | `--application-version <ver>` | Inferred from tarball filename | Prompt if not inferable or user wants to override |
| Output folder | `--output-folder <folder>` | `<name>-snap` | Prompt if user wants a custom destination |
| Service name | `--service-name <name>` | Same as application name | Prompt if the DNS service hostname should differ from the app name |

---

## Optional parameters — offer but do not require

Offer these as optional; skip unless the user mentions them:

| Parameter | Flag | Notes |
|---|---|---|
| OCI image tag | `--oci-image-tag <tag>` | Default: `latest`. Only relevant if tarball is already in OCI archive format |
| Environment variables file | `--envvars <file>` | File of `KEY=value` pairs to embed in the snap recipe |
| Do not daemonize | `--do-not-daemonize` | Flag only (no value). Makes the snap a **run-to-completion app** instead of a daemon. See the decision rule below — pass it for run-to-completion apps, omit it for long-lived apps. |

---

## Daemon vs. run-to-completion decision

`docker-to-snap` makes the snap a **daemon** by default (systemd-supervised,
auto-restarted). Choose based on the application's runtime model:

| Application runtime model | Examples | Flag |
|---|---|---|
| **Long-lived** — runs continuously, stays up | web/API server, database, message broker, scheduler, watcher, a streaming stage in a data pipeline | **Omit** `--do-not-daemonize` (daemon — default) |
| **Run-to-completion** — invoked, does work, returns a value/output, then exits | CLI tool, batch/one-shot job, file converter, query/report generator, interactive command | **Pass** `--do-not-daemonize` |

A run-to-completion app packaged as a daemon will be treated by systemd as a
crash-looping failure (it exits immediately), so this distinction matters.
Classify from the image purpose/name, the entrypoint behaviour (blocks/listens
vs. returns), and upstream documentation before invoking the tool.

---

## Parameters to never use from this skill

| Parameter | Reason |
|---|---|
| *(no `--suppress-build`)* | **Always** pass `--suppress-build` — the build is handled by `snap-iteration-workflow` |
| `--preserve-image-contents` | Only for re-packaging without re-downloading; not applicable to a fresh tarball |
| `--preserve-snap-recipe` | Only when updating an existing project; not applicable to first-time extraction |

---

## Filename inference rules

`docker-to-snap` infers the application name and version from the tarball filename
when it matches the pattern `<name>_<version>.tar`:

| Filename | Inferred name | Inferred version |
|---|---|---|
| `myapp_1.2.3.tar` | `myapp` | `1.2.3` |
| `my-service_2024.01.tar` | `my-service` | `2024.01` |
| `myapp.tar` | *(not inferable)* | `0.1` (default) |
| `myapp_latest.tar` | `myapp` | `latest` |

If inference is not possible, `docker-to-snap` will still run but the snap name
may be wrong — always confirm with the user.

---

## Output directory structure

After a successful `docker-to-snap --suppress-build` run, the output folder contains:

```
<output-folder>/
├── rootfs/                     ← OCI container filesystem (input for Phase 1+)
├── snap/
│   ├── snapcraft.yaml          ← generated recipe (input for Phase 4+)
│   └── hooks/
│       ├── install
│       ├── post-refresh
│       ├── remove
│       └── configure
├── build_scripts/
│   ├── create_wrapper.sh           ← generates library_wrapper.sh from config.json
│   ├── embed_rpath.sh              ← embeds RPATH into all ET_EXEC ELF binaries
│   ├── patch_entrypoint.sh         ← postgres-specific entrypoint patches (not called by default)
│   ├── patch_interpreter.sh        ← patches ELF interpreter to snap-local path
│   └── replace_absolute_symlinks.sh ← converts absolute symlinks to relative
├── config.json                 ← OCI image config (input for Phase 1+)
├── umoci.json
└── version
```

After extraction, set the working context for subsequent phases to `<output-folder>/`.

> **⚠️ `/dev` tree:** The extracted `rootfs/dev/` may contain device stubs and
> dangling symlinks (e.g. `dev/stdout → fd/1 → /proc/self/fd/1`) that are live
> pseudo-terminal FIFOs at extraction time. The generated `snapcraft.yaml`
> includes an `override-pull:` step that copies the rootfs with `cp -a` (symlinks
> verbatim, no dereferencing) then removes `rootfs/dev/` before snapcraft
> processes it — this prevents a `SpecialFileError: ... is a named pipe` build
> failure. snapd provides a correct `/dev` inside the sandbox at runtime.
> Do **not** remove the `override-pull:` step from the generated recipe.

> **⚠️ Entrypoint resolution:** Immediately after `docker-to-snap` completes,
> verify the generated `library_wrapper.sh` contains a correct `ENTRYPOINT=`
> path. Check:
> ```bash
> grep 'ENTRYPOINT=' <output-folder>/snap/local/library_wrapper.sh
> ls rootfs/<that-path>    # must exist
> ```
> If `process.args[0]` is a cwd-relative path (e.g. `./entrypoint.sh`),
> `create_wrapper.sh` searches the container PATH and falls back to
> `process.cwd + entrypoint name` if not found there. If the resolved path does
> not exist in `rootfs/`, replace `library_wrapper.sh` with a custom wrapper
> that sets the correct path directly.

---

## Runtime variable: `APP_ARGS`

The generated `library_wrapper.sh` expands the shell variable `$APP_ARGS` as
extra arguments appended to the entrypoint invocation, just before `"$@"`:

```sh
# Inside library_wrapper.sh (generated by create_wrapper.sh):
PATH="$CUSTOM_PATH" LD_LIBRARY_PATH="..." "$SNAP/entrypoint" $APP_ARGS "$@"
```

Use `APP_ARGS` in `snapcraft.yaml`'s `environment:` block to pass a fixed
argument (such as a startup script path) without patching the wrapper:

```yaml
environment:
  APP_ARGS: $SNAP/app/server.js   # passed to the OCI entrypoint at every start
```

This is the preferred way to supply entrypoint arguments for snapped OCI images.
Avoid hardcoding the path inside `library_wrapper.sh` directly; encoding it in
`environment:` keeps the recipe self-documenting and survives wrapper regeneration.

> **Note:** `APP_ARGS` is word-split by the shell. For a single path argument
> this is safe. For arguments containing spaces, wrap in quotes inside the
> `environment:` value: `APP_ARGS: '"my arg with spaces"'`.

---

## Example commands

**Docker Hub URL or image reference — download first, then extract:**
```bash
python3 <skill-dir>/scripts/download_image.py \
  "https://hub.docker.com/_/nginx" \
  --output nginx_latest.tar

./docker-to-snap \
  --tarball nginx_latest.tar \
  --application-name nginx \
  --application-version latest \
  --suppress-build
```

**Minimal — tarball filename encodes name and version:**
```bash
./docker-to-snap \
  --tarball myapp_1.2.3.tar \
  --suppress-build
```

**Tarball with non-standard filename:**
```bash
./docker-to-snap \
  --tarball myapp-image.tar \
  --application-name myapp \
  --application-version 1.2.3 \
  --suppress-build
```

**With custom output folder and service name:**
```bash
./docker-to-snap \
  --tarball myapp_1.2.3.tar \
  --output-folder /tmp/myapp-snap \
  --service-name myapp-svc \
  --suppress-build
```

**Run-to-completion (CLI / one-shot / interactive) application:**
```bash
./docker-to-snap \
  --tarball myapp_1.2.3.tar \
  --do-not-daemonize \
  --suppress-build
```

---

## Prerequisite check

Before running `docker-to-snap`, install any missing host dependencies:

```bash
python3 <skill-dir>/scripts/ensure_dependencies.py --install -y
```

The helper checks `tar`, `skopeo`, `umoci`, `jq`, and the Python YAML library
used by `scripts/patch_snapcraft.py`. If `docker-to-snap` still exits with a
clear error listing missing tools, run the helper once more and retry the
original `docker-to-snap` command. Report the exact stderr if the retry fails.
