[CmdletBinding()]
param([string] $InnoCompiler = $env:CHIRP_ISCC)

$ErrorActionPreference = 'Stop'
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $windowsRoot '..\..')).Path
$project = Join-Path $windowsRoot 'Chirp\Chirp.csproj'
$scriptFile = Join-Path $windowsRoot 'installer\Chirp.iss'
$releaseDir = Join-Path $repoRoot '.build\releases'
if (-not $InnoCompiler) {
    $installedCompiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($installedCompiler) {
        $InnoCompiler = $installedCompiler.Source
    } else {
        $InnoCompiler = Join-Path $repoRoot '.build\windows-tools\inno-7.1.1\ISCC.exe'
    }
}
$compiler = (Get-Command $InnoCompiler -CommandType Application -ErrorAction Stop).Source

$buildRoot = [IO.Directory]::CreateDirectory((Join-Path $repoRoot '.build\windows-installer')).FullName
$stage = [IO.Directory]::CreateDirectory((Join-Path $buildRoot ([guid]::NewGuid().ToString('N')))).FullName
$payload = Join-Path $stage 'publish'
try {
    $buildOptions = @(
        'publish', $project, '-c', 'Release', '-r', 'win-x64', '--self-contained',
        '-p:Platform=x64', '-p:WindowsPackageType=None', '-p:DebugType=None',
        "-p:OutputPath=$stage/build/", "-p:IntermediateOutputPath=$stage/obj/Release/",
        "-p:MSBuildProjectExtensionsPath=$stage/obj/", '-o', $payload, '--nologo'
    )
    & dotnet @buildOptions
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }
    foreach ($name in 'Chirp.exe', 'Chirp.pri', 'Chirp.Protocol.exe', 'chirp_mls_native.dll', 'chirp_windows_audio.dll', 'Chirp.RNNoise.dll', 'opus.dll', 'AuthorizationTrust.json', 'Sounds\JoinTheRoom.mp3', 'Sounds\LeftTheRoom.mp3') {
        if (-not (Test-Path -LiteralPath (Join-Path $payload $name) -PathType Leaf)) {
            throw "Release payload is missing $name"
        }
    }

    & $compiler /Qp "/O$stage" "/DChirpSourceDir=$payload" $scriptFile
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)" }
    $installers = @(Get-ChildItem -LiteralPath $stage -File -Filter 'Chirp-Windows-*-x64-Setup.exe')
    if ($installers.Count -ne 1) { throw 'Expected one Windows installer' }
    [void][IO.Directory]::CreateDirectory($releaseDir)
    $destination = Join-Path $releaseDir $installers[0].Name
    [IO.File]::Move($installers[0].FullName, $destination, $true)
    Get-Item -LiteralPath $destination
} finally {
    $workDir = Get-Item -LiteralPath $stage
    if ($workDir.Parent.FullName -ne $buildRoot -or $workDir.LinkType -or $workDir.Name -notmatch '^[0-9a-f]{32}$') {
        throw 'Unexpected installer staging directory'
    }
    Remove-Item -LiteralPath $workDir.FullName -Recurse
}
