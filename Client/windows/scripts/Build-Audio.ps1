param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$package = Join-Path $Output 'rnnoise'
$dll = Join-Path $Output 'Chirp.RNNoise.dll'
$prepare = (Resolve-Path (Join-Path $PSScriptRoot '../../../scripts/prepare-rnnoise.py')).Path
$patch = (Resolve-Path (Join-Path $PSScriptRoot '../../apple/Patches/rnnoise-model-loading.patch')).Path
$stamp = @($PSCommandPath,$prepare,$patch) | Get-FileHash | ForEach-Object Hash
$versionFile = Join-Path $Output 'rnnoise.build'
if ((Test-Path -LiteralPath $dll) -and (Test-Path -LiteralPath $versionFile) -and [IO.File]::ReadAllText($versionFile) -eq ($stamp -join ':')) { return }
python $prepare --output $package
if (!(Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (!$vs) { throw 'Install the Visual Studio x64 C++ build tools.' }
    Import-Module (Join-Path $vs 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
}
$src = Join-Path $package 'Sources/CRNNoise'
Push-Location $package
try {
    $files = (Get-ChildItem -LiteralPath $src -Filter '*.c').FullName
    cl.exe /nologo /O2 /MT /LD /std:c11 /DRNNOISE_BUILD /DDLL_EXPORT /DWIN32 /DDISABLE_DEBUG_FLOAT=1 "/I$src" "/I$src/include" $files /link "/OUT:$dll"
    if ($LASTEXITCODE) { throw 'RNNoise build failed' }
    [IO.File]::WriteAllText($versionFile,($stamp -join ':'))
} finally { Pop-Location }
