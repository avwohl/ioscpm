# Notes for Claude on Windows

This file documents cross-platform pitfalls discovered while syncing iOSCPM
between macOS and Windows. Read this before touching files that come from
the sister `romwbw_emu` repo or before committing anything that involves
symlinks or filenames.

## Symlinks: do not edit them as if they were files

Several files under `iOSCPM/Core/` are git **symlinks** (mode 120000) that
point to source files in the sister `romwbw_emu` repo. As of this writing,
they include at least:

    iOSCPM/Core/hbios_cpu.cc      -> ../../../romwbw_emu/src/hbios_cpu.cc
    iOSCPM/Core/hbios_cpu.h       -> ../../../romwbw_emu/src/hbios_cpu.h
    iOSCPM/Core/hbios_dispatch.cc -> ../../../romwbw_emu/src/hbios_dispatch.cc
    iOSCPM/Core/hbios_dispatch.h  -> ../../../romwbw_emu/src/hbios_dispatch.h

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
   content, edit the real file in `../romwbw_emu/src/` and commit it in
   that repo. The symlink will pick up the change automatically.

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
     `AppDelegate.swift`, `ContentView.swift`).
   - Docs in `docs/` are mixed; match whatever neighbors do, do not
     invent a new convention.

   Match the surrounding files. Do not introduce a third style.

## Line endings

Git is configured to handle line endings via `.gitattributes` where it
matters. Do not run `dos2unix`, `unix2dos`, or "normalize line endings"
across the tree. If a specific file has wrong endings, fix that one file.

## When in doubt

If a commit you are about to make touches files in `iOSCPM/Core/` that
came from `romwbw_emu`, or touches anything under a 120000 mode entry,
**stop and ask the human** before pushing. Recovery on the Mac side is
possible but annoying (see acb114b for the playbook).
