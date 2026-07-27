#!/usr/bin/env python3
"""cvar_audit.py - cross-check shared/sh_cvar_table.qc against what the QC actually does.

The cvar table is the mod's single source of truth: it drives registercvar() per VM,
the settings menu, the Create Server screen, data/server.cfg and data/allcommands.cfg.
Nothing enforces that it matches the code, so it drifts in four ways.  This finds all
four:

  MISSING    a cvar the QC reads that no CVar_Add ever registers.  Reads as 0 / "".
  UNDER      registered CVAR_SIDE_CL but SSQC executes it (or vice versa).  The VM that
             wasn't registered reads 0 -- on a REMOTE client, not on a listen server,
             which is why these survive local testing.
  OVER       registered for a VM that never reads it.  Harmless, but it is how the
             cl_player_spine_*_upper_scale client/server mismatch happened.
  CFG-DIFF   data/default.cfg disagrees with the table's default, or holds a value that
             would parse to multi-token garbage (a comment missing its //).

Two things are essential and easy to get wrong:

  * COMMENTS.  sh_pmove.qc documents its workarounds with the literal text
    cvar("sv_func_tickrate") inside a // comment.  A naive scan counts that as a read
    and reports a bug in code that is already correct.
  * #ifdef.   Shared files compile into several VMs, but a cvar read inside
    #ifdef SSQC is unreachable from CSQC.  Ignoring the guards roughly doubles the
    false-positive count.

Known limitation: names built at runtime (strcat) are invisible to a static scan --
that covers the ADS_RegisterPoseCvars set (cl_ads_*, <weapon>_pitch/yaw/...).

Usage:
    python cvar_audit.py                 # report, exit 1 if anything is wrong
    python cvar_audit.py --report FILE   # also write a markdown report
    python cvar_audit.py --quiet         # exit code only
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TABLE = os.path.join(HERE, "shared", "sh_cvar_table.qc")
CFG = os.path.normpath(os.path.join(HERE, "..", "data", "default.cfg"))

VMS = ("CSQC", "SSQC", "MENU")
PROGS = {"SSQC": "sv_progs.src", "CSQC": "cl_progs.src", "MENU": "m_progs.src"}

# Which VM a CVAR_SIDE_* value promises registration for.  MENU is deliberately absent:
# CVar_RegisterMine only ever registers CVAR_SIDE_SV rows in the menu VM (see the
# comment above it), so menu-only reads are never counted as a side error.
DECLARES = {
    "CVAR_SIDE_CL": {"CSQC"},
    "CVAR_SIDE_SV": {"SSQC"},
    "CVAR_SIDE_BOTH": {"CSQC", "SSQC"},
}

# Cvars the ENGINE owns.  The mod reads them but must not register them: registercvar
# is a no-op on an existing cvar anyway, and putting them in the table would dump
# engine settings into allcommands.cfg and let CVar_ForceDefaults stomp a user's
# config.  Every name here was verified present in the FTE source
# (C:\msys64\home\Lex\fteqw\engine) -- regenerate with:
#   for n in ...; do grep -rqs "\"$n\"" --include=*.c <engine> && echo $n; done
ENGINE_CVARS = {
    "chase_active", "chase_back", "chase_right", "chase_up",
    "cl_backspeed", "cl_forwardspeed", "cl_sidespeed", "cl_upspeed",
    "cl_launchintogame", "cl_netfps", "cl_servername",
    "developer", "fov", "name", "rate", "rcon_password", "sensitivity",
    "net_qwmaster1", "net_qwmaster2", "net_qwmaster3",
    "r_decal_lightmap", "r_meshpitch", "r_meshroll", "r_part_maxparticles",
    "r_ragdoll_timescale", "r_shadow_realtime_dlight", "r_shadows",
    "r_shadows_throwdirection", "r_showragdoll", "r_skel_blendnormalize",
    "r_skybox", "r_sun_dir", "r_waterripple_react",
    "sv_cheats", "sv_maxrate",
    "sv_gameplayfix_setmodelrealbox", "sv_gameplayfix_setmodelsize_qw",
    "pr_checkextension",            # capability probe, not a real cvar
}

# Mod cvars that intentionally live outside the table.  Transient QC-to-QC signalling
# flags (leading _ or *_pending) are set by code, never configured by a player, and a
# table row would push them into allcommands.cfg and the settings menu.
NOT_SETTINGS = {
    "_map_sun_active",          # stuffed per-map by sv_env_sun
    "sv_backdrop_pending",      # worldspawn handshake, cleared the same frame
    "sv_physics_engine",        # set outside the QC (engine/plugin selection)
    # Headless harness hook: `+set cl_paint_autotest <tex>` on the command line makes
    # the client join, paint, condump and QUIT.  Deliberately left unregistered so it
    # can never appear in allcommands.cfg or a menu where it could be set by accident;
    # cvar_string() on an unregistered cvar returns "" which is exactly the disarmed
    # state Paint_AutoTestFrame checks for.
    "cl_paint_autotest",
}

# Table rows the ENGINE itself registers (CVAR*/Cvar_Get in the FTE source).  The table
# lists them so they can appear in the settings / Create Server menus, but registercvar
# is a NO-OP on a cvar the engine already created -- so for these rows the table default
# only takes effect through CVar_DoRegister's empty-string fallback, or because
# data/default.cfg or the generated data/server.cfg sets them explicitly.
#
# THE PRACTICAL RULE: never remove one of these from data/default.cfg.  The QC cannot
# apply the value; the cfg line is the only thing that does.  (r_renderscale,
# gl_texturemode and the cl_voip_* family are the ones this actually bites.)
#
# Note that cl_player_spine_* are NOT here: the engine's Alias_SpineBend_Tune reads them
# via Cvar_FindVar but never creates them, so QC still owns those defaults.
#
# Regenerate by extracting CVAR*("name" / Cvar_Get("name" from the engine tree and
# intersecting with the table.
ENGINE_OWNED_ROWS = {
    "cl_debug_spike_ms", "cl_debug_spikes", "cl_idlefps", "cl_maxfps",
    "cl_voip_autogain", "cl_voip_bitrate", "cl_voip_capturedevice",
    "cl_voip_capturingvol", "cl_voip_codec", "cl_voip_ducking",
    "cl_voip_micamp", "cl_voip_noisefilter", "cl_voip_play", "cl_voip_send",
    "cl_voip_showmeter", "cl_voip_test", "cl_voip_vad_threshhold",
    "cl_yieldcpu", "fraglimit", "gl_texturemode", "gl_texturemode2d",
    "hostname", "maxclients", "password", "physics_ode_trimesh_from_hull",
    "physics_ode_use_decomp", "r_renderscale", "r_viewmodel_maxlight",
    "sv_accelerate", "sv_airaccelerate", "sv_antilag", "sv_bigcoords",
    "sv_friction", "sv_gravity", "sv_maxspeed", "sv_maxtic",
    "sv_maxvelocity", "sv_mintic", "sv_nqplayerphysics", "sv_port",
    "sv_prop_collision", "sv_prop_decomp", "sv_prop_decomp_concavity",
    "sv_prop_hull_exclude", "sv_pure", "sv_stopspeed", "sv_voip",
    "sv_voip_echo", "sv_voip_record", "sv_wateraccelerate",
    "sv_waterfriction", "sys_clockprecision", "sys_clocktype",
    "sys_framepacing", "sys_highpriority", "vid_conautoscale",
}

# Known, accepted side gaps: server-authoritative values that CSQC also reads.  On a
# LISTEN server there is one cvar space so SSQC's registration covers both VMs; only a
# REMOTE client sees 0, and each of these already has a hardcoded fallback at the call
# site (sv_gravity -> 800, etc).  Flipping them to BOTH would NOT fix it -- the client
# would then read the TABLE default instead of the server's live value, turning an
# obvious 0 into a silent desync.  The real fix is stat/serverinfo replication, the way
# sv_func_tickrate already does it via STAT_FUNC_TICKRATE (see sh_pmove.qc).  Reported
# as informational; they do not fail the run.
DEFER_REPLICATION = {
    "mp_friendlyfire", "pm_ramp_bumpcount", "sv_anim_qu_per_sec",
    "sv_anim_qu_per_sec_crouch", "sv_car_accel", "sv_car_damping", "sv_car_grip",
    "sv_car_model_yaw", "sv_car_suspension_softness", "sv_gravity", "sv_gunkick",
    "sv_gunkick_strength", "sv_mintic", "sv_paintball_projectile",
    "sv_player_basebone", "sv_shiftspeed", "sv_sprintdisableshooting",
    "sv_trust_clienthits",
}

CVAR_REF = re.compile(
    r'cvar(?:_string|_set|_type|_defstring)?\s*\(\s*"([A-Za-z_][A-Za-z0-9_]*)"')
CVAR_ADD = re.compile(
    r'CVar_Add(UI|Saved)?\s*\(\s*"([^"]*)"\s*,\s*"([^"]+)"\s*,\s*"([^"]*)"\s*,'
    r'\s*(CVAR_SIDE_[A-Z]+)')
REGISTERCVAR = re.compile(r'registercvar\s*\(\s*"([A-Za-z_][A-Za-z0-9_]*)"')
PREPROC = re.compile(r'^\s*#\s*(ifdef|ifndef|if|elif|else|endif)\b\s*(.*)$')

# Console commands in default.cfg that are not cvar assignments.  fog/waterfog take
# several bare args (density + rgb + ...), so without this they look like a cvar whose
# value has trailing garbage.
NOT_ASSIGNMENTS = {"exec", "alias", "bind", "unbind", "unbindall", "echo", "wait",
                   "toggle", "cmd", "connect", "map", "impulse", "fog", "waterfog",
                   "skybox"}


# ---------------------------------------------------------------- source scanning

def strip_comments(text):
    """Blank out // and /* */ comments, leaving line structure intact.

    String literals are left alone -- a // inside a string is not a comment, and cvar
    names live in strings, so mangling them would lose real reads.
    """
    out = []
    i, n = 0, len(text)
    in_block = in_str = False
    while i < n:
        c = text[i]
        if in_block:
            if text.startswith("*/", i):
                in_block = False
                i += 2
                continue
            out.append("\n" if c == "\n" else " ")
            i += 1
        elif in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            in_block = True
            i += 2
        else:
            if c == '"':
                in_str = True
            out.append(c)
            i += 1
    return "".join(out)


def reachable_refs(path, vm):
    """cvar names this file can actually execute when compiled with `vm` defined.

    Tracks #ifdef nesting as a stack of True / False / None, where None means the
    symbol is not a VM gate (SOLIDBRUSH_EF_ADDITIVE etc.) and the block is assumed
    reachable -- conservative, so we never invent a missing registration.
    """
    found = set()
    stack = []
    for line in strip_comments(open(path, encoding="utf-8", errors="replace").read()).split("\n"):
        m = PREPROC.match(line)
        if m:
            kind, rest = m.group(1), m.group(2).strip()
            sym = (rest.split()[0] if rest else "").strip("()!")
            if kind in ("ifdef", "ifndef", "if"):
                if sym in VMS:
                    stack.append((sym != vm) if kind == "ifndef" else (sym == vm))
                else:
                    stack.append(None)
            elif kind == "elif":
                if stack:
                    stack[-1] = None          # can't evaluate; assume reachable
            elif kind == "else":
                if stack and stack[-1] is not None:
                    stack[-1] = not stack[-1]
            elif kind == "endif":
                if stack:
                    stack.pop()
            continue
        if all(s is not False for s in stack):
            found.update(CVAR_REF.findall(line))
    return found


def progs_members(name):
    path = os.path.join(HERE, name)
    out = set()
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line.endswith(".qc"):
            out.add(os.path.normpath(line))
    return out


def scan_sources():
    """{cvar: {vm: {file, ...}}} for every reachable cvar read, plus registercvar names."""
    members = {vm: progs_members(src) for vm, src in PROGS.items()}
    uses, hand_registered = {}, set()
    for root, dirs, files in os.walk(HERE):
        dirs[:] = [d for d in dirs if d not in ("ftedefs", "genericdefs", "__pycache__")]
        for fn in files:
            if not fn.endswith(".qc"):
                continue
            full = os.path.join(root, fn)
            rel = os.path.normpath(os.path.relpath(full, HERE))
            if rel.endswith("sh_cvar_table.qc"):
                continue
            body = strip_comments(open(full, encoding="utf-8", errors="replace").read())
            hand_registered.update(REGISTERCVAR.findall(body))
            for vm in VMS:
                if rel not in members[vm]:
                    continue
                for name in reachable_refs(full, vm):
                    uses.setdefault(name, {}).setdefault(vm, set()).add(rel)
    return uses, hand_registered


def read_table():
    """{cvar: (section, default, side, line, is_ui)} in declaration order."""
    text = open(TABLE, encoding="utf-8", errors="replace").read()
    out = {}
    for m in CVAR_ADD.finditer(text):
        out[m.group(3)] = (m.group(2), m.group(4), m.group(5),
                           text.count("\n", 0, m.start()) + 1, m.group(1) == "UI")
    return out


def read_cfg():
    """{cvar: (line_no, value, raw_tail)} for assignments in default.cfg.

    r_part blocks are skipped: they are particle definitions in braces, not cvars.
    raw_tail is whatever followed the value -- non-empty means the line has trailing
    tokens that are almost certainly a comment missing its //.
    """
    out = {}
    in_part = False
    for no, raw in enumerate(open(CFG, encoding="utf-8", errors="replace"), 1):
        line = raw.split("//")[0].strip()
        if not line:
            continue
        if line.startswith("r_part"):
            in_part = "namespace" not in line
            continue
        if in_part:
            if line == "}":
                in_part = False
            continue
        tok = line.split()
        if tok[0].lower() in NOT_ASSIGNMENTS:
            continue
        if tok[0].lower() in ("set", "seta"):
            if len(tok) < 3:
                continue
            name, rest = tok[1], line.split(None, 2)[2]
        elif len(tok) >= 2 and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", tok[0]):
            name, rest = tok[0], line.split(None, 1)[1]
        else:
            continue
        rest = rest.strip()
        if rest.startswith('"'):                      # quoted: value is the whole string
            end = rest.find('"', 1)
            value, tail = (rest[1:end], rest[end + 1:].strip()) if end > 0 else (rest.strip('"'), "")
        else:
            parts = rest.split(None, 1)
            value, tail = parts[0], (parts[1].strip() if len(parts) > 1 else "")
        out[name] = (no, value, tail)
    return out


# ---------------------------------------------------------------- checks

def audit():
    uses, hand_registered = scan_sources()
    table = read_table()
    cfg = read_cfg()
    r = {"missing": [], "under": [], "over": [], "cfg_diff": [], "cfg_malformed": [],
         "deferred": [], "cfg_shadow": [], "table": table, "cfg": cfg, "uses": uses}

    for name, vms in sorted(uses.items()):
        # hand_registered covers the menu VM's own registercvar() calls -- the table
        # has no CVAR_SIDE_MENU, so menu-only cvars legitimately live in m_main.qc.
        if (name in table or name in hand_registered
                or name in ENGINE_CVARS or name in NOT_SETTINGS):
            continue
        r["missing"].append((name, sorted(vms), sorted(set().union(*vms.values()))))

    for name, (section, default, side, line, is_ui) in sorted(table.items()):
        used = set(uses.get(name, {})) - {"MENU"}
        if not used:
            continue
        declared = DECLARES[side]
        missing_side = used - declared
        extra_side = declared - used
        if missing_side:
            where = sorted(set().union(*[uses[name][v] for v in missing_side]))
            bucket = "deferred" if name in DEFER_REPLICATION else "under"
            r[bucket].append((name, side, sorted(used), line, where))
        elif extra_side and not is_ui:
            # CVar_AddUI rows are deliberately BOTH even when only one VM reads them:
            # the F2 server panel runs in CSQC and falls back to a local cvar() read
            # when the server hasn't pushed serverinfo for that knob, so the row has
            # to exist client-side to show its default.  Documented at the
            # sv_debug_ent_types and sv_physprop_weapon_* rows.  Only plain
            # CVar_Add / CVar_AddSaved rows can be genuinely over-registered.
            r["over"].append((name, side, sorted(used), line))

    for name, (no, value, tail) in sorted(cfg.items()):
        if tail:
            r["cfg_malformed"].append((name, no, value, tail))
        if name in table and table[name][1] != value:
            r["cfg_diff"].append((name, no, table[name][1], value, table[name][3]))
        # A mod cvar set in default.cfg SHADOWS its table default: the cfg is exec'd
        # before csprogs loads and registercvar won't overwrite an existing cvar, so
        # the table row becomes dead weight on clients while dedicated servers (no
        # menu VM, never exec this file) use the table.  That split is the bug this
        # check exists to prevent.  Engine-registered rows are exempt -- for those the
        # cfg line is the ONLY thing that can apply the value.
        if name in table and name not in ENGINE_OWNED_ROWS:
            r["cfg_shadow"].append((name, no, table[name][3]))
    return r


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--report", metavar="FILE", help="write a markdown report")
    ap.add_argument("--quiet", action="store_true", help="exit code only")
    args = ap.parse_args()

    r = audit()
    bad = (len(r["missing"]) + len(r["under"]) + len(r["over"])
           + len(r["cfg_diff"]) + len(r["cfg_malformed"]) + len(r["cfg_shadow"]))

    if not args.quiet:
        print("table entries      : %d" % len(r["table"]))
        print("default.cfg assigns: %d" % len(r["cfg"]))
        print("cvars read by QC   : %d" % len(r["uses"]))
        print()
        if r["cfg_malformed"]:
            print("MALFORMED in default.cfg (trailing tokens - comment missing '//'): %d"
                  % len(r["cfg_malformed"]))
            for name, no, value, tail in r["cfg_malformed"]:
                print("  default.cfg:%-5d %-38s value=%r  trailing=%r" % (no, name, value, tail))
            print()
        if r["missing"]:
            print("MISSING registration (QC reads it, no CVar_Add): %d" % len(r["missing"]))
            for name, vms, where in r["missing"]:
                print("  %-38s read-by=%-11s %s" % (name, ",".join(vms), where[:2]))
            print()
        if r["under"]:
            print("UNDER-REGISTERED (a VM executes it but never registers it): %d" % len(r["under"]))
            for name, side, used, line, where in r["under"]:
                print("  L%-5d %-38s decl=%-14s reads=%-11s %s"
                      % (line, name, side, ",".join(used), where[:2]))
            print()
        if r["over"]:
            print("OVER-REGISTERED (registered for a VM that never reads it): %d" % len(r["over"]))
            for name, side, used, line in r["over"]:
                print("  L%-5d %-38s decl=%-14s only-read-by=%s"
                      % (line, name, side, ",".join(used)))
            print()
        if r["cfg_diff"]:
            print("default.cfg DISAGREES with the table: %d" % len(r["cfg_diff"]))
            for name, no, tdef, cval, tline in r["cfg_diff"]:
                print("  %-38s table:%-5d %-20r cfg:%-5d %r" % (name, tline, tdef, no, cval))
            print()
        if r["cfg_shadow"]:
            print("default.cfg SHADOWS the table (mod cvars must not be set there): %d"
                  % len(r["cfg_shadow"]))
            for name, no, tline in r["cfg_shadow"]:
                print("  default.cfg:%-5d %-38s shadows sh_cvar_table.qc:%d"
                      % (no, name, tline))
            print()
        if r["deferred"]:
            print("info: %d server-authoritative cvars are also read by CSQC and need"
                  % len(r["deferred"]))
            print("      stat/serverinfo replication, not registration -- see"
                  " DEFER_REPLICATION.")
            print("      %s" % ", ".join(n for n, _, _, _, _ in r["deferred"]))
            print()
        print("OK" if not bad else "%d finding(s)" % bad)

    if args.report:
        with open(args.report, "w", encoding="utf-8", newline="\n") as f:
            f.write("# cvar audit\n\n")
            f.write("- table entries: %d\n- default.cfg assignments: %d\n"
                    "- cvars read by QC: %d\n\n" % (len(r["table"]), len(r["cfg"]), len(r["uses"])))
            for key, title in (("cfg_malformed", "Malformed default.cfg lines"),
                               ("missing", "Missing registrations"),
                               ("under", "Under-registered (side)"),
                               ("over", "Over-registered (side)"),
                               ("cfg_diff", "default.cfg vs table mismatches")):
                f.write("## %s (%d)\n\n" % (title, len(r[key])))
                for row in r[key]:
                    f.write("- `%s`\n" % (row[0],))
                f.write("\n")
        print("wrote %s" % args.report)

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
