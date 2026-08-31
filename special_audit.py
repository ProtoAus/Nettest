#!/usr/bin/env python3
"""special_audit.py — weapon-special (impulse 7) dispatch audit.

CSQC's `case WEAPON_IMPULSE_SPECIAL` in client/cl_weapons.qc is a HAND-WRITTEN
`else if (self.weapon == WEP_X)` chain, not a function-pointer dispatch like
.fire / .reload.  A weapon that binds `self.special` in its server Equip and is
not on that chain gets: impulse 7 reaches the server, the action runs, damage and
sound land -- and the viewmodel never moves, because the server-only WS_SPECIAL
never reaches predicted_player.

That failure mode has shipped three times now (three DoD bayonets, the jetpack's
boost level, and the five +attack2 deployables that bound no .special at all), and
it is invisible from either end: the server code is complete and the client code
is complete, they just do not know about each other.

This script fails if:
  (A) a weapon binds .special server-side but has no arm on the CSQC chain, or
  (B) a weapon's CSQC arm calls a CSQC_Predict*Special that does not exist, or
  (C) such a predictor exists but has an EMPTY body (the scoped K98 shipped that
      way -- "a prediction function that nothing calls is a function that
      silently does nothing", sh_wpn_dodk43.qc).

Deliberate absences go in KNOWN_UNPREDICTED with the reason.

Run from quakers/src, alongside cvar_audit.py / check_serverfire.py /
optional_audit.py / proxy_audit.py.
"""
import os
import re
import sys

SRC = os.path.dirname(os.path.abspath(__file__))
WEAPON_DIR = os.path.join(SRC, "shared", "weapons")
CL_WEAPONS = os.path.join(SRC, "client", "cl_weapons.qc")

# Weapons whose .special is deliberately NOT predicted, with the reason.  Each
# entry is a promise that the omission was checked, not that it was missed.
KNOWN_UNPREDICTED = {
    "WEP_GRAVITYGUN":
        "W_GravGun_ToggleShift flips .gravshift_toggle and sets no weaponstate, "
        "so there is no viewmodel take to miss; everything it drives lives in "
        "GravShift_UpdateActivation, which is #ifdef SSQC and owns a server-global "
        "direction latch.  One snapshot late, not broken.",
}


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_comments(text):
    """Remove // and /* */ so a commented-out binding is not counted."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def weapon_files():
    for name in sorted(os.listdir(WEAPON_DIR)):
        if name.endswith(".qc"):
            yield os.path.join(WEAPON_DIR, name)


def enclosing_function(raw, pos):
    """Name of the QC function whose body contains `pos`, or None.

    QC has no nesting, so the nearest preceding `void() Name =` (or
    `void(args) Name =`) is the enclosing one.
    """
    best = None
    for m in re.finditer(r"\bvoid\s*\([^)]*\)\s*(\w+)\s*=", raw):
        if m.start() > pos:
            break
        best = m.group(1)
    return best


def find_special_binders():
    """{WEP_CONST: (file, handler)} for every `self.special = Handler;`.

    THE WEP_ CONSTANT IS DERIVED THROUGH THE EQUIP FUNCTION, not by scraping the
    file for WEP_ ids.  Scraping is catastrophic here for the same reason it is in
    check_serverfire.py: sh_wpn_snowball.qc names fifteen other weapons in its
    utility-cycle tables and would claim every one of them, and its own
    `weapon_slingshot` spawner sets `.weapon = WEP_SLINGSHOT` on a pickup whose
    weap_draw is __NULL__ — an upgrade, not an equippable weapon.

    So: find the equip function that contains the binding, then find the world
    entity / drop blocks that name that function as their weap_draw, and read the
    `.weapon = WEP_X` out of the same block.
    """
    out = {}
    for path in weapon_files():
        raw = strip_comments(read(path))
        fname = os.path.basename(path)

        equips = set()
        handler = None
        for m in re.finditer(r"self\.special\s*=\s*(\w+)\s*;", raw):
            if m.group(1) == "__NULL__":
                continue
            handler = handler or m.group(1)
            fn = enclosing_function(raw, m.start())
            if fn:
                equips.add(fn)
        if not equips:
            continue

        # Every `.weapon = WEP_X` literal in the file, with its position, so an
        # equip can be paired with the NEAREST one rather than with everything
        # inside a fixed window — weapon_snowball and weapon_slingshot are 30
        # lines apart in the same file and only the first has a weap_draw.
        wep_sites = [(m.start(), m.group(1)) for m in
                     re.finditer(r"\.weapon\s*=\s*(WEP_[A-Z0-9_]+)", raw)]

        weps = set()
        for eq in equips:
            for m in re.finditer(r"\w*\.?weap_draw\s*=\s*" + re.escape(eq) + r"\s*;",
                                 raw):
                near = [(abs(p - m.start()), w) for p, w in wep_sites
                        if abs(p - m.start()) < 900]
                if near:
                    weps.add(min(near)[1])
        # Parametrised multi-weapon files (the three DoD MGs, the Bren/FG42 pair)
        # assign `.weapon = wep` from a local, so there is no literal to pair
        # with.  For those the file's own WEP_ ids ARE the weapons it implements —
        # the same fallback, and the same reasoning, as check_serverfire.py's.
        if not weps:
            weps = set(re.findall(r"\bWEP_[A-Z0-9_]+\b", raw))
        weps.discard("WEP_NONE")

        if not weps:
            print(f"  note: {fname} binds .special but no WEP_ id could be paired "
                  f"with its equip (skipped)")
            continue
        for w in weps:
            out.setdefault(w, (fname, handler))
    return out


def find_chain_arms():
    """{WEP_CONST: predictor} parsed out of the WEAPON_IMPULSE_SPECIAL case."""
    raw = strip_comments(read(CL_WEAPONS))
    start = raw.find("case WEAPON_IMPULSE_SPECIAL:")
    if start < 0:
        sys.exit("FAIL: no `case WEAPON_IMPULSE_SPECIAL:` in client/cl_weapons.qc")
    # The arm runs to the next `case ` at the same switch level.
    end = raw.find("case ", start + 10)
    body = raw[start:end if end > 0 else len(raw)]

    arms = {}
    # Each arm is `if (...conditions...) Predictor();` possibly with || chains.
    for cond, call in re.findall(
            r"if\s*\(([^)]*(?:\)[^)]*\()*[^)]*)\)\s*\n?\s*(\w+)\s*\(\s*\)\s*;", body):
        for w in re.findall(r"\bWEP_[A-Z0-9_]+\b", cond):
            arms[w] = call
    return arms, body


def predictor_bodies():
    """{name: body-text} for every CSQC_Predict*Special in shared/weapons."""
    out = {}
    for path in weapon_files():
        raw = read(path)
        for m in re.finditer(r"void\s*\(\s*\)\s*(CSQC_\w*Special)\s*=\s*\{", raw):
            name = m.group(1)
            i = m.end() - 1
            depth = 0
            for j in range(i, len(raw)):
                if raw[j] == "{":
                    depth += 1
                elif raw[j] == "}":
                    depth -= 1
                    if depth == 0:
                        out[name] = raw[i + 1:j]
                        break
    return out


def main():
    binders = find_special_binders()
    arms, body = find_chain_arms()
    bodies = predictor_bodies()

    failures = []

    for wep, (fname, handler) in sorted(binders.items()):
        if wep in arms:
            continue
        if wep in KNOWN_UNPREDICTED:
            continue
        failures.append(
            f"{wep} binds .special = {handler} in {fname} but has NO arm on the "
            f"WEAPON_IMPULSE_SPECIAL chain in client/cl_weapons.qc.\n"
            f"      The action will run server-side and the viewmodel will not move.")

    for wep, call in sorted(arms.items()):
        if call not in bodies:
            # Predictors may also live in client/ — only flag a name nothing defines.
            if not re.search(r"\b" + re.escape(call) + r"\s*=", read(CL_WEAPONS)):
                failures.append(
                    f"{wep}'s chain arm calls {call}(), which is not defined in "
                    f"shared/weapons or client/cl_weapons.qc.")
            continue
        if not bodies[call].strip():
            failures.append(
                f"{wep}'s predictor {call}() has an EMPTY BODY — it is on the chain "
                f"and does nothing, which reads exactly like a working arm.")

    # Report the deliberate omissions so they stay visible rather than silent.
    for wep, why in sorted(KNOWN_UNPREDICTED.items()):
        if wep in binders and wep not in arms:
            print(f"  deliberate: {wep} unpredicted — {why.splitlines()[0]}")

    print(f"\n.special binders: {len(binders)}   chain arms: {len(arms)}   "
          f"predictors defined: {len(bodies)}")

    if failures:
        print("\nFAIL:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("\nOK: every weapon that binds .special is predicted on the "
          "WEAPON_IMPULSE_SPECIAL chain")
    return 0


if __name__ == "__main__":
    sys.exit(main())
