// ============================================================================
//  sh_carryrot.qc — orientation math for CARRIED physics props (shared SSQC+CSQC)
// ============================================================================
//
// Compiled into BOTH progs (sv_progs.src + cl_progs.src).  That is not tidiness:
// the server drives the real Box3D body while the local carrier PREDICTS the same
// pose client-side, so the two must agree bit-for-bit or the prop pops on drop.
// One implementation is the only way to guarantee that.
//
// WHY A BASIS AND NOT EULER ANGLES
// --------------------------------
// Composing Euler angles in QC is a bug farm (gimbal, wrap, axis-order).  We store
// the orientation as two unit vectors (model +X and model +Z) and only convert to
// .angles at the very end.  That conversion is EXACT here:
//
//   vectoangles(F, U)  -> engine PF_vectoangles -> VectorAngles(F, U, out, TRUE),
//                         which multiplies pitch by r_meshpitch and roll by r_meshroll.
//   AngleVectorsMesh(a) = AngleVectors(a_x*r_meshpitch, a_y, a_z*r_meshroll)
//
// and the engine uses AngleVectorsMesh to build a prop's basis for rendering, for
// server collision (World_OBBTrace / World_HullTrace) and for the client pmove
// mirror (PM_HullTrace).  Since r_meshpitch^2 == r_meshroll^2 == 1 the two
// multiplies cancel, so:
//
//        AngleVectorsMesh( vectoangles(F, U) )  ==  (F, *, U)     exactly.
//
// i.e. vectoangles() is the precise inverse of the engine's own prop-basis builder.
// Set .angles = vectoangles(F,U) DIRECTLY — do NOT pre-flip the pitch yourself, or
// you double-apply r_meshpitch.  (Car_DrawWheels in cl_physprop.qc documents that
// exact bug: the double-apply inverted wheel pitch, invisible until the car banked.)
//
// THE "CARRY FRAME"
// -----------------
// Carried props track the carrier's view yaw.  We define the carry frame as the
// pure-yaw frame at yaw0 = player.v_angle_y + 180 (the yaw props already used), and
// store the prop's axes IN THAT FRAME.  Because it is a pure Z rotation, composing
// is a 2x2 rotation — deliberately NOT makevectors(), because Carry_Tick and
// Carry_Throw both rely on v_forward surviving across calls and clobbering the
// builtin globals mid-tick is a live hazard in that file.
// ============================================================================

// Basis produced by CarryRot_Axes() — the prop's model axes.
// Matches the engine's box-local convention: [v_forward, -v_right, v_up]
// (server/world.c World_OBBTrace negates axis[1]).
vector crot_X;      // model +X ("forward")
vector crot_Y;      // model +Y ("left")
vector crot_Z;      // model +Z ("up")

// Basis produced by CarryRot_Ortho / _Snap8 / _Nlerp.
vector crot_oF;
vector crot_oU;

// r_meshpitch/r_meshroll are "do not change from the default" engine cvars (-1 and
// 1 in this build) and are read identically by client and server.  The fallback only
// fires if the cvar is somehow absent; 0 would silently flatten every pitch.
float CarryRot_MeshPitch()
{
    float v = cvar("r_meshpitch");
    if (v == 0)
        return -1;
    return v;
}
float CarryRot_MeshRoll()
{
    float v = cvar("r_meshroll");
    if (v == 0)
        return 1;
    return v;
}

// Normalise an angle to [-180, 180).  Used by the wire codec: at the 182 counts/degree
// scale below that keeps every component inside a signed short (182*180 = 32760).
float CarryRot_Norm180(float a)
{
    return a - 360 * floor((a + 180) / 360);
}

// Wire scale for a carry-frame orientation sent as 3 shorts.  ~0.0055 deg per count —
// far finer than needed, and it costs 6 bytes only for props that are actually held.
// Do NOT switch these to WriteCoord: FTE coords are commonly 1/8-precision fixed point,
// which would quantise a unit-vector-derived angle into visible steps.
const float CROT_WIRE_SCALE = 182;

// .angles -> model basis.  This is AngleVectorsMesh(), i.e. the basis the ENGINE
// actually collides and renders with — NOT raw makevectors(), which differs by a
// pitch sign flip and is only correct while pitch happens to be 0.
void CarryRot_Axes(vector ang)
{
    vector m;
    m_x = ang_x * CarryRot_MeshPitch();
    m_y = ang_y;
    m_z = ang_z * CarryRot_MeshRoll();
    makevectors(m);
    crot_X = v_forward;
    crot_Y = '0 0 0' - v_right;
    crot_Z = v_up;
}

// model basis -> .angles.  Exact inverse of CarryRot_Axes (see the header).
vector CarryRot_Angles(vector F, vector U)
{
    return vectoangles(F, U);
}

// world vector -> carry frame (inverse of a pure yaw rotation = its transpose).
vector CarryRot_ToFrame(vector v, float yaw)
{
    float cy = cos(yaw * 0.0174532925);
    float sy = sin(yaw * 0.0174532925);
    vector r;
    r_x =  cy * v_x + sy * v_y;
    r_y = -sy * v_x + cy * v_y;
    r_z =  v_z;
    return r;
}

// carry frame -> world vector.
vector CarryRot_FromFrame(vector v, float yaw)
{
    float cy = cos(yaw * 0.0174532925);
    float sy = sin(yaw * 0.0174532925);
    vector r;
    r_x = cy * v_x - sy * v_y;
    r_y = sy * v_x + cy * v_y;
    r_z = v_z;
    return r;
}

// Force (F,U) back to a clean orthonormal pair -> crot_oF / crot_oU.
// Mouse-driven rotation accumulates float error every frame, so this runs on every
// update; without it the basis slowly shears and vectoangles() starts lying.
void CarryRot_Ortho(vector F, vector U)
{
    if (F * F < 0.000001)
        F = '1 0 0';
    F = normalize(F);

    // Gram-Schmidt: strip any component of U that lies along F.
    U = U - F * (U * F);
    if (U * U < 0.000001)
    {
        // U was (near) parallel to F — pick any axis not parallel to F and retry,
        // so we always emit a valid basis instead of a NaN one.
        U = '0 0 1' - F * (F_z);
        if (U * U < 0.000001)
            U = '1 0 0' - F * (F_x);
    }
    crot_oF = F;
    crot_oU = normalize(U);
}

// Snap a basis to the nearest AXIS-ALIGNED pose whose up maps to +Z or -Z, with the
// forward snapped to the nearest 90 degrees -> crot_oF / crot_oU.  That is the set of
// 8 poses: upright or upside-down, never on its side, yaw in {0,90,180,270}.
//
// Pure vector comparison — no atan2, no rounding step, so there is no wrap or gimbal
// case to get wrong.  Feed it a basis already expressed in the CARRY frame and the
// result is square-on to the player's view.
void CarryRot_Snap8(vector F, vector U)
{
    vector Y, Zs, Xs, h;
    float  mx, my, hsign;

    // model +Y = Z x X (the basis is right-handed).
    Y_x = U_y * F_z - U_z * F_y;
    Y_y = U_z * F_x - U_x * F_z;
    Y_z = U_x * F_y - U_y * F_x;

    // Up maps to whichever pole it is already nearer.  A prop lying exactly on its
    // side makes this a coin toss, but it is evaluated ONCE at grab, so the choice is
    // deterministic rather than jittery, and the pull-in animates it standing up.
    if (U_z >= 0)
    {
        Zs = '0 0 1';
        hsign = 1;
    }
    else
    {
        Zs = '0 0 -1';
        hsign = -1;
    }

    // Choose the better-conditioned horizontal source for the yaw.  If the prop is
    // nose-up, F projects to nothing horizontally, so derive the forward from Y
    // instead (Xs = Ys x Zs).  This can never degenerate: for an orthonormal basis
    // F_z^2 + Y_z^2 <= 1, hence mx + my >= 1, so the winner always has horizontal
    // length >= 0.707.  There is no near-zero normalize anywhere in here.
    mx = F_x * F_x + F_y * F_y;
    my = Y_x * Y_x + Y_y * Y_y;
    if (mx >= my)
    {
        h_x = F_x;
        h_y = F_y;
    }
    else
    {
        // The X implied by Y.  hsign flips it for the upside-down poles, otherwise an
        // inverted prop would end up facing backwards.
        h_x =  Y_y * hsign;
        h_y = -Y_x * hsign;
    }
    h_z = 0;

    if (fabs(h_x) >= fabs(h_y))
    {
        if (h_x >= 0) Xs = '1 0 0';
        else          Xs = '-1 0 0';
    }
    else
    {
        if (h_y >= 0) Xs = '0 1 0';
        else          Xs = '0 -1 0';
    }

    // Xs is horizontal and Zs is vertical, so they are exactly orthogonal — no
    // Gram-Schmidt needed and vectoangles() on this pair is exact.
    crot_oF = Xs;
    crot_oU = Zs;
}

// World-space offset from a prop's ORIGIN to its box CENTRE, with the local centre offset
// ROTATED by the prop's orientation.
//
// A model's origin sits at its feet, so the centre is offset from it — and that offset is
// a MODEL-SPACE vector, so it has to rotate with the model.  The carry used to add it
// along world Z unconditionally, which is only correct while the prop is upright.  Held
// upside-down the true offset points DOWN but the old code still added it UP, placing the
// prop a full box-height too low (the "upside-down prop sits lower on the screen" bug) and
// making the carry appear to pivot about the prop's base instead of its middle.
//
// NOTE: goes through CarryRot_Axes, so it CALLS MAKEVECTORS.
vector CarryRot_CenterOfs(vector ang, vector lmins, vector lmaxs)
{
    vector lc = (lmins + lmaxs) * 0.5;
    CarryRot_Axes(ang);
    return crot_X * lc_x + crot_Y * lc_y + crot_Z * lc_z;
}

// World-axis AABB half-extent of a box with local half-extents `h` rotated by `ang`.
//
// The carry clip-and-slide traces a WORLD-AXIS box.  With the orientation locked upright
// that was harmless, but a freely-rotated prop (inspect mode) breaks it: a long prop
// turned 90 degrees traces too SHORT along the axis it actually occupies, so the hold
// point can be resolved inside geometry.  This is the same 8-corner projection the engine
// broadphase does in server/world.c when it links a rotated physics box.
//
// NOTE: goes through CarryRot_Axes, so it CALLS MAKEVECTORS — never call it between
// setting up v_forward and reading it.
vector CarryRot_RotatedHalf(vector ang, vector h)
{
    vector r;
    CarryRot_Axes(ang);
    r_x = fabs(crot_X_x) * h_x + fabs(crot_Y_x) * h_y + fabs(crot_Z_x) * h_z;
    r_y = fabs(crot_X_y) * h_x + fabs(crot_Y_y) * h_y + fabs(crot_Z_y) * h_z;
    r_z = fabs(crot_X_z) * h_x + fabs(crot_Y_z) * h_y + fabs(crot_Z_z) * h_z;
    return r;
}

// Rotate a basis about a unit axis by `deg` (Rodrigues) -> crot_oF / crot_oU.
// This is what mouse motion drives in inspect mode.  The axis is given in the SAME frame
// as the basis; for the carry frame the two useful axes are constants, because the frame
// itself yaws with the view:
//     '0 0 1'  = world up          -> mouse X spins the prop like a turntable
//     '0 1 0'  = the player's RIGHT -> mouse Y tips it toward/away from the camera
// (view-right transformed into the carry frame works out to exactly (0,1,0); the yaw
// terms cancel because the carry frame is defined at v_angle_y + 180.)
void CarryRot_SpinBasis(vector F, vector U, vector axis, float deg)
{
    float  rad = deg * 0.0174532925;
    float  c   = cos(rad);
    float  s   = sin(rad);
    vector kF, kU, rF, rU;

    kF_x = axis_y * F_z - axis_z * F_y;      // axis x F
    kF_y = axis_z * F_x - axis_x * F_z;
    kF_z = axis_x * F_y - axis_y * F_x;
    kU_x = axis_y * U_z - axis_z * U_y;      // axis x U
    kU_y = axis_z * U_x - axis_x * U_z;
    kU_z = axis_x * U_y - axis_y * U_x;

    rF = F * c + kF * s + axis * ((axis * F) * (1 - c));
    rU = U * c + kU * s + axis * ((axis * U) * (1 - c));

    // Re-orthonormalise every time: mouse rotation accumulates float error frame after
    // frame, and an un-corrected basis slowly shears until vectoangles starts lying.
    CarryRot_Ortho(rF, rU);
}

// Prop Hunt: compose a disguised player's stored carry-frame basis (ph_rel_fwd/up)
// into world .angles at frame yaw `yaw0` (= v_angle_y + 180 live, or ph_locked_yaw +
// 180 while committed).  Shared so the server hitbox pin / visual proxy and the CSQC
// predraw all build the identical orientation.  Falls back to a plain upright facing
// (angles_y = yaw0 - 180, i.e. v_angle_y) when the basis is unset/degenerate — e.g. a
// proxy that hasn't yet received a pose, so it renders exactly like the old flat yaw.
vector PH_PoseAngles(vector relF, vector relU, float yaw0)
{
    if (relF * relF < 0.5)
        return [0, yaw0 - 180, 0];
    return CarryRot_Angles(CarryRot_FromFrame(relF, yaw0),
                           CarryRot_FromFrame(relU, yaw0));
}

// Interpolate between two bases -> crot_oF / crot_oU.
// A per-component EULER lerp (Carry_AnglesLerp) is wrong for this: from an arbitrary
// tumbled start pose it takes visibly wrong paths, and a 0<->180 roll passes straight
// through "on its side" — exactly the look we are trying to eliminate.
void CarryRot_Nlerp(vector F0, vector U0, vector F1, vector U1, float f)
{
    // Antipodal guards: if a pair is near-opposite, the straight lerp passes through the
    // origin at f=0.5, where normalize() explodes and Ortho's degenerate fallback
    // substitutes an arbitrary roll — a visible snap in the middle of the blend.  BOTH
    // axes need this: F0/F1 opposed is a 180° turn, U0/U1 opposed with F fixed is a 180°
    // ROLL about forward, which the drop fade can hit (its own guard only tests forward).
    if (F0 * F1 < -0.9995)
        F1 = normalize(F1 + U1 * 0.02);
    if (U0 * U1 < -0.9995)
        U1 = normalize(U1 + F1 * 0.02);

    CarryRot_Ortho(F0 + (F1 - F0) * f,
                   U0 + (U1 - U0) * f);
}
