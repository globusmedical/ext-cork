# Build System Modernization Plan

## Goal

Replace Cork's Makefile and obsolete Visual Studio project with a modern CMake build that
produces a real shared library from the **unmodified** Cork sources:

- Windows: `cork.dll` plus a true import library `cork.lib`, built with MSVC `cl` using the
  original Visual Studio flags. It is a drop-in replacement for the Cork package used by
  ImFusion's `IMFUSION_CORK` code path and is consumable from both the `cl`/`link` and the
  `clang-cl`/`lld-link` pipelines.
- Linux: `libcork.so.0` built with the system Clang (`libcork.so.1` from `1.0.0` on).

Release binaries are built, tested, and published by GitHub Actions on GitHub-hosted runners.
The Windows release uses the VS 2015 (v140) toolset, the same compiler family as the original
`vs14` binaries, so it can serve as reference data for a later compiler bump. Local builds use
the same CMake presets in a Visual Studio developer prompt or an activated gm-venv toolchain
environment.

The setup should stay public and plausible for contribution back to
[gilbo/cork](https://github.com/gilbo/cork).

This is a plan for iteration, not an implementation specification. It reflects the current
source tree, the toolchain patterns of `gm-sensorhub`/`gm-vcpkg-cmake`, Cork's usage in
`gm-imfusion`, and the GitHub-hosted runner images as of October 2026.

## Findings

### Root cause of the ImFusion link failure

Inspection of the deployed ImFusion package `gm-imfusion/ext/cork/1.0.0-vs14`:

| Artifact | Finding |
| --- | --- |
| `lib/Release/cork.lib` | Static archive of 10 objects, not an import library [^lib] |
| `cork.obj` in that archive | MSVC `/GL` (LTCG) object, not native COFF [^gl] |
| `bin/Release/cork.dll` | x64 PE, apparently with no exports and no imports [^pe] |
| `include/cork.h` | Identical (modulo line endings) to `src/cork.h` in this fork |
| `ext/mpir/3.0.0-vs14` | Proper `mpir.lib` import library and `mpir.dll` |

[^lib]: `llvm-ar t` lists `cork.obj`, `main.obj`, `triangle.obj`, `files.obj`, and others.
    The presence of `main.obj` suggests a locally modified Visual Studio project.
[^gl]: The member starts with an `ANON_OBJECT_HEADER` carrying the LTCG class ID, which
    `lld-link` rejects with "is not a native COFF file".
[^pe]: Read with an ad hoc PE parser, because the gm LLVM package lacks `llvm-readobj`. To be
    confirmed with `dumpbin /exports /imports` during implementation.

Consequences:

- ImFusion links Cork **statically** today. Its `PackageInfo.cmake` declares `Cork::Cork` as
  a shared imported target (`IMPORTED_IMPLIB` = `cork.lib`, `IMPORTED_LOCATION` = `cork.dll`),
  but the archive gets linked in and the shipped DLL is an empty placeholder.
- The `lld-link` error comes from the `/GL` objects in that archive, not from the compiler
  used for ImFusion. Any real import library fixes it, whichever compiler built the DLL.
- The current integration therefore does not use the LGPL shared-library mechanism.
- Because `imfusion_create_imported_target` already models Cork as a shared library, a package
  with the same layout (real import library plus exporting DLL) needs no ImFusion source or
  CMake change; only the grab package version changes.

### Consumer contract (ImFusion)

- Includes the existing `cork.h` and calls four of its seven C++-linkage free functions:
  `freeCorkTriMesh`, `computeUnion`, `computeDifference`, and `computeIntersection`
  (`isSolid` only in a commented-out block). The DLL still exports all seven.
- Input arrays are allocated and freed by ImFusion; output arrays are allocated in `cork.cpp`
  and released through `freeCorkTriMesh`. Ownership never crosses the DLL boundary, so mixing
  CRTs or compilers is safe for this API.
- `CorkTriMesh` is a POD (two `uint` counts, two pointers); no STL types cross the API. Cork
  has no exception barrier, so an exception such as `std::bad_alloc` would reach the caller,
  as with today's static link. `cl` and `clang-cl` share the MSVC exception model.
- `cork.h` does not include MPIR headers, so MPIR becomes a private, runtime-only dependency of
  `cork.dll`. ImFusion's CMake still requests the `MPIR` SOUP, which stays harmless.

### Cork sources and legacy builds

- Makefile library sources: `cork`, `util/{timer,log}`, `isct/{empty3d,quantization}`,
  `file_formats/{files,ifs,off}`, plus `isct/triangle.c` with `NO_TIMER`, `REDUCED`,
  `CDT_ONLY`, `TRILIBRARY`, and `ANSI_DECLARATORS`. The `cork` CLI compiles all of them plus
  `main.cpp`; `off2obj` is standalone. `makeConstants` holds a machine-specific GMP path.
- `main.cpp` uses internal `Files::` helpers in addition to the public API.
- Visual Studio project: VS 2012 (`v110`), Win32 only, `Application` type. All configurations
  define only `_USE_MATH_DEFINES;NOMINMAX` (no `NDEBUG`). Release: `/O2 /Oi /Gy /GL /W3`, the
  default `/MD`, debug information, and linker `/DEBUG /LTCG /OPT:REF /OPT:ICF`. Debug: `/Od`,
  `/MDd`, `/W3`, and the VS defaults for debug information and runtime checks.
- Cork has no `NDEBUG`- or `assert`-dependent code. Its `ENSURE` checks (`prelude.h`) are
  always active and call `exit(1)` on failure.
- Multiprecision: `fixint.h` and `gmpext4.h` include `mpir.h`/`mpirxx.h` on Windows and
  `gmp.h`/`gmpxx.h` elsewhere, and use `mpz_class`, so the C++ interface is required.

### Toolchain references

- `gm-vcpkg-cmake` bootstraps a toolchain through presets, a toolchain file that downloads
  private scripts, gm-venv, grab, and an internal vcpkg fork. None of that is needed here: CI
  runners ship the tools, and locally an already initialised gm-venv context can be activated
  with its `env.ps1`, `env.bat`, or `env.sh`.
- An initialised gm-venv context provides `cl.exe` 14.36 (grab `msvc-v143`), the Windows SDK,
  CMake, and Ninja. Its `VCPKG_ROOT` points to the internal vcpkg fork.
- `gm-imfusion/grab.toml` pins MSVC `14.36.32532`, Windows SDK `10.0.20348.0`, and LLVM 20.
  ImFusion compiles with `clang-cl` against that MSVC STL and runtime; `cl` 14.36.32532 is the
  MSVC compiler of its toolchain.
- `gm-sensorhub` pins vcpkg ports with `builtin-baseline` in `vcpkg.json`; its git registry in
  `vcpkg-configuration.json` covers gm packages only. This works because gm-venv always sets
  `VCPKG_ROOT` to a known checkout of the internal fork.

### GitHub-hosted runners

| | `windows-2022` | `windows-2025` | `ubuntu-24.04` |
| --- | --- | --- | --- |
| Toolchain | VS 2022 17.14, MSVC 14.44 and 14.29 | Same as 2022 | System Clang and GCC |
| Windows SDKs | 10.0.17763, 19041, 22621, 26100 | 10.0.26100 only | n/a |
| CMake / Ninja | 3.31.6 / 1.13.2 | 3.31.6 / 1.13.2 | Preinstalled |
| vcpkg | `VCPKG_INSTALLATION_ROOT` | Same | Same |

- Neither Windows image has v140 or 14.36 preinstalled. The VS 2022 installer offers both as
  components: `Microsoft.VisualStudio.Component.VC.140` (MSVC v140, VS 2015 build tools
  v14.00) and `Microsoft.VisualStudio.Component.VC.14.36.17.6.x86.x64` (out of support).
  A job can add them with `vs_installer.exe modify --add <component> --quiet`.
- The 14.36 component should install the last 17.6 servicing build, expected to be ImFusion's
  `14.36.32532`; CI checks the exact version. Whether the installer still offers SDK
  `10.0.20348` (`Microsoft.VisualStudio.Component.Windows10SDK.20348`) is checked by the spike.
- `windows-2022` is preferred for v140 because it still has older Windows SDKs.
- No hosted image has VS 2015 itself; the `windows-2019` image has been retired.

### MPIR through public vcpkg

- Port `mpir` 3.0.0 (port version 13), `supports: !(uwp | arm)`. Same upstream version as
  ImFusion's `ext-mpir 3.0.0-vs14`; 3.0.0 (2017) is MPIR's last release.
- Windows: builds MPIR's own Visual Studio projects with MSBuild (generic C, no assembly).
  With `VCPKG_PLATFORM_TOOLSET` `v140` it uses `build.vc14`, MPIR's VS 2015 projects; with
  v141 or later it uses `build.vc15`. `x64-windows` is dynamic by default.
- Linux: autotools with `--enable-cxx --enable-gmpcompat` and yasm, providing `gmp.h` and
  `gmpxx.h` as Cork expects. `x64-linux` is static by default, so a dynamic triplet is needed.
- The port refuses to build if `gmp` is installed in the same tree, and it exports no CMake
  config, so Cork needs a small find module.

## Resolved Decisions

| Topic | Decision |
| --- | --- |
| Build platform | GitHub-hosted runners, pinned `windows-2022` and `ubuntu-24.04` |
| Windows compiler | MSVC `cl` v140 if the spike passes, else v142 14.29 [^toolset] |
| ImFusion match | Comparison build with `cl` 14.36.32532, as pinned by ImFusion [^imf] |
| Newer MSVC | Not in phase 1; validated against the phase 2 golden files |
| Windows flags | Original VS flags, including `/GL` in Release [^flags] |
| Linux | System Clang; flags as in the Makefile (`-O2 -DNDEBUG`, `-Wall`) |
| `clang-cl` | Only as a test consumer, never to build Cork |
| CMake floor | `3.31...<newest tested 4.x>` [^cmake] |
| Multiprecision | MPIR 3.0.0 via Microsoft vcpkg; GMP on Linux only if MPIR fails |
| vcpkg pinning | Microsoft vcpkg as pinned default git registry [^vcpkg] |
| Local builds | Same presets in a VS developer prompt or an activated gm-venv environment |
| Bootstrap | None; the `gm-vcpkg-cmake`-style bootstrap is dropped |
| Presets | `windows-msvc-*` and `linux-clang-*` for Debug, Release, RelWithDebInfo |
| Windows exports | Module definition file with exactly the `cork.h` API |
| Linux exports | Default visibility, as with the old static library |
| ABI | MSVC C++ ABI (`cl` and `clang-cl` consumers); no `extern "C"` wrapper for now |
| CLI | Keeps the name `cork`; distinct PDB name |
| Release tools | `cork`, `off2obj`, `cork_compat` in the packages; grab takes only the library |
| Configurations shipped | Debug and Release on both platforms |
| Package layout | Per-configuration folders (`bin/<Config>`, `lib/<Config>`) [^layout] |
| MPIR runtime | Not shipped; consumers provide MPIR 3.0.0 (ImFusion: its own `ext-mpir`) |
| Versioning | `0.0.N` until mature, then `1.0.0`; `SOVERSION 0`, `1` from `1.0.0` [^version] |
| CI phases | Branch-run multi-compiler phase first, upstream-ready phase later [^phases] |
| Comparison gating | Fails only on missing results or harness errors; verdict in job summary |
| Immutable releases | Not enforced by the repository or the organisation |
| Releases | Tag-triggered; Windows and Linux packages, checksums, provenance attestations |
| Grab packaging | Manual, from the release packages |
| Compatibility test | Same-run comparison of builds; failures compared like outputs [^compat] |
| Test meshes | Generated by a committed Python script (stdlib only); no meshes in Git or LFS |
| Mesh artifacts | Inputs, outputs, and comparison report uploaded for every CI run |
| Tests | All in the fork; ImFusion meshes only run privately through the harness |
| Legacy builds | Removed in a dedicated commit after the new setup works |
| Triangle Win64 | Decided only if the stress test shows the truncation is reachable |

[^toolset]: v140 matches the original `vs14` binaries and becomes the reference data for a
    later compiler bump. The 14.29 build runs alongside as the cross-toolset comparison.
[^imf]: Shows directly whether moving Cork to ImFusion's compiler changes results. If it does
    not, 14.36 is the natural release toolset after the v140 reference phase.
[^flags]: `/GL` objects stay inside `cork.dll`. Consumers link only the import library, whose
    stubs are plain COFF, so `lld-link` is unaffected.
[^compat]: The goal is compiler compatibility, not geometric correctness: same input and seed
    give the same result or the same failure. Exact first; a tolerance only if needed, documented.
[^cmake]: No CMake 4-only feature has been identified as necessary. Presets schema version 10
    requires 3.31, which is also the CMake on the Windows runner images.
[^vcpkg]: Pinned in `vcpkg-configuration.json`, so ports come from Microsoft vcpkg at that
    commit whichever vcpkg tool runs: the runner's preinstalled one, a VS-bundled one, or a
    plain clone. gm-sensorhub uses `builtin-baseline` instead, which relies on gm-venv
    controlling `VCPKG_ROOT`.
[^layout]: Matches ImFusion's package layout, so manual grab packaging is mostly a copy. Can
    still change before `1.0.0`.
[^version]: The project version follows the release tag. `SOVERSION` is bumped to `1` by
    hand together with `1.0.0`. It only affects the Linux SONAME; the DLL name stays `cork.dll`.
[^phases]: See [CI phases](#ci-phases). Phase 1 runs manually on a work branch, without PRs.

## Proposed Design

### Ground rules

- No file under `src/` is modified. Everything needed lives in the build system, a module
  definition file, tests, or (only if agreed) separate wrapper sources.
- The library is shared only. No static Cork artifact is installed.
- The rest of this repository may change freely; the Make and Visual Studio files are removed
  in a dedicated final commit.

### New files

```text
CMakeLists.txt
CMakePresets.json
vcpkg.json                         # dependency "mpir"
vcpkg-configuration.json           # default registry: Microsoft vcpkg, pinned commit
cmake/
  CorkConfig.cmake.in
  CorkCompilerFlags.cmake          # original VS / Makefile flags
  FindMPIR.cmake                   # imported target MPIR::mpir
  cork.def                         # explicit Windows exports
  triplets/
    x64-windows-v140.cmake         # MPIR built with the v140 toolset
    x64-windows-v142.cmake         # MPIR built with the v142 (14.29) toolset
    x64-windows-v143-14.36.cmake   # MPIR built with v143 14.36, as ImFusion
.github/
  workflows/ci.yml                 # build, test, artifacts
  workflows/release.yml            # tag-triggered release
  scripts/                         # small helpers: v140 install, packaging, build-info
tests/                             # consumer, smoke, compatibility, stress
  fixtures/generate_meshes.py      # deterministic input OFFs, Python standard library only
  fixtures/inputs.sha256           # expected hashes of the generated inputs
  compat/                          # harness cork_compat and compare_results.py
```

### Library target

- `cork_objects` (OBJECT library) compiles the Makefile library sources plus `triangle.c`.
  `cork` (SHARED) links those objects; `Cork::cork` is the namespaced alias. Compiling once
  guarantees the DLL and CLI contain identical object code.
- Compile settings, all target-scoped:
  - `cxx_std_11`, C++ extensions off; C for `triangle.c`.
  - `triangle.c` only: `NO_TIMER`, `REDUCED`, `CDT_ONLY`, `TRILIBRARY`, `ANSI_DECLARATORS`.
  - Windows (MSVC `cl`), reproducing the original VS project in `CorkCompilerFlags.cmake`:
    - All configurations: `_USE_MATH_DEFINES`, `NOMINMAX`, `/W3`, and no `NDEBUG`. CMake's
      default `/DNDEBUG` and `/Ob` flags are removed for Cork targets.
    - Release: `/O2 /Oi /Gy /GL /Zi`, linked with `/DEBUG /LTCG /OPT:REF /OPT:ICF`.
    - RelWithDebInfo: identical to Release. The original Release already produced PDBs.
    - Debug: `/Od /Zi /RTC1`, linked with `/DEBUG`.
    - `MSVC_RUNTIME_LIBRARY` `MultiThreaded$<$<CONFIG:Debug>:Debug>DLL` (`/MD`, `/MDd`).
      This matches the original and ImFusion and keeps `std::rand()` state shared with the
      host (see Risks).
  - Linux (Clang), reproducing the Makefile: `-Wall`; Release and RelWithDebInfo `-O2 -DNDEBUG`
    (plus `-g` for RelWithDebInfo); Debug `-g`. `triangle.c` gets `-O2` as in the Makefile.
- `/GL` and LTCG are confined to the DLL. The installed import library contains only plain
  COFF stubs, and the exported ABI is unaffected, so `clang-cl`/`lld-link` consumers work.
- Windows exports come from `cmake/cork.def`. It lists the decorated names of the seven
  functions in `cork.h`, plus aliases if the class-key issue under Risks requires them.
  - Consumers built with `cl` or `clang-cl` reference the same MSVC-decorated names.
  - Unlike `WINDOWS_EXPORT_ALL_SYMBOLS`, internal and template symbols stay hidden, so the
    ABI is stable and minimal.
  - A test compares the export table against `cork.h`.
- Linux: default visibility, matching the old static library. SONAME and RUNPATH set by CMake.
- `VERSION` from the project version and `SOVERSION 0`: `cork.dll` on Windows, `libcork.so.0`
  on Linux. `SOVERSION` becomes `1` with release `1.0.0`.

### Executables

- `cork` CLI: target `cork_cli` with `OUTPUT_NAME cork` and `PDB_NAME cork_cli`, built from
  `main.cpp` plus `cork_objects`, as the Makefile does. `main.cpp` uses internal `Files::`
  helpers that the DLL does not export. It exports nothing, so no import library clashes.
- `off2obj`: standalone, as today.
- Both are behind `CORK_BUILD_TOOLS` (default `ON`).
- `cork_compat`: the compatibility harness (see [Compatibility test](#compatibility-test)),
  built with the tests and linked against `Cork::cork`. It is installed with the tools, so the
  released `cork.dll` can run private meshes without a local build (with an MPIR runtime such
  as ImFusion's `mpir.dll` on the `PATH`).

### Multiprecision dependency

- `vcpkg.json` declares `mpir`. `vcpkg-configuration.json` sets Microsoft vcpkg
  (`https://github.com/microsoft/vcpkg`) as the default git registry at a pinned commit; no
  other registry.
- `FindMPIR.cmake` creates `MPIR::mpir` as a shared imported target. It finds the
  `mpir.h`/`mpirxx.h` and `mpir.lib`/`mpir.dll` names on Windows and the `gmp.h`/`gmpxx.h`
  and `libmpir`/`libmpirxx` names on Linux, with Debug and Release locations. Actual file
  names are validated against the installed port.
- Cork links it `PRIVATE`. `cork.h` does not expose MPIR, so consumers need only the runtime.
- Triplets:
  - Windows: overlay triplets `x64-windows-v140`, `x64-windows-v142`, and
    `x64-windows-v143-14.36`, based on the stock `x64-windows` with `VCPKG_PLATFORM_TOOLSET`
    (and `VCPKG_PLATFORM_TOOLSET_VERSION` `14.36` for the last), so MPIR is built with the same
    toolset as Cork. Without an overlay triplet, the stock `x64-windows` uses the newest toolset.
  - Linux: the community `x64-linux-dynamic` triplet.
  - A configure-time check fails if Cork's `MSVC_VERSION` does not match the triplet's toolset.
- With v140, MPIR is built from its VS 2015 projects, presumably as ImFusion's
  `ext-mpir 3.0.0-vs14` was.
- GMP fallback on Linux: only if the MPIR 3.0.0 port fails with current Clang. It would be a
  platform-conditional dependency, documented as a deviation.

### Local builds

Release binaries come only from CI. Local builds are for development and use the same presets:

- Windows, Visual Studio: a developer prompt for the desired toolset, for example
  `vcvarsall.bat x64 -vcvars_ver=14.29`, and `VCPKG_ROOT` pointing to a vcpkg checkout.
- Windows, gm-venv: activate an initialised toolchain context with its `env.ps1` or `env.bat`
  (grab `cl` 14.36 and Windows SDK), then set `VCPKG_ROOT` to a Microsoft vcpkg clone, because
  the context's `VCPKG_ROOT` points to the internal fork. MPIR's MSBuild build with the grab
  MSVC package is unproven (see Risks).
- Linux: system Clang, autotools, and `VCPKG_ROOT`.
- `CMakeLists.txt` works with any toolchain and
  `-DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake`; presets are a convenience.

### Presets

- Schema version 10 (CMake 3.31), Ninja, per-preset build folders, and a shared install
  prefix per platform so Debug and Release land side by side.
- `windows-msvc-{debug,release,relwithdebinfo}` and `linux-clang-{debug,release,relwithdebinfo}`
  use `$env{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake`. The compiler is whatever `cl` the
  developer environment provides; the vcpkg triplet is a cache variable, overridden in CI
  (`x64-windows-v140` or `x64-windows-v142`).
- Matching build and test presets.

### Install and package export

- Per-configuration layout: `bin/<Config>/` holds `cork.dll`, its PDB, and the tools `cork`,
  `off2obj`, and `cork_compat` with their PDBs; `lib/<Config>/` holds the import library
  `cork.lib` or `libcork.so*`; `include/` holds only `cork.h`; `share/cork/` holds
  `compare_results.py`; `share/doc/cork/` holds `COPYRIGHT` (with the LGPL text).
- `CorkConfig.cmake`, `CorkConfigVersion.cmake`, and per-configuration `CorkTargets-*.cmake`
  go to `lib/cmake/Cork` and provide `Cork::cork` for both configurations.
- MPIR is not installed or packaged. Consumers provide an MPIR 3.0.0 runtime: on Windows
  `mpir.dll` next to the executable or on the `PATH`; on Linux the `libmpir` SONAME recorded in
  `build-info.json`, on the loader path. Linking against `libcork.so` on Linux may also need
  that directory in `-rpath-link`. ImFusion keeps deploying its own `ext-mpir`.
- On Linux, RUNPATH is `$ORIGIN` for the libraries and `$ORIGIN/../../lib/<Config>` for the
  tools, so `libcork.so` is found; MPIR is resolved through the normal loader search.
- In CI, tests that run installed binaries put the vcpkg MPIR runtime on `PATH` or
  `LD_LIBRARY_PATH`. The build tree uses it directly.
- The README documents the LGPL shared-library mechanism: replacing `cork.dll` or
  `libcork.so` with an interface-compatible build is the supported relinking path. It also
  points to the sources: this repository at the release tag and the vcpkg MPIR port, and states
  the required MPIR version and runtime file names.
- Each package contains `build-info.json`: compiler and linker versions, Windows SDK, CMake,
  vcpkg commit, MPIR port version and the runtime name it was linked against (`mpir.dll`,
  `libmpir.so.<N>`), runner image version, and the source commit.

### CI phases

Phase 1, development (this plan): all work happens on one branch of the fork, without PRs.

- `ci.yml` triggers on `workflow_dispatch` and on `push` to the work branch only, with a
  `concurrency` group that cancels superseded runs of the same branch.
- GitHub shows the **Run workflow** button only for workflows on the default branch. Once the
  branch push has run the workflow once, `gh workflow run ci.yml --ref <branch>` dispatches it
  on the branch without merging anything.
- Tag-triggered releases also work from the branch, because a tag push runs the workflow file of
  the tagged commit.
- The work branch is merged into the fork's default branch once phase 1 is stable.

Phase 2, stable (later, separate plan): reduced to what upstream can use.

- One Windows compiler (ImFusion's toolset at that time, 14.36 today), Linux, Debug and Release.
- Golden files replace the same-run comparison: per CRT (UCRT, glibc), because `rand()`
  sequences differ. They are seeded from the v140 results, so a newer compiler's deviations show
  up as diffs. Toolsets newer than 14.36 are confirmed against them.
- Triggers on `push` and `pull_request`; the v140 job and the multi-toolset comparison stay
  in the fork or are dropped.
- The phase 2 CMake files, tests, golden files, and workflow form the PR to
  [gilbo/cork](https://github.com/gilbo/cork).

Artifacts expire, so each phase 1 release also attaches the v140 compatibility results
(`cork-<ver>-compat-results.zip`). Phase 2 golden files are generated from them.

### CI and releases

`ci.yml` jobs in phase 1:

| Job | Runner | Content |
| --- | --- | --- |
| `fixtures` | `ubuntu-24.04` | Generates the input OFFs once, checks their hashes, uploads them |
| `windows-v140` | `windows-2022` | Install VC.140; v140 developer environment; Debug and Release |
| `windows-v142` | `windows-2022` | Preinstalled 14.29 developer environment; Debug and Release |
| `windows-v143-14.36` | `windows-2022` | Install VC 14.36, SDK 20348 if offered; Debug, Release |
| `linux` | `ubuntu-24.04` | `apt` autotools; system Clang; Debug and Release |
| `compare` | `ubuntu-24.04` | Compares all results; uploads the report, writes the job summary |

- Each build job downloads the fixtures, configures, builds, runs CTest on those inputs,
  installs Debug and Release into one prefix, writes `build-info.json`, and uploads the package
  and the compatibility results.
- `compare` runs with `if: always()`; a failed build shows up in the report as missing results.
- The job summary starts with one verdict line, followed by the per-build matrix and a list of
  differing cases:
  - **PASS**: all builds ran every case; all comparable results are identical.
  - **DIFFERENCES**: all builds ran every case; k of N comparisons differ. The job succeeds but
    emits a `::warning::` annotation, so the run overview shows it.
  - **FAILED**: a build, harness run, or upload is missing; the job fails.
- Debug versus Release differences are listed separately and never change the verdict.
- Artifacts are uploaded with `if: always()` and kept 30 days (`retention-days`), independent
  of release assets. OFF files open directly in MeshLab, inputs and results as layers:

```text
cork-fixtures/                     # the identical inputs used by every job
  manifest.json                    # cases, generator parameters, seeds, SHA-256
  <case>/a.off, <case>/b.off
cork-results-<build>/              # windows-v140-release, linux-clang-debug, ...
  build-info.json
  <case>/<op>-s<seed>.json         # outcome, exit status, stdout/stderr, hashes, duration
  <case>/<op>-s<seed>.off          # only if the operation returned a mesh
cork-compare-report/
  report.md, report.json           # pairwise matrix; summary also in the job summary
cork-package-<platform>/           # installed tree, as later released
```

- The release package comes from `windows-v140` if the spike passes, otherwise from
  `windows-v142`.
- vcpkg binary cache: the `files` provider with `actions/cache`, keyed on `vcpkg.json`,
  `vcpkg-configuration.json`, the triplet, and the toolset. MPIR is rebuilt only on changes.
- `clang-cl` consumer test: enabled on the Windows runners with their preinstalled LLVM.

`release.yml` runs on tags `v*`:

1. Calls `ci.yml` (`workflow_call`) for the tagged commit.
2. Creates a draft release and attaches `cork-<ver>-windows-x64.zip`,
   `cork-<ver>-linux-x64.tar.gz`, `cork-<ver>-compat-results.zip`, and `SHA256SUMS`.
3. Generates build provenance attestations for the packages
   (`actions/attest-build-provenance`).
4. Publishes the release; `0.0.N` releases are marked as pre-releases.

Workflow hygiene:

- `permissions: contents: read` by default; only the release job gets `contents: write`,
  `id-token: write`, and `attestations: write`.
- Third-party actions are pinned by commit SHA. No secrets are needed.
- Immutable releases are not enforced, so `0.0.N` releases and tags can be deleted. Versions
  are still never reused, so a downloaded package always matches its tag.

Spike (first CI change): on `windows-2022`, install VC.140, build MPIR with
`x64-windows-v140`, and build Cork with v140. If it fails for reasons that cannot be fixed
without changing Cork or the MPIR port, the release toolset falls back to 14.29.

### Tests

All tests live in the fork and run through CTest. Test code may seed `rand()`, reserve address
space, or inspect binaries; it never changes Cork's sources. The fixture generator and the
comparison script need Python 3 with the standard library only.

| Test | Checks |
| --- | --- |
| `exports` | `dumpbin /exports cork.dll` lists exactly the `cork.h` API (plus aliases) |
| `import_lib` | `lib /list cork.lib` lists only `cork.dll` members; no `/GL` objects |
| `dependencies` | `cork.dll` imports only `mpir.dll` and the dynamic VC/UCRT runtime |
| `consumer` | Install-tree `find_package(Cork)` project builds, links, and runs a union |
| `consumer_clang_cl` | Same project with `clang-cl`/`lld-link`; optional [^clangcl] |
| `cli_smoke` | `cork -union/-diff/-isct/-xor/-resolve` on the samples; invalid input fails [^cli] |
| `compat_run` | Harness runs all fixture cases; a second run reproduces identical results |
| `stress_win64` | Windows: harness with the low 4 GiB reserved; results match `compat_run` |

[^clangcl]: Enabled when `CORK_TEST_CLANG_CL` points to a `clang-cl`. CI uses the runner's
    preinstalled LLVM. `clang-cl` is used only to build this consumer, never Cork itself.
[^cli]: The CLI seeds `rand()` from the clock, so only exit status and output presence are
    checked. Deterministic outputs come from the harness.

#### Compatibility test

The question is whether another compiler or configuration changes Cork's observable behavior,
not whether the geometry is correct. A failure is a result like any other: two builds are
compatible when they produce the same output or fail the same way.

- Fixtures: `generate_meshes.py` writes the input OFFs, under the repository's license. It
  avoids `sin`/`cos` (rational parameterizations, integer hash noise) and emits coordinates that
  are multiples of 2^-12, so the text is exact and every platform parses the same floats.
  `inputs.sha256` detects generator drift. No mesh is committed besides the existing samples.
- Cases, kept small: `ballA`/`ballB`, overlapping icospheres, icosphere and box, box and
  rotated box, boxes sharing faces (coplanar path), torus and box, a blob offset to coordinates
  around 1000, and one finer icosphere pair (about 20k triangles each).
- Operations: union, difference in both directions, intersection, symmetric difference,
  `resolveIntersections`, and `isSolid`, each with two fixed seeds.
- Harness `cork_compat` links `Cork::cork` and has its own minimal OFF reader, because
  `Files::` is not exported. It runs one operation per process with a timeout, after
  `srand(<seed>)`, because `ENSURE` calls `exit(1)` and a crash must not end the run. Per run it
  records outcome, exit status, stdout/stderr, duration, and SHA-256 of the raw output arrays,
  and writes the output OFF with `%.9g`, which round-trips `float`.
- `compare_results.py` compares records exactly: same outcome class (result, `ENSURE` exit,
  crash, timeout), same messages, same array hashes. Hashes, not OFF text, decide equality. A
  tolerance mode (exact topology, coordinates within an epsilon relative to the bounding box)
  exists only as a documented fallback.
- Comparable builds: all Windows builds use the UCRT `rand()`, so v140, 14.29, and 14.36,
  Debug and Release, are compared against v140 Release. glibc's `rand()` differs, so Linux
  compares only Debug against Release.
- The 14.36 comparison is the one that matters most for ImFusion: it shows whether Cork built
  with ImFusion's own MSVC behaves like the v140 reference.
- Local cross-check: a build in the gm-venv environment (grab `cl` 14.36.32532) runs the same
  harness. Identical hashes to the CI 14.36 job confirm that CI used the same compiler.
- Private meshes: the harness also accepts a folder of OFF pairs, so ImFusion's meshes can be
  run locally through the same comparison without publishing them.
- Later compiler bumps: the v140 job stays in CI as the reference. If VC.140 disappears from
  the runners, the harness runs against the released v140 package instead.

Comparing against the original binaries is not possible publicly, because the shipped static
`cork.lib` is internal.

## Risks and Compatibility Notes

1. **Win64 pointer truncation in Triangle.** Triangle's memory pools store pointers in
   `unsigned long alignptr` (for example in `poolrestart`), which is 32-bit on Windows x64.
   `triangulate()` runs on the intersection path (`mesh.isct.tpp`). Heap addresses above
   4 GiB would be truncated; Linux (LP64) is not affected. The shipped vs14 x64 build has the
   same source, so behavior stays "unchanged" but may be latently unsafe. The `stress_win64`
   test shows whether it is reachable; any fix is decided only then.
2. **Randomness.** Intersection perturbation (`mesh.isct.tpp`) and BVH construction
   (`aabvh.h`) call `std::rand()`. The library never seeds it; only the CLI does. Results
   therefore depend on the host thread's CRT `rand` state, as with the old static link.
   `/MD` keeps that state shared with the host; `/MT` would silently change the sequence.
3. **Compiler code generation.** The old binaries came from MSVC v140 with `/GL`; the new DLL
   comes from v140 (VS 2015 Update 3 build tools) with the same flags, but the original's
   exact compiler update is unknown. Exact predicates use MPIR, but constructed float
   coordinates may differ in the last bits. The compatibility test shows whether they do.
4. **Class-key name decoration.** ImFusion's header forward-declares `class CorkTriMesh;`
   before including `cork.h`, which defines `struct CorkTriMesh`. MSVC name decoration
   encodes the class key (`V` versus `U`), so ImFusion objects may reference names the DLL
   does not export. To check, inspect ImFusion's `MeshBooleanOperationsAlgorithm` object with
   `dumpbin /symbols` or `llvm-nm -u`. If needed, add export aliases in `cork.def`; no source
   change is required.
5. **`ENSURE` terminates the host.** Cork's always-active `ENSURE` checks call `exit(1)`.
   This is existing behavior, unchanged by the DLL, but it now terminates ImFusion from inside
   a DLL. It is documented, not changed.
6. **v140 on a hosted runner.** Unproven combination: installing VC.140 into VS 2022 on each
   run (a few minutes), MPIR's VS 2015 projects through current vcpkg, and v140 with current
   Windows SDK headers. v140 is also out of support, which the SOUP documentation should
   mention. The spike decides; the fallback is 14.29.
7. **MPIR 3.0.0 with modern Clang on Linux.** The port uses autotools and
   `-Wno-implicit-function-declaration`; current Clang may still reject parts of it. The
   fallback is GMP on Linux.
8. **One `mpir.dll` per process.** ImFusion ships `ext-mpir 3.0.0-vs14` as `mpir.dll`. The
   new `cork.dll` is linked against vcpkg's MPIR 3.0.0 import library but loads ImFusion's
   `mpir.dll` at runtime. Same upstream version and `mpz_*` C API, so expected compatible;
   ImFusion's tests confirm it.
9. **VC runtime floor.** A DLL needs a VC runtime at least as new as its toolset: 14.0 for
   v140, 14.29 for the fallback. Both are below the 14.36 runtime of the gm toolchain.
10. **Runner image drift.** Pinned image labels still receive weekly updates (VS minor
    version, SDKs, CMake). The v140 toolset itself is fixed; `build-info.json` records the
    rest, and the compatibility comparison catches output changes.
11. **Linux glibc floor.** A library built on Ubuntu 24.04 may reference recent glibc symbol
    versions. CI records the actual floor in `build-info.json`; an older build container is
    possible if the ImFusion Linux pipeline needs one.
12. **`VCPKG_ROOT` in a gm-venv shell.** Locally, an activated gm-venv environment exports
    `VCPKG_ROOT` pointing to the internal fork. The pinned registry still selects Microsoft
    ports, but the fork's tool and scripts would run. The README tells developers to override
    it.
13. **MSBuild from the grab MSVC package.** Locally, building MPIR's Windows port with the grab
    MSVC package (`DisableRegistryUse`, no VS setup registration) is unproven. This affects only
    local gm-venv builds; CI and VS developer prompts use a registered Visual Studio.
14. **Fixture determinism.** The generator uses only IEEE double `+ - * /` and `sqrt`, and
    rounds to the 2^-12 grid, so its output should not depend on the Python build. The
    `fixtures` job generates once per run anyway, and `inputs.sha256` flags any drift.

## Commit Plan

Each commit builds and works on its own. The spike runs first on a branch with a minimal
version of commits 1 to 4; its outcome fixes the release toolset before the rest is finalised.

| # | Commit | Upstream |
| --- | --- | --- |
| 1 | CMake core: targets, original flags, `cork.def`, `FindMPIR.cmake`, install, export | Yes |
| 2 | `vcpkg.json`, `vcpkg-configuration.json`, overlay triplets (v140, v142, 14.36) | Yes |
| 3 | Presets: `windows-msvc-*`, `linux-clang-*` | Yes |
| 4 | `ci.yml` (branch push, dispatch): v140, 14.29, 14.36, Linux; artifacts, cache | No [^p1] |
| 5 | Tests, generator, harness; CTest; `fixtures` and `compare` jobs, artifacts | Yes [^t] |
| 6 | `release.yml`: packages, compat results, checksums, attestations, publish | No |
| 7 | README: build instructions, LGPL shared-library note, tested matrix, sources | Yes |
| 8 | Remove `Makefile`, `makeConstants`, and `win/wincork` | Yes |

[^t]: Upstream could take the generic tests, the generator, and the harness; the `clang-cl`
    consumer and the CI comparison jobs are fork-specific.
[^p1]: Phase 1 workflows stay in the fork. Upstream gets the phase 2 workflow instead.

After the first `0.0.N` release, outside this repository: package the release for grab
manually, bump `ext-cork` in `gm-imfusion/grab.toml`, and build ImFusion with `USE_CORK=ON` on
the clang-cl pipeline. You run this on the machine with the configured gm-imfusion build and
report issues back.

## Validation Criteria

- CI is green on `windows-2022` (v140, 14.29, 14.36) and `ubuntu-24.04` for Debug and Release.
- All CTest tests pass: exports, import library, dependencies, consumer, `consumer_clang_cl`,
  CLI smoke, `compat_run`, and stress.
- The compile commands of Cork targets show the original flags (`/O2 /Oi /Gy /GL`, `/W3`,
  `/MD`, no `NDEBUG`), and the link uses `/LTCG /OPT:REF /OPT:ICF`. `build-info.json`
  confirms the v140 compiler for the release package.
- A `0.0.1` pre-release has both packages in the per-configuration layout, including `cork`,
  `off2obj`, and `cork_compat`, `SHA256SUMS`, and attestations that verify with
  `gh attestation verify`.
- ImFusion with `USE_CORK=ON` links `ImFusionLib.dll` on the clang-cl pipeline with only the
  package version changed, and its mesh Boolean tests pass.
- Compatibility: the report shows identical outcomes for v140, 14.29, and 14.36 Release, or each
  difference is investigated and documented (tolerance or accepted deviation).
- Fixture, result, and report artifacts exist for every run, including failed ones.
- The stress test passes, or its failure is documented and decided upon.
- Linux: `libcork.so.0` has SONAME `libcork.so.0` and RUNPATH `$ORIGIN`, and passes the smoke
  tests.
- Neither package contains an MPIR file; `build-info.json` names the expected MPIR runtime.
- The `compare` job summary shows a verdict line (PASS, DIFFERENCES, or FAILED) on every run.
- CI runs on the work branch by push and by `gh workflow run --ref`, without a PR.
- Local builds with the presets work in a VS developer prompt and on Linux.
- `git diff <fork-base> -- src` is empty, and no internal URL, package name, or credential
  appears in tracked files.

## Open Questions

None. The spike decides the release toolset; the stress test decides the Triangle Win64
question. The work branch name is chosen when the first commit is pushed.

## Upstream Considerations

- Tracked files reference only public tools and services: Microsoft vcpkg, CMake, Ninja, MSVC,
  Clang, and GitHub Actions. No internal URL, registry, package name, or credential is checked
  in.
- The public API, `src/`, and the copyright and license files stay untouched.
- The CMake core, vcpkg files, presets, generic tests, README, and legacy removal are
  upstream-compatible. The phase 1 CI and release workflows are fork-specific; the upstream PR
  uses the phase 2 workflow with golden files (see [CI phases](#ci-phases)).
- Whether upstream is still maintained and accepts PRs should be checked before submitting. The
  fork stays usable on its own either way.
- The README states the tested compiler and dependency matrix, so the build migration implies
  no broader algorithmic guarantees than the original project.
