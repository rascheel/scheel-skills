# OCI Analysis Output Contract

Use this JSON shape when writing `snap-analysis.json` for OCI input. The authoritative
machine-validated contract is `../../schema/snap-analysis.schema.json`.

```json
{
  "schema_version": "1.1",
  "project": { "name": "...", "version": "...", "summary": "...", "description": "...", "license": null, "grade": "stable | devel" },
  "snap": { "base": "core24", "confinement": "strict", "classic_reason": null },
  "build": { "plugin": "dump", "plugin_config": { "source": "<rootfs_path>", "source-type": "local" }, "build_packages": [], "stage_packages": [], "override_build_extra": null },
  "apps": [ { "name": "...", "command": "<wrapper path>", "daemon": null, "plugs": ["..."], "environment": {} } ],
  "hooks": [],
  "layouts": { "<snap-path>": { "bind": "<snap-variable-path>" } },
  "interfaces": [ { "name": "...", "apps": ["..."], "auto_connected": true, "reason": "..." } ],
  "notes": [],
  "oci": {
    "image_ref": "<pullable reference or tarball path>",
    "digest": "<sha256:... or null>",
    "config_json_path": "<path to extracted config.json>",
    "rootfs_path": "<path to extracted rootfs/>",
    "docker_to_snap_output_dir": "<output folder docker-to-snap produced>",
    "docker_to_snap_snapcraft_path": "<scaffold snapcraft.yaml path for packager to start from>",
    "target_arch": "amd64 | arm64 | armhf | i386 | ppc64el | s390x | riscv64",
    "entrypoint": ["<process.args from config.json>"],
    "working_dir": "<string or null>",
    "exposed_ports": ["<port/proto>"],
    "env": { "<KEY>": "<value>" },
    "volumes": ["<mount path>"],
    "user": { "uid": 0, "gid": 0, "username": "<string or null>", "is_root": true },
    "merged_usr": true,
    "glibc_compat": { "oci_glibc_version": "<string or null>", "base_snap_glibc_version": "<string or null>", "compatible": true, "mitigation": "rpath_embed | none" },
    "system_usernames": { "needed": false, "method": "env_var | cli_flag | setpriv_wrapper | getpwnam_hardcoded | null", "details": {} },
    "overrides_needed": [ { "part": "<part>", "phase": "build | prime", "kind": "patch_interpreter | symlink_fix | chmod | config_edit | file_inject | custom", "target_path": "<path inside rootfs>", "description": "<why>" } ],
    "content_interfaces": [ { "role": "provider | consumer", "slot_or_plug_name": "<name>", "content_label": "<label>", "path": "$SNAP_COMMON/<subpath>", "snap_name_hint": "<name>" } ],
    "config_options": [ { "key": "<snap-config-key>", "source": "env_var | config_file | cli_flag", "source_name": "<name>", "type": "port | enum | integer | path | string", "allowed_values": [], "default": "<value>", "config_file_format": "ini | yaml | json | env | null", "config_file_path": "$SNAP_COMMON/... or null", "wiring": "cli_flag | env_var | layout" } ],
    "reproducibility_baseline": { "tarball_path": "<path to reuse for re-extraction>", "extraction_command_recorded": "<docker-to-snap invocation used, for exact replay>" }
  }
}
```
