@echo off
REM ---------------------------------------------------------------------------
REM Compile the nettest QC progs: server qwprogs.dat + client csprogs.dat + menu.dat.
REM
REM All three progs have grown past fteqcc's DEFAULT 2MB string buffer, so all
REM MUST be built with -max_strings (there is no working pragma equivalent).
REM A plain "fteqcc64.exe cl_progs.src" fails with:
REM     QCC_CopyString: -max_strings 2097152 limit exceeded
REM The SERVER overflow is subtler: it surfaces as a cascade of
REM     server/sv_player.qc:NNNN: error: Unknown value "maxclients".
REM (an auto-provided engine global whose NAME cannot be stored once the def-name
REM string table is full) - NOT a code error.  Build sv_progs.src with -max_strings.
REM
REM menu.dat ALSO includes shared/sh_cvar_table.qc.  The Create Server menu
REM regenerates data/server.cfg from the MENU VM, so if menu.dat is stale, new
REM CVar_AddSaved rows never reach the generated server.cfg.  Build it too.
REM ---------------------------------------------------------------------------
cd /d "%~dp0"
echo Compiling server progs (qwprogs.dat)...
fteqcc64.exe sv_progs.src -max_strings 8388608
echo.
echo Compiling client progs (csprogs.dat)...
fteqcc64.exe cl_progs.src -max_strings 8388608
echo.
echo Compiling menu progs (menu.dat)...
fteqcc64.exe m_progs.src -max_strings 8388608
echo.
echo Done.  Restart the server to pick up new progs (csprogs hash changes).
