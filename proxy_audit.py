# Read-only static audit of server/sv_player.qc's prediction proxy.
#
# EVERY field PM_PredictionProxy_SendEntity writes on the wire must also be
# copied player->proxy in PM_SyncPredictionProxy.  SendEntity runs with `self`
# = the PROXY edict, so a field that is never copied serialises the proxy's own
# never-assigned zero -- forever, and silently, while the reader / sv_confirmed_*
# store / reconcile at the other end all look complete.
#
# That is how wep_deployed, famas_burst_mode and the four v26 pm_inv_* bytes
# all shipped dead.  This is the generic check for the whole class.
import re, sys
p = r"C:/FTEQuake/quakers/src/server/sv_player.qc"
src = open(p, encoding='latin-1').read()

def block(name):
    i = src.index(name)
    return src[i:src.index("\n};", i)]

send, sync = block("PM_PredictionProxy_SendEntity ="), block("PM_SyncPredictionProxy =")

# Every self.FIELD anywhere inside a Write*(MSG_ENTITY, ...) argument list --
# catches the bare form AND wrapped ones like bound(0, self.x, 255) and x ? 1 : 0.
written = set()
for line in send.splitlines():
    if 'MSG_ENTITY' not in line: continue
    for m in re.finditer(r'\bself\.(\w+)', line):
        written.add(m.group(1))

# proxy.FIELD = ... and proxy.FIELD[i] = ...
copied = set(m.group(1) for m in re.finditer(r'proxy\.(\w+)\s*(?:\[[^\]]*\])?\s*=[^=]', sync))
diffed = set(m.group(1) for m in re.finditer(r'proxy\.(\w+)\s*(?:\[[^\]]*\])?\s*!=', src))

# vector components: proxy.origin = ... covers origin_x/_y/_z
def ok(f, s):
    if f in s: return True
    if f[-2:] in ('_x','_y','_z') and f[:-2] in s: return True
    return False

# self.car_driving.origin_x is a nested ENTITY deref, not a proxy field
written = {w for w in written if w != 'car_driving'}

missing_copy = sorted(w for w in written if not ok(w, copied))
missing_diff = sorted(w for w in written if not ok(w, diffed))

print("wire fields: %d   copied: %d" % (len(written), len(copied)))
print()
print("*** WRITTEN BUT NEVER COPIED (serialises 0 forever):" if missing_copy
      else "OK: every wire field has a player->proxy copy")
for f in missing_copy: print("      ", f)
if missing_diff:
    print("\n*** WRITTEN BUT IN NO CHANGE DETECTOR (may ride another field's dirty bit):")
    for f in missing_diff: print("      ", f)
sys.exit(1 if (missing_copy or missing_diff) else 0)
