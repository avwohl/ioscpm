# Notes for Claude on Windows

This file documents cross-platform pitfalls discovered while syncing iOSCPM
between macOS and Windows. Read this before touching files that come from
a sibling repo (`romwbw_emu` or `cpmemu`) or before committing anything that
involves symlinks or filenames.

## Symlinks: do not edit them as if they were files

Several files under `iOSCPM/Core/` are git **symlinks** (mode 120000) that
point to source files in TWO sibling repos: `romwbw_emu` (the RomWBW/HBIOS
layer) and `cpmemu` (the qkz80 CPU core). As of this writing, they include at
least:

    iOSCPM/Core/hbios_cpu.cc      -> ../../../romwbw_emu/src/hbios_cpu.cc
    iOSCPM/Core/hbios_cpu.h       -> ../../../romwbw_emu/src/hbios_cpu.h
    iOSCPM/Core/hbios_dispatch.cc -> ../../../romwbw_emu/src/hbios_dispatch.cc
    iOSCPM/Core/hbios_dispatch.h  -> ../../../romwbw_emu/src/hbios_dispatch.h
    iOSCPM/Core/qkz80.cc          -> ../../../cpmemu/src/qkz80.cc
    iOSCPM/Core/qkz80.h           -> ../../../cpmemu/src/qkz80.h

Every `qkz80*` file in `iOSCPM/Core/` is a symlink into `../../../cpmemu/src`
(11 of them at present); the rest of the 120000 entries point into
`../../../romwbw_emu/src`.

Always verify the current set with:

    git ls-files -s iOSCPM/Core/ | grep ^120000

On Windows, git by default stores symlinks as **plain text files containing
the target path** (a ~40-byte string like `../../../romwbw_emu/src/...`).
This is a footgun: it looks like a normal text file in editors and tools,
so it is very easy to overwrite the path string with actual file contents.
When that happens, git records a new blob but **leaves the file mode as
120000**. The result is a "symlink" whose target path is tens of kilobytes
of C++ source code, which fails to check out on macOS with `File name too
long` and breaks the next pull on the Mac.

This already happened once: commit 5265ad1 "Sync hbios_dispatch from
romwbw_emu" replaced the symlink target strings with the full ~93 KB of
C++ source for `hbios_dispatch.cc` and `hbios_dispatch.h`. It had to be
recovered with a plumbing-level merge (acb114b).

### Rules

1. **Never edit a 120000-mode file directly.** If you need to change the
   content, edit the real file in whichever sibling repo the symlink points
   at - `readlink` it, it is either `../romwbw_emu/src/` or `../cpmemu/src/`
   - and commit it in that repo. The symlink will pick up the change
   automatically.

2. **Never run a "sync" script that copies files into a 120000 path.**
   The point of the symlinks is that no sync is needed.

3. Before committing, run:

       git diff --cached --raw | grep ^:120000

   If any 120000 file shows up with a content change, **stop**. Inspect
   the new blob:

       git cat-file blob <new-hash> | head -3

   If it is anything other than a short relative path (under ~256 bytes),
   you have clobbered a symlink. Restore it with:

       git checkout HEAD -- <path>

4. If you actually want to enable real symlinks on Windows (requires
   Developer Mode or admin), set:

       git config core.symlinks true

   and re-checkout the affected paths. Then editors will refuse to open
   the symlink as text and the footgun goes away.

## Symlinks resolve to a working tree, not to a pinned commit

The other half of the symlink arrangement, and the one that bites on any
machine: a symlink points at a *path* in the sibling checkout, so a build
compiles whatever those working trees currently have checked out. There is no
submodule, no pinned SHA, and nothing in the Xcode project records which
sibling commit went into a build. A topic branch left checked out in
`../cpmemu` or `../romwbw_emu` ships into the app with no signal at all, and a
released build has no record of what it contains.

### What it looks like when it fires

On 2026-08-26 `romwbw_emu` committed `322ca8e`, which declared
`emu_host_file_get_read_name()` in `src/emu_io.h` and called it unconditionally
from `src/hbios_dispatch.cc` for `HBF_HOST_GETRNAME`. That is a *required*
backend function: every port has to define one or it stops linking.
`hbios_dispatch.cc` is one of the 21 symlinks under `iOSCPM/Core/`, so the new
call arrived in this port the moment that sibling checkout moved. No commit
here, no diff here, no version number anywhere that changed - the build simply
stopped linking, and the failure was the first anyone knew of it. It was the
second time the same mechanism fired in a week: `emu_host_path_caps()` did it a
few days earlier, and `49851aa` here is that fix.

The stale-checkout direction is the same hazard mirrored, and it bit at the same
time. This repo's own checkout was two commits behind its origin - sitting on
`49851aa` while origin had `15f48e9`, and `15f48e9` is the commit that defines
the getter. So the tree on disk had a core that needed the function, a port that
did not define it, and a fix that already existed on the remote. A symlink pins
nothing at either end: not the sibling it points into, and not the checkout it
points from. Pull this repo *and* check the siblings; either one alone leaves
the other half of the gap open.

One part of this does have a mechanical check, and it is cheaper than a build.
`Tests/run_tests.sh`'s `=== CoreKeyboardTests ===` suite compiles the symlinked
core against its own stub backend in `Tests/CoreKeyboardTests.cc`, so a newly
required core function fails to link there too - with no Xcode, no simulator and
no Mac. Note what that does and does not prove: it proves the *test's* stub list
is complete. Adding the stub there is a different edit from defining the real
function in `iOSCPM/Core/emu_io_ios.mm`, and only the Xcode build checks the
second one.

Which commit is behind a link, though, nothing here can see. `run_tests.sh`
checks the *shape* of the arrangement - its `=== CoreSymlinks ===` section
asserts that all 21 entries under `iOSCPM/Core/` are still mode 120000 in the
index and that none of them dangle, and the compile step that follows names its
sources through `iOSCPM/Core/` rather than reaching past it. That catches a
flattening and a missing file. It cannot catch which commit the tree behind a
link is sitting on: a symlink into a sibling parked on a topic branch resolves,
compiles and passes every test below, exactly as a correct one does. So the
check below is a habit rather than a test - nothing mechanical stands behind it,
and a green `run_tests.sh` is not evidence that it was done.

Check all three checkouts before building or releasing - this one included, for
the reason above:

    git -C . fetch && git -C . status -sb                # expect no "behind"
    git -C ../cpmemu     rev-parse --abbrev-ref HEAD     # expect main
    git -C ../romwbw_emu rev-parse --abbrev-ref HEAD     # expect main

The `fetch` is not optional: `status -sb` reports "behind" against the remote
ref this checkout last heard about, so without it a stale tree reports itself
up to date - which is exactly the state that hid the two-commit gap above.

and, if either sibling is not on its default branch, confirm the files ioscpm
actually consumes have not drifted:

    git -C ../cpmemu diff --stat main...HEAD -- 'src/qkz80*'

Do not try to automate this as an Xcode Run Script phase.
`ENABLE_USER_SCRIPT_SANDBOXING = YES` in both build configurations, and the
sibling `.git` directories lie outside `SRCROOT` and cannot be declared as
script inputs, so the phase would either fail or force sandboxing off. If a
mechanical check is wanted, it belongs in a standalone script or a pre-release
checklist run outside the build.

## Filename case: do not create case-conflicting files

macOS uses a **case-insensitive but case-preserving** filesystem by
default. `Foo.cc` and `foo.cc` are the same file there but different files
in git and on Windows/Linux. If two paths in the same directory differ
only by case, the macOS checkout will silently collapse them and you will
lose work.

### Rules

1. **Preserve the existing case of every filename.** Never rename a file
   just to change capitalization. If you must rename, do it explicitly
   with `git mv` and commit it as a deliberate rename.

2. **Never create a new file whose path differs from an existing path
   only by case.** Before adding a file, check:

       git ls-files | grep -i '^<lowercased-path>$'

   If anything matches, pick a different name or update the existing
   file.

3. The current convention in this repo (as of acb114b) is:
   - Source files in `iOSCPM/Core/` use lowercase with underscores
     (e.g., `hbios_dispatch.cc`, `romwbw_mem.h`).
   - Swift/ObjC files in `iOSCPM/` use UpperCamelCase (e.g.,
     `iOSCPMApp.swift`, `ContentView.swift`).
   - Docs in `docs/` are mixed; match whatever neighbors do, do not
     invent a new convention.

   Match the surrounding files. Do not introduce a third style.

## Line endings

This repo has no `.gitattributes`; line endings are left to whatever
`core.autocrlf` the checkout happens to use. Do not run `dos2unix`,
`unix2dos`, or "normalize line endings" across the tree. If a specific file
has wrong endings, fix that one file.

Do not add a `.gitattributes` to "protect" the symlinks either. Git does not
apply line-ending conversion to mode-120000 entries - checked empirically
with `core.symlinks=false` plus `core.autocrlf=true`, and the target string
checks out byte for byte - so a `-text` rule on `iOSCPM/Core/*` would guard
against nothing while creating one more file to keep in sync.

## When in doubt

If a commit you are about to make touches files in `iOSCPM/Core/` that came
from a sibling repo (`romwbw_emu` or `cpmemu`), or touches anything under a
120000 mode entry, **stop and ask the human** before pushing. Recovery on the
Mac side is possible but annoying (see acb114b for the playbook).
