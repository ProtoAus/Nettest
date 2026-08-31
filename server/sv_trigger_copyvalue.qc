//
// sv_trigger_copyvalue.qc — Sven Co-op trigger_changevalue + trigger_copyvalue
//
// Ported from Sven Co-op (sven-coop.fgd).  Perform arithmetic / logic / trig /
// vector / string operations on entity keyvalues, addressed BY FIELD NAME via
// FTE's DP_QC_ENTITYDATA builtins (findentityfield / entityfieldtype /
// getentityfieldstring / putentityfieldstring, sv_defs.qc:1574-1591).
//
//   trigger_changevalue : op(dest_old, STATIC m_iszNewValue) -> every entity
//                         matching `target`, key m_iszValueName.
//   trigger_copyvalue   : op(dest_old, netname.m_iszSrcValueName) -> target's
//                         m_iszDstValueName.  First match (or all w/ flag 128).
//                         Constant mode (flag 8) repeats every `dmg` seconds.
//
// Scope (per spec): the keys ARE engine field names (health, speed, origin,
// angles, velocity, renderamt, ...).  STANDARD DECLARED FIELDS ONLY — custom /
// undeclared map keys aren't reachable from QC, and writing origin/angles here
// does NOT relink (use setorigin paths for that); acceptable per the request.
//

// --- custom keys (the BSP parser auto-fills these from matching map keys) ----
.string m_iszValueName;            // changevalue: destination key
.string m_iszNewValue;             // changevalue: static source value
.string m_iszSrcValueName;         // copyvalue: source key
.string m_iszDstValueName;         // copyvalue: destination key
.float  m_iszValueType;            // operation (Sven enum; integer via FGD choices)
.float  m_trigonometricBehaviour;  // 0 = degrees, 1 = radians
.float  m_iAppendSpaces;           // trailing spaces appended for string ops
.float  m_iFloatConversion;        // copyvalue: float->string precision / round mode
.float  tcv_active;                // copyvalue constant-mode latch

// --- operation enum (MUST match sven-coop.fgd:6103/6160) ---------------------
const float TVT_REPLACE = 0;
const float TVT_ADD     = 1;
const float TVT_MUL     = 2;
const float TVT_SUB     = 3;
const float TVT_DIV     = 4;
const float TVT_AND     = 5;
const float TVT_OR      = 6;
const float TVT_NAND    = 7;
const float TVT_NOR     = 8;
const float TVT_DIR2ANG = 9;       // copyvalue only
const float TVT_ANG2DIR = 10;      // copyvalue only
const float TVT_APPEND  = 11;      // string concat
const float TVT_MOD     = 12;
const float TVT_XOR     = 13;
const float TVT_NXOR    = 14;
const float TVT_POW     = 16;
const float TVT_SIN     = 17;
const float TVT_COS     = 18;
const float TVT_TAN     = 19;
const float TVT_ARCSIN  = 20;
const float TVT_ARCCOS  = 21;
const float TVT_ARCTAN  = 22;
const float TVT_COT     = 23;
const float TVT_ARCCOT  = 24;

// --- spawnflags --------------------------------------------------------------
const float SF_TV_NOX       = 1;
const float SF_TV_NOY       = 2;
const float SF_TV_NOZ       = 4;
const float SF_TV_CONSTANT  = 8;    // copyvalue
const float SF_TV_STARTON   = 16;   // copyvalue (with Constant)
const float SF_TV_INVTARGET = 32;
const float SF_TV_INVSOURCE = 64;
const float SF_TV_MULTIDEST = 128;  // copyvalue

const float TV_D2R = 0.0174532925199433;   // PI/180
const float TV_R2D = 57.2957795130823;     // 180/PI

// zero the vector extents excluded by the Don't-use-X/Y/Z spawnflags
vector(vector v, float fl) TV_Mask =
{
	if (fl & SF_TV_NOX) v_x = 0;
	if (fl & SF_TV_NOY) v_y = 0;
	if (fl & SF_TV_NOZ) v_z = 0;
	return v;
};

// float -> string honouring m_iFloatConversion (default 6dp; rounded N dp; int round/ceil/floor)
string(float f, float conv) TV_FtoS =
{
	if (conv == 16) return ftos(floor(f + 0.5));   // integer, rounded
	if (conv == 17) return ftos(0 - floor(0 - f)); // integer, rounded up (ceil)
	if (conv == 18) return ftos(floor(f));         // integer, rounded down
	float dp = 0;
	if      (conv == 1)  dp = 5;
	else if (conv == 4)  dp = 4;
	else if (conv == 7)  dp = 3;
	else if (conv == 10) dp = 2;
	else if (conv == 13) dp = 1;
	if (dp <= 0)
		return ftos(f);                            // 0 => default
	float m = pow(10, dp);
	return ftos(floor(f * m + 0.5) / m);
};

// the scalar operation: a = old destination, b = source.  Unary ops ignore a.
float(float op, float a, float b, float trigB) TV_Calc =
{
	float x, r, ia, ib;
	switch (op)
	{
	case TVT_REPLACE: return b;
	case TVT_ADD:     return a + b;
	case TVT_SUB:     return a - b;
	case TVT_MUL:     return a * b;
	case TVT_DIV:     return (b != 0) ? a / b : a;
	case TVT_MOD:     return (b != 0) ? a - floor(a / b) * b : a;
	case TVT_POW:     return pow(a, b);
	case TVT_AND:     ia = a; ib = b; return ia & ib;
	case TVT_OR:      ia = a; ib = b; return ia | ib;
	case TVT_XOR:     ia = a; ib = b; return (ia | ib) - (ia & ib);  // XOR = OR - AND (non-neg ints)
	case TVT_NAND:    ia = a; ib = b; return (ia & ib) ? 0 : 1;      // Sven: logical !(a & b)
	case TVT_NOR:     ia = a; ib = b; return (ia | ib) ? 0 : 1;
	case TVT_NXOR:    ia = a; ib = b; return ((ia | ib) - (ia & ib)) ? 0 : 1;
	case TVT_SIN:     x = b; if (!trigB) x = x * TV_D2R; return sin(x);
	case TVT_COS:     x = b; if (!trigB) x = x * TV_D2R; return cos(x);
	case TVT_TAN:     x = b; if (!trigB) x = x * TV_D2R; return tan(x);
	case TVT_COT:     x = b; if (!trigB) x = x * TV_D2R; { float s = sin(x); return (s != 0) ? cos(x) / s : 0; }
	case TVT_ARCSIN:  r = asin(b); if (!trigB) r = r * TV_R2D; return r;
	case TVT_ARCCOS:  r = acos(b); if (!trigB) r = r * TV_R2D; return r;
	case TVT_ARCTAN:  r = atan(b); if (!trigB) r = r * TV_R2D; return r;
	case TVT_ARCCOT:  r = atan2(1, b); if (!trigB) r = r * TV_R2D; return r;
	}
	return a;
};

// Same op, but onto one of Sven's "$" custom keyvalues, which are not fields and
// so cannot go through findentityfield / putentityfieldstring.  Storage is the
// side table in sv_customkeys.qc; the type comes from the name's prefix.
//
// Shape mirrors TV_Apply below deliberately, so the two stay comparable.
void(entity act, entity dst, string dstkey, vector srcVec, float srcF, string srcStr, float srcType) TV_ApplyCustom =
{
	float  op    = act.m_iszValueType;
	float  fl    = act.spawnflags;
	float  trigB = act.m_trigonometricBehaviour;
	float  kt    = CustomKey_Type(dstkey);
	string cur   = CustomKey_Get(dst, dstkey);
	string news  = "";
	vector ov    = '0 0 0';
	vector nv    = '0 0 0';
	float  a     = 0;
	float  s     = 0;
	float  i     = 0;

	if (op == TVT_APPEND)
	{
		news = strcat(cur, srcStr);
		for (i = 0; i < act.m_iAppendSpaces; i = i + 1)
			news = strcat(news, " ");
		CustomKey_Set(dst, dstkey, news);
		return;
	}

	// A $s_ target with REPLACE is a plain string assignment, and that is the
	// whole reason the type prefix exists.  Falling through to the numeric path
	// would evaluate stof("extreme") == 0 and store "0" — which is precisely the
	// difficulty selection this entity is used to carry.
	if (kt == EV_STRING && op == TVT_REPLACE)
	{
		CustomKey_Set(dst, dstkey, srcStr);
		return;
	}

	if (op == TVT_DIR2ANG || op == TVT_ANG2DIR)
	{
		vector sv = TV_Mask(srcVec, fl);
		vector res;
		if (fl & SF_TV_INVSOURCE) sv = sv * -1;
		if (op == TVT_DIR2ANG)
			res = vectoangles(sv);
		else
		{
			makevectors(sv);
			res = v_forward;
		}
		ov = stov(cur);
		if (!(fl & SF_TV_NOX)) ov_x = res_x;
		if (!(fl & SF_TV_NOY)) ov_y = res_y;
		if (!(fl & SF_TV_NOZ)) ov_z = res_z;
		CustomKey_Set(dst, dstkey, vtos(ov));
		return;
	}

	s = srcF;
	if (srcType == EV_VECTOR)
		s = vlen(TV_Mask(srcVec, fl));
	if (fl & SF_TV_INVSOURCE)
		s = 0 - s;

	if (kt == EV_VECTOR)
	{
		ov = stov(cur);
		nv = ov;
		if (!(fl & SF_TV_NOX)) { a = ov_x; if (fl & SF_TV_INVTARGET) a = 0 - a; nv_x = TV_Calc(op, a, s, trigB); }
		if (!(fl & SF_TV_NOY)) { a = ov_y; if (fl & SF_TV_INVTARGET) a = 0 - a; nv_y = TV_Calc(op, a, s, trigB); }
		if (!(fl & SF_TV_NOZ)) { a = ov_z; if (fl & SF_TV_INVTARGET) a = 0 - a; nv_z = TV_Calc(op, a, s, trigB); }
		CustomKey_Set(dst, dstkey, vtos(nv));
		return;
	}

	a = stof(cur);
	if (fl & SF_TV_INVTARGET) a = 0 - a;
	CustomKey_Set(dst, dstkey, TV_FtoS(TV_Calc(op, a, s, trigB), act.m_iFloatConversion));
};

// apply the trigger's configured op onto dst's field `dstkey`, using a source
// pre-resolved into (vector / scalar / string) + its EV_ type.
void(entity act, entity dst, string dstkey, vector srcVec, float srcF, string srcStr, float srcType) TV_Apply =
{
	// "$s_foo" and friends are map-invented variables with no field behind them.
	if (CustomKey_IsCustom(dstkey))
	{
		TV_ApplyCustom(act, dst, dstkey, srcVec, srcF, srcStr, srcType);
		return;
	}

	float dstFn = findentityfield(dstkey);
	if (dstFn <= 0)
		return;
	float dstType = entityfieldtype(dstFn);
	float op    = act.m_iszValueType;
	float fl    = act.spawnflags;
	float trigB = act.m_trigonometricBehaviour;
	vector ov;
	float  a;

	// --- string concatenation ---
	if (op == TVT_APPEND)
	{
		string news = strcat(getentityfieldstring(dstFn, dst), srcStr);
		float i;
		for (i = 0; i < act.m_iAppendSpaces; i = i + 1)
			news = strcat(news, " ");
		putentityfieldstring(dstFn, dst, news);
		return;
	}

	// --- vector ops (copyvalue): Direction <-> Angles ---
	if (op == TVT_DIR2ANG || op == TVT_ANG2DIR)
	{
		vector sv = TV_Mask(srcVec, fl);
		if (fl & SF_TV_INVSOURCE) sv = sv * -1;
		vector res;
		if (op == TVT_DIR2ANG)
			res = vectoangles(sv);
		else
		{
			makevectors(sv);
			res = v_forward;
		}
		ov = stov(getentityfieldstring(dstFn, dst));
		if (!(fl & SF_TV_NOX)) ov_x = res_x;
		if (!(fl & SF_TV_NOY)) ov_y = res_y;
		if (!(fl & SF_TV_NOZ)) ov_z = res_z;
		putentityfieldstring(dstFn, dst, vtos(ov));
		return;
	}

	// --- numeric / bitwise / trig ---
	// source operand as a scalar: a vector source collapses to its (masked) length
	float s;
	if (srcType == EV_VECTOR)
		s = vlen(TV_Mask(srcVec, fl));
	else
		s = srcF;
	if (fl & SF_TV_INVSOURCE) s = s * -1;

	if (dstType == EV_VECTOR)
	{
		// per-extent op on the unmasked extents (masked extents keep their value)
		ov = stov(getentityfieldstring(dstFn, dst));
		vector nv = ov;
		if (!(fl & SF_TV_NOX)) { a = ov_x; if (fl & SF_TV_INVTARGET) a = 0 - a; nv_x = TV_Calc(op, a, s, trigB); }
		if (!(fl & SF_TV_NOY)) { a = ov_y; if (fl & SF_TV_INVTARGET) a = 0 - a; nv_y = TV_Calc(op, a, s, trigB); }
		if (!(fl & SF_TV_NOZ)) { a = ov_z; if (fl & SF_TV_INVTARGET) a = 0 - a; nv_z = TV_Calc(op, a, s, trigB); }
		putentityfieldstring(dstFn, dst, vtos(nv));
	}
	else
	{
		a = stof(getentityfieldstring(dstFn, dst));
		if (fl & SF_TV_INVTARGET) a = 0 - a;
		putentityfieldstring(dstFn, dst, TV_FtoS(TV_Calc(op, a, s, trigB), act.m_iFloatConversion));
	}
};

// fire the "Trigger after action" target(s) — reuse the mod's target chain by
// briefly aiming .target at .message (the op is already done by this point).
void(entity act, entity who) TV_FireAfter =
{
	if (act.message == "" || act.message == __NULL__)
		return;
	string saved = act.target;
	act.target = act.message;
	Trigger_UseTargets(act, who);
	act.target = saved;
};

//============================ trigger_changevalue ============================
void() trigger_changevalue_use =
{
	if (self.target == "" || self.m_iszValueName == "")
		return;

	entity who = activator;
	string  srcStr = self.m_iszNewValue;
	float   srcF   = stof(self.m_iszNewValue);
	vector  srcVec = stov(self.m_iszNewValue);

	if (self.target == "!activator")
	{
		if (who)
			TV_Apply(self, who, self.m_iszValueName, srcVec, srcF, srcStr, EV_FLOAT);
	}
	else if (self.target == "!caller")
	{
		if (sub_use_caller)
			TV_Apply(self, sub_use_caller, self.m_iszValueName, srcVec, srcF, srcStr, EV_FLOAT);
	}
	else
	{
		entity dst = findchain(targetname, self.target);   // affects ALL matches (Sven)
		while (dst)
		{
			TV_Apply(self, dst, self.m_iszValueName, srcVec, srcF, srcStr, EV_FLOAT);
			dst = dst.chain;
		}
	}

	TV_FireAfter(self, who);
};

void() trigger_changevalue =
{
	self.movetype = MOVETYPE_NONE;
	self.solid    = SOLID_NOT;
	self.use      = trigger_changevalue_use;
};

//============================= trigger_copyvalue =============================
void() trigger_copyvalue_fire =
{
	if (self.target == "" || self.netname == "" || self.m_iszSrcValueName == "" || self.m_iszDstValueName == "")
		return;

	entity srcent = find(world, targetname, self.netname);
	if (!srcent)
		return;

	float  srcType = 0;
	string srcStr  = "";
	float  srcF    = 0;
	vector srcVec  = '0 0 0';

	// A "$" source is a custom keyvalue, not a field.  An absent one aborts
	// rather than reading as 0, the same reading TCond_ReadKey takes.
	if (CustomKey_IsCustom(self.m_iszSrcValueName))
	{
		if (!CustomKey_Has(srcent, self.m_iszSrcValueName))
			return;
		srcType = CustomKey_Type(self.m_iszSrcValueName);
		srcStr  = CustomKey_Get(srcent, self.m_iszSrcValueName);
	}
	else
	{
		float srcFn = findentityfield(self.m_iszSrcValueName);
		if (srcFn <= 0)
			return;
		srcType = entityfieldtype(srcFn);
		srcStr  = getentityfieldstring(srcFn, srcent);
	}
	srcF   = stof(srcStr);
	srcVec = stov(srcStr);

	entity dst;
	if (self.spawnflags & SF_TV_MULTIDEST)
	{
		dst = findchain(targetname, self.target);
		while (dst)
		{
			TV_Apply(self, dst, self.m_iszDstValueName, srcVec, srcF, srcStr, srcType);
			dst = dst.chain;
		}
	}
	else
	{
		dst = find(world, targetname, self.target);
		if (dst)
			TV_Apply(self, dst, self.m_iszDstValueName, srcVec, srcF, srcStr, srcType);
	}

	TV_FireAfter(self, activator);
};

void() trigger_copyvalue_think =
{
	if (!self.tcv_active)
		return;
	trigger_copyvalue_fire();
	self.nextthink = time + ((self.dmg > 0) ? self.dmg : frametime);   // dmg 0 => every server frame
};

void() trigger_copyvalue_use =
{
	if (self.spawnflags & SF_TV_CONSTANT)
	{
		self.tcv_active = !self.tcv_active;          // toggleable in constant mode
		if (self.tcv_active)
		{
			self.think     = trigger_copyvalue_think;
			self.nextthink = time + ((self.dmg > 0) ? self.dmg : frametime);
		}
		else
			self.nextthink = 0;                      // stop the loop
		return;
	}
	trigger_copyvalue_fire();                        // one-shot
};

void() trigger_copyvalue =
{
	self.movetype = MOVETYPE_NONE;
	self.solid    = SOLID_NOT;
	self.use      = trigger_copyvalue_use;

	if ((self.spawnflags & SF_TV_CONSTANT) && (self.spawnflags & SF_TV_STARTON))
	{
		self.tcv_active = TRUE;
		self.think      = trigger_copyvalue_think;
		self.nextthink  = time + 0.2;                // begin shortly after map load
	}
};
