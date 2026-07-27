#!/usr/bin/env python3
"""Package the compiled csprogs.dat into a COMPRESSED .pk3 in the gamedir.

Why:
  FTE sends a LOOSE csprogs.dat to connecting clients *uncompressed* (~8 MB for
  this mod - see the download path in engine/server/sv_user.c SV_NextChunkedDownload,
  which SZ_Writes raw file blocks). When csprogs.dat instead lives inside a .pk3
  whose name does NOT start with "pak", the server's SV_LocateDownload redirects a
  client's "csprogs.dat" request to "package/<the pk3>" (DLERR_SV_REDIRECTPACK) and
  streams the pk3 file as-is - i.e. already zip/deflate compressed (~1.6 MB here).
  Gated only by allow_download_packages (default 1). No sv_pure needed.

Safety:
  FTE searches the loose gamedir directory BEFORE its pk3s (fs.c FS_AddPathHandle
  prepends the dir last), so a loose csprogs.dat always OVERRIDES the pk3 copy. This
  script therefore DELETES the loose csprogs.dat after packaging, so the pk3 is what
  ships. If you ever run a bare `fteqcc64 cl_progs.src` (no packaging), the fresh
  loose csprogs.dat simply overrides the now-stale pk3 -> uncompressed download but
  CORRECT code. It can never silently run stale csqc.

  The pk3 is written to a .tmp and verified (testzip + exact contents) before the
  atomic swap and before the loose file is removed, so a failure never leaves the
  gamedir without a usable csprogs.

Run from the src/ dir (compile_qc.bat does); paths are resolved relative to THIS file.
"""
import os
import sys
import zipfile

HERE  = os.path.dirname(os.path.abspath(__file__))
LOOSE = os.path.normpath(os.path.join(HERE, "..", "csprogs.dat"))
# MUST NOT start with "pak" (else allow_download_copyrighted blocks the redirect).
PK3   = os.path.normpath(os.path.join(HERE, "..", "quakers_csprogs.pk3"))


def main():
    if not os.path.isfile(LOOSE):
        # Not an error if a previous run already packaged it (pk3 present, loose gone).
        if os.path.isfile(PK3):
            print(f"[pack_csprogs] {os.path.basename(LOOSE)} absent, {os.path.basename(PK3)} "
                  f"present -- already packaged, nothing to do.")
            return 0
        print(f"[pack_csprogs] ERROR: {LOOSE} not found -- did the csprogs compile succeed?")
        return 1

    raw = os.path.getsize(LOOSE)
    tmp = PK3 + ".tmp"
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            z.write(LOOSE, "csprogs.dat")   # at the pk3 ROOT so the FS resolves "csprogs.dat"
        # Verify the archive is intact and holds EXACTLY csprogs.dat before we trust it.
        with zipfile.ZipFile(tmp) as z:
            bad = z.testzip()
            names = z.namelist()
    except Exception as e:
        if os.path.isfile(tmp):
            os.remove(tmp)
        print(f"[pack_csprogs] ERROR: packaging failed ({e}); loose csprogs.dat kept.")
        return 1

    if bad is not None or names != ["csprogs.dat"]:
        os.remove(tmp)
        print(f"[pack_csprogs] ERROR: verification failed (bad={bad!r}, names={names}); "
              f"loose csprogs.dat kept.")
        return 1

    comp = os.path.getsize(tmp)
    os.replace(tmp, PK3)   # atomic swap of the finished archive into place
    os.remove(LOOSE)       # only the pk3 ships now -> the download redirects to it (compressed)
    print(f"[pack_csprogs] csprogs.dat {raw:,} B -> {os.path.basename(PK3)} {comp:,} B "
          f"({100.0 * comp / raw:.0f}% of raw); loose csprogs.dat removed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
