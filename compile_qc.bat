@echo off
REM ---------------------------------------------------------------------------
REM Compile the quakers QC progs: server qwprogs.dat + client csprogs.dat + menu.dat.
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
REM 2026-08-02: sv_progs.src outgrew 8388608 too, and the cascade came back wearing
REM a different name ("Unknown value DOOR_USE_ABLE", from sv_doors.qc).  If you ever
REM see an "Unknown value" error naming a constant that plainly IS defined, it is
REM this, not your code - double -max_strings rather than hunting the symbol.
REM
REM menu.dat ALSO includes shared/sh_cvar_table.qc.  The Create Server menu
REM regenerates data/server.cfg from the MENU VM, so if menu.dat is stale, new
REM CVar_AddSaved rows never reach the generated server.cfg.  Build it too.
REM ---------------------------------------------------------------------------
cd /d "%~dp0"
echo Compiling server progs (qwprogs.dat)...
fteqcc64.exe sv_progs.src -max_strings 16777216
echo.
echo Compiling client progs (csprogs.dat)...
fteqcc64.exe cl_progs.src -max_strings 16777216
echo.
echo Compiling menu progs (menu.dat)...
fteqcc64.exe m_progs.src -max_strings 16777216
echo.
REM ---------------------------------------------------------------------------
REM Package csprogs.dat into a COMPRESSED .pk3 so connecting clients download it
REM at ~1.6MB instead of the raw ~8MB.  FTE sends a LOOSE csprogs.dat to clients
REM UNCOMPRESSED, but when it lives inside a (non-'pak'-named) pk3 the server
REM redirects the download to the whole pk3 and streams it already-compressed
REM (SV_LocateDownload -> DLERR_SV_REDIRECTPACK; allow_download_packages default 1).
REM pack_csprogs.py verifies the archive, then removes the loose csprogs.dat (FTE
REM searches loose files BEFORE pk3s, so a stray bare-fteqcc build's fresh loose
REM copy would harmlessly override a stale pk3 -> never runs stale code).
REM If python is missing / packaging fails, the loose csprogs.dat is KEPT and the
REM server still works (just uncompressed downloads).
REM ---------------------------------------------------------------------------
echo Packaging csprogs.dat -^> quakers_csprogs.pk3 (compressed download)...
python pack_csprogs.py
echo.
echo Done.  Restart the server to pick up new progs (csprogs hash changes).
