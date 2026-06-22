@echo off
REM ---------------------------------------------------------------------------
REM Compile the nettest QC progs (server qwprogs.dat + client csprogs.dat).
REM
REM The CLIENT progs has grown past fteqcc's DEFAULT 2MB string buffer, so it
REM MUST be built with -max_strings (there is no working #pragma equivalent).
REM A plain `fteqcc64.exe cl_progs.src` will fail with:
REM     QCC_CopyString: -max_strings 2097152 limit exceeded
REM ---------------------------------------------------------------------------
cd /d "%~dp0"
echo Compiling server progs (qwprogs.dat)...
fteqcc64.exe sv_progs.src
echo.
echo Compiling client progs (csprogs.dat)...
fteqcc64.exe cl_progs.src -max_strings 8388608
echo.
echo Done.  Restart the server to pick up new progs (csprogs hash changes).
