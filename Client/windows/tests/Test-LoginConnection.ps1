# Run against an isolated Debug login window with TestLocalWinUIDesktop serving its fixture directory.
param(
    [Parameter(Mandatory)][int]$AppPid,
    [Parameter(Mandatory)][string]$FixtureDirectory
)

$ErrorActionPreference = 'Stop'
$origin = (Get-Content -Raw -LiteralPath (Join-Path $FixtureDirectory 'origin.txt')).Trim()
function Invoke-LoginUI([string[]]$Arguments) {
    winapp ui @Arguments -a $AppPid
    if ($LASTEXITCODE -ne 0) { throw "winapp ui $($Arguments -join ' ') failed" }
}

# The trailing slash makes the confirmed address differ from what the user typed.
Invoke-LoginUI @('wait-for', 'ServerAddress')
Invoke-LoginUI @('set-value', 'ServerAddress', "$origin/")
Invoke-LoginUI @('wait-for', 'ConnectServer', '-p', 'IsEnabled', '--value', 'True')
Invoke-LoginUI @('invoke', 'ConnectServer')
Invoke-LoginUI @('wait-for', 'ServerAddress', '--value', $origin)
Invoke-LoginUI @('wait-for', 'PasskeyLogin', '-p', 'IsEnabled', '--value', 'True')
Invoke-LoginUI @('wait-for', 'ConnectServer', '--gone')

Invoke-LoginUI @('set-value', 'ServerAddress', "$origin/")
Invoke-LoginUI @('wait-for', 'PasskeyLogin', '--gone')
Invoke-LoginUI @('wait-for', 'ConnectServer', '-p', 'IsEnabled', '--value', 'True')
