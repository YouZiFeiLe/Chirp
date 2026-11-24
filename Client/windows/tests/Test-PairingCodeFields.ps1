# Run on an isolated client's empty approval dialog after importing the new device's request.
param([Parameter(Mandatory)][int]$AppPid)

$ErrorActionPreference = 'Stop'
function Invoke-PairingUI([string[]]$Arguments) {
    winapp ui @Arguments -a $AppPid | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "winapp ui $($Arguments -join ' ') failed" }
}

try {
    foreach ($group in 1..3) {
        Invoke-PairingUI @('wait-for', "PairingCodeGroup$group", '--type', 'Edit', '--value', '')
    }
    Invoke-PairingUI @('wait-for', 'PrimaryButton', '-p', 'IsEnabled', '--value', 'False')

    # Send all digits in one burst so a delayed focus change cannot hide lost keystrokes.
    Invoke-PairingUI @('send-keys', 'text=001203456789', '--target', 'PairingCodeGroup1', '--via', 'send-input')
    Invoke-PairingUI @('wait-for', 'PairingCodeGroup1', '--value', '0012')
    Invoke-PairingUI @('wait-for', 'PairingCodeGroup2', '--value', '0345')
    Invoke-PairingUI @('wait-for', 'PairingCodeGroup3', '--value', '6789')
    Invoke-PairingUI @('wait-for', 'PrimaryButton', '-p', 'IsEnabled', '--value', 'True')

    Invoke-PairingUI @('send-keys', 'ctrl+a backspace backspace', '--target', 'PairingCodeGroup3', '--via', 'send-input')
    Invoke-PairingUI @('wait-for', 'PairingCodeGroup2', '--value', '034')
    Invoke-PairingUI @('send-keys', 'text=5a1', '--via', 'send-input')
    Invoke-PairingUI @('wait-for', 'PairingCodeGroup2', '--value', '0345')
    Invoke-PairingUI @('wait-for', 'PairingCodeGroup3', '--value', '1')
    Invoke-PairingUI @('wait-for', 'PrimaryButton', '-p', 'IsEnabled', '--value', 'False')
} finally {
    winapp ui yield | Out-Null
}
