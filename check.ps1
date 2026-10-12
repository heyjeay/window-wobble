# check.ps1 - validate the Windhawk mod without going through the Windhawk UI
#
# Three passes:
#   0. lints the engine applies but the compiler does not: the metadata block
#      format, non-ASCII bytes, and malformed line endings
#   1. -fsyntax-only with WH_EDITING, which is what the VSCode integration does
#   2. a real link against stubs for the engine-provided InternalWh_* symbols,
#      which is the only way to catch a missing -l flag before install
#
# Windhawk force-includes windhawk_api.h and compiles with its own Clang, so
# the flags here mirror the engine's rather than being freely chosen.

[CmdletBinding()]
param([string]$Mod = "$PSScriptRoot\window-wobble.wh.cpp")

$ErrorActionPreference = 'Stop'

$wh  = 'C:\Program Files\Windhawk\Compiler'
$cc  = Join-Path $wh 'bin\clang++.exe'
$inc = Join-Path $wh 'include'
if (-not (Test-Path $cc)) { throw "Windhawk compiler not found at $cc" }

$defs = @(
    '-DWH_MOD', '-DUNICODE', '-D_UNICODE',
    # Windhawk's own build sets these; the mod no longer passes them itself.
    # They have to be on the command line because windhawk_api.h pulls in
    # windows.h before the mod body, which is too late for GetDpiForWindow,
    # PW_RENDERFULLCONTENT and WS_EX_NOREDIRECTIONBITMAP.
    '-DWINVER=0x0A00', '-D_WIN32_WINNT=0x0A00', '-DNTDDI_VERSION=0x0A000008'
)

# windhawk_utils.h pastes WH_MOD_ID into a wide string literal. Defining it on
# the command line means fighting PowerShell's native-argument quoting, which
# silently drops the quotes and yields Lwindow-wobble; a forced include is
# unambiguous. Under -DWH_EDITING the api header supplies its own placeholder,
# hence the guard.
$modIdHeader = Join-Path $env:TEMP 'wh-modid.h'
Set-Content $modIdHeader @(
    '#ifndef WH_MOD_ID',
    '#define WH_MOD_ID L"window-wobble"',
    '#endif') -Encoding ASCII

$common = @('-std=c++23', '-target', 'x86_64-w64-mingw32',
            '-I', $inc,
            '-include', 'windhawk_api.h',
            '-include', $modIdHeader) + $defs

$raw   = Get-Content $Mod -Raw
$bytes = [IO.File]::ReadAllBytes($Mod)

Write-Host "0/2  lints..." -ForegroundColor Cyan

# Windhawk reads the mod source as ANSI, so a non-ASCII byte renders as
# mojibake in its editor even though the compiler accepts it. This caught 1386
# box-drawing characters that had become garbage on the mod page.
$nonAscii = [regex]::Matches($raw, '[^\x00-\x7F]')
if ($nonAscii.Count -gt 0) {
    $chars = ($nonAscii | ForEach-Object { 'U+{0:X4}' -f [int][char]$_.Value } |
              Select-Object -Unique) -join ', '
    throw "mod contains $($nonAscii.Count) non-ASCII character(s): $chars"
}

# Every line ending must be exactly CR LF. A doubled CR is invisible in most
# editors and corrupts the file for anything that parses it strictly; a lone CR
# ends a line for some readers and not others, and inside a comment it silently
# turns the remainder of the line into code. Both have bitten this project.
for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -eq 13) {
        if ($i -eq $bytes.Length - 1 -or $bytes[$i + 1] -ne 10) {
            throw "lone carriage return at offset $i"
        }
    } elseif ($bytes[$i] -eq 10) {
        if ($i -eq 0 -or $bytes[$i - 1] -ne 13) {
            throw "lone line feed at offset $i"
        }
    }
}

# Windhawk parses the metadata block itself and rejects any line that is not a
# "// @key value" directive. The compiler happily accepts a stray comment
# there, so only an explicit check catches it before install.
$meta = [regex]::Match($raw, '(?s)// ==WindhawkMod==\r?\n(.*?)// ==/WindhawkMod==')
if (-not $meta.Success) { throw "no WindhawkMod metadata block" }
$badLines = $meta.Groups[1].Value -split "\r?\n" |
    Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^//\s@[A-Za-z]+\s+\S' }
if ($badLines) {
    $badLines | ForEach-Object { Write-Host "  offending: $_" -ForegroundColor Red }
    throw "metadata block may only contain '// @key value' lines"
}
Write-Host "     ok" -ForegroundColor Green

$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'

Write-Host "1/2  syntax (WH_EDITING)..." -ForegroundColor Cyan
& $cc @common -DWH_EDITING -fsyntax-only $Mod 2>&1 | ForEach-Object { Write-Host "  $_" }
$code = $LASTEXITCODE
if ($code -ne 0) { $ErrorActionPreference = $prev; throw "syntax check failed ($code)" }
Write-Host "     clean" -ForegroundColor Green

Write-Host "2/2  link (stubbed engine symbols)..." -ForegroundColor Cyan
$tmp = Join-Path $env:TEMP "wh-modcheck-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
@'
#include <windows.h>
#include <stdarg.h>
int    InternalWh_GetIntSetting(void*, PCWSTR, va_list) { return 0; }
PCWSTR InternalWh_GetStringSetting(void*, PCWSTR, va_list) { return L""; }
void   InternalWh_FreeStringSetting(void*, PCWSTR) {}
BOOL   InternalWh_SetFunctionHook(void*, void*, void*, void**) { return TRUE; }
BOOL   InternalWh_IsLogEnabled(void*) { return FALSE; }
void   InternalWh_Log(void*, PCWSTR, va_list) {}
'@ | Set-Content (Join-Path $tmp 'stub.cpp') -Encoding UTF8

# Mirror the mod's own @compilerOptions libraries. d3d11 and dcomp are loaded
# at run time with LoadLibraryEx, so they are deliberately not linked.
$libs = @('-ldwmapi', '-lgdi32')
& $cc @common -shared -O2 $Mod (Join-Path $tmp 'stub.cpp') `
    -o (Join-Path $tmp 'out.dll') @libs 2>&1 | ForEach-Object { Write-Host "  $_" }
$code = $LASTEXITCODE
$ErrorActionPreference = $prev

if ($code -ne 0) { Remove-Item $tmp -Recurse -Force; throw "link failed ($code)" }
$size = (Get-Item (Join-Path $tmp 'out.dll')).Length
Remove-Item $tmp -Recurse -Force
Write-Host "     linked, $size bytes" -ForegroundColor Green
Write-Host "`nMod validates. Install via Windhawk > Create New Mod > paste > Compile." -ForegroundColor Cyan
