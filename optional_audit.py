#!/usr/bin/env python3
"""optional_audit.py -- fail on `optional` parameters of QC-DEFINED functions.

WHY THIS EXISTS
===============
FTEQCC's `optional` keyword is safe on BUILTINS and unsafe on everything else.
An omitted optional argument is not zero -- it is whatever the previous call
left in the parameter globals.  Three independent places in the toolchain say so:

  * qclib/qcc.h:379           - the compiler's own comment: "argument may safely
                                be omitted, FOR BUILTIN FUNCTIONS. for qc
                                functions use the defltvalue instead."
  * qcc_pr_comp.c:9186-9193   - on a short call the compiler sets `np = arg` and
                                emits OP_CALL0.  Nothing is ever stored to
                                OFS_PARM0.  (Note the `&& !optional` on 9186:
                                marking a parameter `optional` also DEFEATS a
                                declared default value, so `optional float x = 3`
                                is not a fix.)
  * pr_exec.c:553-562         - PR_EnterFunction copies f->numparms (the
                                DECLARED count, not the call's argc) words from
                                OFS_PARM0 into the locals, with no zeroing.

Builtins escape this because the VM hands them progfuncs->funcs.callargc; QC
functions have no way to ask how many arguments they actually received.

This has bitten three times in this codebase:
  1. HUD_DrawWeaponSlot's flash_red -- fixed by making it required
     (client/cl_hud.qc:828, which documents the trap).
  2. CSQC_SendHitclaim's in_hitgroup -- melee and paintball hits sent a garbage
     hitgroup, so damage multipliers landed on a random body part whenever the
     stale float happened to fall in [HITGROUP_HEAD..HITGROUP_RIGHTLEG].
  3. CSQC_MuzzleFlash's colour, plus the egon beams' end_sprite -- the whole
     arsenal flashed the wrong colour (green Python, white shotgun, ...) because
     the stale word was the calling helper's own first argument.

Every one of those survived a 0-warning build.  Hence a static check.

USAGE
=====
    python optional_audit.py            # from src/
    python optional_audit.py --list     # also print the legitimate builtin uses

Exit status 0 = clean, 1 = at least one offender.
"""
from __future__ import print_function

import os
import re
import sys

# Directories holding hand-written game code.  *_defs.qc at the top level are
# the engine-generated builtin declaration files and are exempt wholesale.
CODE_DIRS = ("client", "server", "shared", "menu")

# A function DEFINITION: a parameter list followed by a name and `= {`.
# A builtin is `... name = #123;` or `= #0:name;` and never matches this.
DEF_RE = re.compile(
    r"\(([^();{}]*?\boptional\b[^();{}]*?)\)\s*"      # param list containing `optional`
    r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{",             # name = {
    re.S,
)

# A FORWARD DECLARATION of a QC function: `... name;` with no `= #`.
FWD_RE = re.compile(
    r"\(([^();{}]*?\boptional\b[^();{}]*?)\)\s*"
    r"([A-Za-z_][A-Za-z0-9_]*)\s*;",
    re.S,
)

BUILTIN_RE = re.compile(r"=\s*#")


def strip_comments(text):
    """Remove /* */ and // so a commented-out signature never trips the audit."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def qc_sources(root):
    for d in CODE_DIRS:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirnames, filenames in os.walk(base):
            for fn in sorted(filenames):
                if fn.endswith(".qc"):
                    yield os.path.join(dirpath, fn)


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def main(argv):
    root = os.path.dirname(os.path.abspath(__file__))
    offenders = []
    scanned = 0

    for path in qc_sources(root):
        scanned += 1
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            raw = f.read()
        text = strip_comments(raw)
        rel = os.path.relpath(path, root).replace(os.sep, "/")

        for regex, kind in ((DEF_RE, "definition"), (FWD_RE, "forward decl")):
            for m in regex.finditer(text):
                params, name = m.group(1), m.group(2)
                # Guard: a forward decl that is really a builtin (`= #n`) is fine.
                tail = text[m.end() - 1 : m.end() + 40]
                if BUILTIN_RE.search(tail):
                    continue
                bad = [p.strip() for p in params.split(",") if "optional" in p]
                offenders.append(
                    (rel, line_of(text, m.start()), name, kind, bad)
                )

    if "--list" in argv:
        print("Scanned %d .qc file(s) under %s\n" % (scanned, "/".join(CODE_DIRS)))

    if not offenders:
        print("optional_audit: PASS (%d files scanned, 0 QC functions using "
              "`optional`)" % scanned)
        return 0

    print("optional_audit: FAIL -- `optional` on a QC-defined function is a "
          "read of stale parameter globals, not a zero.\n")
    for rel, line, name, kind, bad in offenders:
        print("  %s:%d  %s  (%s)" % (rel, line, name, kind))
        for p in bad:
            print("        -> %s" % p)
    print("\n%d offender(s). Make the parameter REQUIRED and pass it explicitly "
          "at every call site." % len(offenders))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
