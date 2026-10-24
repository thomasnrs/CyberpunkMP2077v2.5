# Night City Online on Cyberpunk 2077 2.5

This branch ports the Night City Online fork (which targets patch 2.31) to **patch 2.5**
(Edgerunners 2, exe 3.0.88.46235, released 2026-10-22). It boots to the multiplayer main
menu and the server runs; in-world play is still being verified.

## What changed

**RED4ext.SDK** (`vendor/RED4ext.SDK`, branch `nosso-2.5`)
- wopss `0f5eba4` (2.5 support) merged into the tiltedphoques fork. Files the fork had only
  touched through stale merge resolutions were reset to upstream.
- RED4ext.SDK#228 (KelpHect, 2.5 class layouts) merged, plus the `ArchiveScope::Mod` fix.
- Hand-decoded CyberpunkMP structs moved to 2.5 where it could be proven (TextInputWidget,
  WheeledBaseObject, `vehicle::BaseObject::physicsState`); the rest are probed at runtime.

**Client**
- `code/client/Red`: RedLib refreshed to psiberx `3fd71fe`.
- Plugin API moved to `RED4ext::v1`; `DynArray` fields became methods.
- Script bundle layouts for 2.5 (`Game/ScriptValidation.h`, from Codeware's port). The RPC
  validator asks `IsNative()` instead of reading `ScriptFunction` flags.
- Hard-coded offsets replaced: render context via `GpuApi::GetDeviceData()`, item appearance
  name from the TweakDB flat, engine start through the `TurnEngineOn` native.
- `Game/Probe.cpp` checks, once per session, layouts that headers could not pin: vehicle
  `rigidBody`, the CharacterCustomizationSystem state handle, `moveComponent` representation,
  CharacterCustomizationState arrays, and the `vtable+0x1F0` SetSimpleMovement slot (not
  called until its target is confirmed). Results go to the mod log as `[Probe]` lines.
- `InstallCrashLogger()` runs from `Main` right after bootstrap; fatal exceptions log the
  module, RVA and a stack.

## Dependencies on 2.5

Until official 2.5 releases exist, these are built from source:

| | source |
|---|---|
| RED4ext | wopss/RED4ext `main` (`47ac01c`, 2.5 support) |
| Codeware | psiberx/cp2077-codeware#63 (KelpHect) |
| TweakXL | psiberx/cp2077-tweak-xl#22 (KelpHect) |
| ArchiveXL | psiberx/cp2077-archive-xl#31 (Alexey-shishkin4) |
| redscript | v0.5.32 release (2.5 script bundles) |
| Input Loader | v0.2.3 release |

The psiberx libraries need `add_requireconfs("**.mimalloc", { version = "2.1.7", override = true })`:
tiltedcore links `mi_malloc_size`, which the mimalloc 3.x package does not export. Package them
with `tools\dist\package-mod.ps1 -ReleaseBin build\windows\x64\release` under PowerShell 7; that
step does not copy the DLL, so it is copied by hand (the packager below does this).

## Building

As in CONTRIBUTING.md, with Visual Studio Build Tools 2026 (MSVC 14.51) working as well:

```
git submodule update --init --recursive
xmake f -m release --vs_sdkver=10.0.22621.0 --game=<path to Cyberpunk2077.exe>
xmake build -j 4 Client
xmake build -j 4 Server.Native Server.Loader Server.Scripting Admin
```

## Player package

```
.\tools\port-2.5\Package-Client.ps1 [-Build]
```

Expects `..\red4ext` and `..\deps-src\<lib>` next to the repo, downloads the pinned releases
and the template saves into `..\.nco-cache`, and writes `..\nco-dist\NightCityOnline-2.5-*.zip`.
The zip holds the game-folder overlay, both template saves and a Portuguese installer
(`Instalar.bat`) that records what it copies so `Desinstalar.bat` removes exactly that.

Players launch with `--online --ip=<server> --port=11778 -skipStartScreen`. The mod's menu only
appears with `-online`; `-skipStartScreen` avoids a slow "press space" title screen.

## Known gaps

- In-world sync (remote players, vehicles, appearance) is not verified on 2.5 yet; check the
  `[Probe]` lines after the first session with two players.
- Remote vehicle simple movement is disabled until the `vtable+0x1F0` target is confirmed.
- `ScriptReport::fillErrors` is only written when the byte still looks like a bool.
