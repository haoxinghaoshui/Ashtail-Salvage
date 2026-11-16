# Z2 compressed PCK build gate

Run from the repository root in PowerShell. Supply your Godot 4.6.3 console path
and a private build directory outside `Godot/GraytailGodot`:

The same tool supports the delivery repository's `game/` layout. It resolves the
repository from the script location and requires exactly one of these two project
locations; it never selects a checkout by drive letter.

```powershell
./tools/z2/build.ps1 -Mode Refresh -GodotExe $godot -BuildRoot $scratch
./tools/z2/build.ps1 -Mode Verify -GodotExe $godot -BuildRoot $scratch
./tools/z2/build.ps1 -Mode Export -GodotExe $godot -BuildRoot $scratch -OutputPck $package
```

`Refresh` is explicit: freeze sources first. It copies the entire project with
`/E /XD .godot`, imports that mirror, computes normalized source hashes, exports
a draft with default compressed scripts (mode 2), and seals hashes of the actual
compressed script bytes into `data/z2/rule_source_digest.json`. Only that generated
JSON is copied back. Every job has separate engine/settings/temp/user-data paths;
the source project is never run. The build mirror sets the asset registry CSV to
Keep File so the translation importer cannot discard it; source import metadata
is untouched. `pck_export_preset.cfg` is copied only into the mirror (the repo
ignores project-local export presets). No export templates are needed for a PCK.

`Verify` requires a complete sealed manifest matching the current source tree.
`Export` (the default) performs that preflight, exports compressed scripts, verifies
the resulting pack and runs Main new/save/restore in two separate processes, and
only then copies it to OutputPck if supplied. The preset includes the raw asset CSV
and JSON manifests used by Main without changing any project display setting. Missing,
incomplete and stale manifests fail. Source edits during a job fail publication.
Logs, the source inventory and packs remain under the printed job directory.

Project sessions always read actual sources. Pack sessions require the JSON and
verify every covered resource's compiled byte hash. Both produce the same source
identity for checkpoint compatibility. Missing `.gd` is expected only in a pack;
it is an error in a project. Source hashes retain the existing LF normalization
and exclude only workstation `candidate_sprite_path` values. Build time, engine
version and Git revision are provenance, not gameplay identity. Working changes
are identified by the per-source hashes, so Git revision alone is not a freeze.

Refresh after **any** rule source change (and after a Godot compiler upgrade).
The checked-in JSON is a particular build sample, never a promise that concurrently
edited sources are still valid. Direct exports with a stale seal are rejected at
runtime too; disabling script compression is not a supported workaround.

Regression runners: `z2_rule_digest_runner.gd` is a normal no-argument project test.
Its optional `--source-probes` mutates and restores only a project explicitly named
by `Z2_RULE_QA_PROJECT`; use a disposable mirror. `z2_export_session_runner.gd` is
build/PCK acceptance, not a single-call full-suite runner: it requires a fresh
`Z2_EXPORT_QA_HOME` containing user data, then `--record` and `--restore` in separate
processes sharing that data. Export invokes this pair automatically; tests themselves
are excluded from the PCK. Do not count project-only execution as PCK acceptance.
