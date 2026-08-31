#!/usr/bin/env python3
"""
Server-fire reachability audit.

Under sv_trust_clienthits >= 1 (the shipped default) the server's autonomous
fire in W_WeaponFrame is switched off, and self.fire() runs only when the client
sends `cmd cs`.  That command is emitted from exactly ONE place in the tree --
SH_StandardTryFire in shared/sh_weapon_standard.qc.  There are only two
self.fire() call sites at all (the `cs` handler in sv_player.qc, and
W_WeaponFrame in sv_weapons.qc), so a weapon that hand-rolls its own try-fire
and is NOT listed in W_FireIsServerAutonomous reaches the server through neither
route: its +attack does nothing whatsoever.

That failure is silent and total -- no damage to monsters, breakables or props
(client hitclaims are rejected outside player slots), no AI_HeardGunfire, no
third-person shoot pose -- and it drifted twice before anyone noticed, because
+attack2 is NOT gated and keeps working.

This script derives the correct membership straight from the weapon sources and
compares it against W_FireIsServerAutonomous in shared/sh_weapons.qc.

Run from src/.  Exit 1 on any disagreement.

KNOWN LIMIT: a weapon whose ALT-fire uses SH_StandardTryFire while its PRIMARY
is bespoke would look "covered" to a naive text search.  The enclosing-function
tracking below exists to catch exactly that -- a call is only counted if it sits
in a function whose name doesn't look alt-only.
"""
import re
import sys
import pathlib

WEAPON_DIR = pathlib.Path("shared/weapons")
SH_WEAPONS = pathlib.Path("shared/sh_weapons.qc")

CALL = re.compile(r"\bSH_StandardTryFire(?:SemiAuto)?\s*\(")
# QC function definition header: the signature ends with `<name> =`, possibly
# after a multi-line parameter list.  e.g. `float(float now) SH_ShotgunTryFire =`
FUNC_DEF = re.compile(r"\)\s*([A-Za-z_]\w*)\s*=\s*$")
# `self.weapon = WEP_X` / `tgt.weapon = WEP_X` -- how a file declares which
# weapon(s) it implements.
WEAPON_ID = re.compile(r"\.weapon\s*=\s*(WEP_[A-Z0-9_]+)")
# "this file implements a weapon at all" -- see the note in analyse().
VIEWMODEL_ASSIGN = re.compile(r"\.weapon_viewmodel\s*=")
ALT_NAME = re.compile(r"Alt|Second|Secondary|Release", re.I)


def strip_comments(text):
    """Remove /* */ and // comments, preserving line structure."""
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"),
                  text, flags=re.S)
    return "\n".join(re.sub(r"//.*$", "", ln) for ln in text.split("\n"))


def analyse(path):
    """-> (set of WEP_ ids, has a real primary-side SH_StandardTryFire call)."""
    code = strip_comments(path.read_text(encoding="utf-8", errors="replace"))

    # NOT EVERY FILE IN shared/weapons/ IMPLEMENTS A WEAPON, and the "every
    # WEP_ id the file mentions" fallback below is catastrophic for one that
    # doesn't.  sh_wpn_csshield.qc is EQUIPMENT: no slot, no id, no fire, and a
    # SH_ShieldSuffix switch naming the eleven weapons it may be carried with.
    # It therefore claimed WEP_GLOCK, WEP_DEAGLE, WEP_CSUSP, WEP_CSP228,
    # WEP_CSFIVESEVEN, WEP_CFGLOCK and WEP_CFP228, had no try-fire of its own,
    # and so pushed all seven into `want` -- seven false FAILs that masked the
    # one real finding (WEP_CSXM1014) sitting in the same list.
    #
    # The marker is the CSQC equip: every real weapon file has exactly one
    # `self.weapon_viewmodel = ...`, and nothing else in this directory does.
    if not VIEWMODEL_ASSIGN.search(code):
        return set(), False

    ids = set(WEAPON_ID.findall(code))
    if not ids:
        # Parametrised multi-weapon files assign `.weapon = wep` from an
        # argument (sh_wpn_csgrenades.qc does this for all three CS grenades),
        # so there is no literal to find.  Every WEP_ id the file mentions is
        # one it implements -- these files don't reference other weapons.
        ids = set(re.findall(r"WEP_[A-Z0-9_]+", code))

    func = ""
    primary_call = False
    for line in code.split("\n"):
        m = FUNC_DEF.search(line.rstrip())
        if m:
            func = m.group(1)
        if CALL.search(line) and not ALT_NAME.search(func):
            primary_call = True
    return ids, primary_call


def declared_ids():
    """WEP_ ids listed inside W_FireIsServerAutonomous."""
    code = strip_comments(SH_WEAPONS.read_text(encoding="utf-8", errors="replace"))
    i = code.find("W_FireIsServerAutonomous")
    if i < 0:
        sys.exit("FAIL: W_FireIsServerAutonomous not found in shared/sh_weapons.qc")
    body = code[i:]
    end = body.find("\n};")
    if end < 0:
        sys.exit("FAIL: could not find the end of W_FireIsServerAutonomous")
    return set(re.findall(r"WEP_[A-Z0-9_]+", body[:end]))


def main():
    if not WEAPON_DIR.is_dir():
        sys.exit("FAIL: run this from src/ (shared/weapons not found)")

    listed = declared_ids()
    want = set()      # ids that MUST be listed (no primary SH_StandardTryFire)
    covered = set()   # ids that must NOT be listed
    unresolved = []

    for path in sorted(WEAPON_DIR.glob("*.qc")):
        ids, primary_call = analyse(path)
        if not ids:
            unresolved.append(path.name)
            continue
        (covered if primary_call else want).update(ids)

    # A file can legitimately share an id with another file; "needs the bypass"
    # wins, since one bespoke path is enough to strand the weapon.
    covered -= want

    missing = sorted(want - listed)
    extra = sorted(listed - want - covered)
    wrong = sorted(listed & covered)

    for name in unresolved:
        print(f"  note: no `.weapon = WEP_*` found in {name} (skipped)")

    ok = True
    if missing:
        ok = False
        print("FAIL: bespoke try-fire but NOT in W_FireIsServerAutonomous")
        print("      (these weapons' +attack never reaches the server):")
        for w in missing:
            print(f"        {w}")
    if wrong:
        ok = False
        print("FAIL: listed as server-autonomous but DOES call SH_StandardTryFire")
        print("      (the server would fire twice per shot):")
        for w in wrong:
            print(f"        {w}")
    if extra:
        # Not fatal: ids that no weapon file claims (aliases, retired weapons).
        print("  note: listed but no weapon file claims them: " + ", ".join(extra))

    if ok:
        print(f"PASS: {len(want)} server-autonomous weapons, "
              f"{len(covered)} client-notified, all consistent")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
