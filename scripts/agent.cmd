@echo off
rem The VS Code door on a Windows desk: the ACP agent over stdio. taskweft's NIF is built with llvm-mingw
rem (clang++ through the mingw32-make shim), never Visual Studio, and only JSON may
rem reach stdout, so the compile runs first with its output on stderr. Edit LLVM_MINGW
rem for a desk that unpacked the toolchain elsewhere.
set "REPO=%~dp0.."
set "LLVM_MINGW=%USERPROFILE%\llvm-mingw\llvm-mingw-20260826-ucrt-x86_64"
set "PATH=%LLVM_MINGW%\bin;%USERPROFILE%\bin;%USERPROFILE%\scoop\shims;%USERPROFILE%\scoop\apps\elixir\current\bin;%USERPROFILE%\scoop\apps\erlang\current\bin;%PATH%"
set "CC=clang"
set "CXX=clang++"
set "VCINSTALLDIR="
cd /d "%REPO%"
call mix compile 1>&2
mix taskweft_acp.agent
