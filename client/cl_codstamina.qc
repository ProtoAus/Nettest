// ============================================================
//  client/cl_codstamina.qc  -  sv_codstamina HUD bar
//
//  Visualises predicted_player.codstamina (0..1 sprint / hold-breath
//  pool) and predicted_player.codstamina_punished (red lockout flag).
//  Style intentionally minimal — solid-white fill on top of a 1 px
//  grey border (matches the defuse-bar layout in cl_hud.qc), turns
//  red while punished.  Fades out smoothly to invisible when the
//  pool is full and the lockout has cleared so an idle player sees
//  nothing on screen.
//
//  Server gate: serverkeyfloat("sv_codstamina") > 0.  Client gate:
//  cl_codstamina_bar (lets individual players hide the bar even on
//  a server that has the feature enabled).
// ============================================================

float csqc_codstamina_bar_alpha;     // eased 0..1 visibility
float csqc_codstamina_bar_last_time; // for dt calc

void() HUD_DrawCodStaminaBar =
{
    if (!predicted_player || !csqc_prediction_valid)
        return;
    if (serverkeyfloat("sv_codstamina", 0) <= 0)
        return;
    // cl_codstamina_bar is now an opacity multiplier (0..1) rather
    // than the old 0/1 toggle — gives the player a "slightly faded
    // bar" option at 0.7 etc.  Bail early when it's effectively zero.
    float bar_opacity = cvar("cl_codstamina_bar");
    if (bar_opacity < 0) bar_opacity = 0;
    if (bar_opacity > 1) bar_opacity = 1;
    if (bar_opacity <= 0.001)
        return;

    float st = predicted_player.codstamina;
    float punished = predicted_player.codstamina_punished;

    // Bar visibility envelope — target 1 when active (not at full or
    // punished), target 0 when at full and not punished.  Per the user
    // spec: "when the bar is full, just make it fade out until you
    // reduce it again somehow".
    float now = cltime;
    float dt = now - csqc_codstamina_bar_last_time;
    csqc_codstamina_bar_last_time = now;
    if (dt < 0.0001) dt = 0.0001;
    if (dt > 0.1) dt = 0.1;
    float target = (st >= 0.995 && !punished) ? 0 : 1;
    // Fade ~0.5 s in/out — same exponential ease shape the rest of
    // the codscope envelopes use.  Fast-start / soft-settle.
    float k = bound(0, (4.0 * dt) / 0.5, 1.0);
    csqc_codstamina_bar_alpha += (target - csqc_codstamina_bar_alpha) * k;
    if (target - csqc_codstamina_bar_alpha < 0.005
        && target - csqc_codstamina_bar_alpha > -0.005)
        csqc_codstamina_bar_alpha = target;
    csqc_codstamina_bar_alpha = bound(0, csqc_codstamina_bar_alpha, 1);

    if (csqc_codstamina_bar_alpha <= 0.001)
        return;

    float outer_w = 250;
    float outer_h = 8;
    float outer_x = (g_width - outer_w) * 0.5;
    // Position above the defuse bar slot — defuse uses 0.78, give the
    // stamina bar 0.84 so the two stack cleanly if both are active.
    float outer_y = g_height * 0.84;

    vector border_col = '0.3 0.3 0.3';
    // Final alpha = visibility envelope × user opacity multiplier.
    float bar_alpha = csqc_codstamina_bar_alpha * bar_opacity;

    // 1 px border — four strips so the centre stays drawable on top.
    drawfill([outer_x, outer_y],
             [outer_w, 1], border_col, bar_alpha, 0);
    drawfill([outer_x, outer_y + outer_h - 1],
             [outer_w, 1], border_col, bar_alpha, 0);
    drawfill([outer_x, outer_y],
             [1, outer_h], border_col, bar_alpha, 0);
    drawfill([outer_x + outer_w - 1, outer_y],
             [1, outer_h], border_col, bar_alpha, 0);

    // Inner fill — solid white in normal state, solid red while
    // punished (sprint / hold-breath both lock out until refill).
    float bar_x = outer_x + 2;
    float bar_y = outer_y + 2;
    float bar_w = outer_w - 4;
    float bar_h = outer_h - 4;
    float fill_w = bar_w * bound(0, st, 1);
    if (fill_w < 0) fill_w = 0;
    if (fill_w > bar_w) fill_w = bar_w;

    vector fill_col;
    if (punished)
        fill_col = '0.9 0.15 0.15';
    else
        fill_col = '1 1 1';
    if (fill_w > 0)
        drawfill([bar_x, bar_y], [fill_w, bar_h], fill_col, bar_alpha, 0);
};
