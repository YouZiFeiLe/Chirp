# Run on an isolated client's Chinese settings page in the theme being tested.
param([Parameter(Mandatory)][int]$AppPid)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$capture = Join-Path ([IO.Path]::GetTempPath()) ("chirp-icon-" + [guid]::NewGuid() + ".png")

function Invoke-SettingsUI([string[]]$Arguments) {
    winapp ui @Arguments -a $AppPid | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "winapp ui $($Arguments -join ' ') failed" }
}

function Get-IconColor([string]$Selector, [string]$Type) {
    Invoke-SettingsUI @('screenshot', $Selector, '--type', $Type, '-o', $capture)
    $bitmap = [Drawing.Bitmap]::new($capture)
    try {
        # Sample the center of the leading icon tile in physical pixels at the current DPI.
        $start = [int]($bitmap.Height * 0.3)
        $end = [int]($bitmap.Height * 0.7)
        $background = $bitmap.GetPixel($start, $start).ToArgb()
        $ink = @{}
        for ($y = $start; $y -lt $end; $y++) {
            for ($x = $start; $x -lt $end; $x++) {
                $color = $bitmap.GetPixel($x, $y).ToArgb()
                if ($color -ne $background) { $ink[$color]++ }
            }
        }
        if ($ink.Count -eq 0) { throw "$Selector has an empty icon tile" }
        return ($ink.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    } finally {
        $bitmap.Dispose()
    }
}

function Assert-RepositoryIcon([string]$Title, [int]$ExpectedColor) {
    Invoke-SettingsUI @('wait-for', 'ProjectRepository', '-p', 'Name', '--value', $Title)
    if ((Get-IconColor 'ProjectRepository' 'Hyperlink') -ne $ExpectedColor) {
        throw "The icon for '$Title' does not match the audio settings icon color"
    }
}

try {
    $accent = Get-IconColor '声音设置' 'Button'
    Assert-RepositoryIcon '项目地址' $accent
    Invoke-SettingsUI @('invoke', '界面语言', '--type', 'ComboBox')
    Invoke-SettingsUI @('invoke', 'English', '--type', 'ListItem')
    Assert-RepositoryIcon 'Project URL' $accent
    Invoke-SettingsUI @('invoke', 'Display language', '--type', 'ComboBox')
    Invoke-SettingsUI @('invoke', '简体中文', '--type', 'ListItem')
    Assert-RepositoryIcon '项目地址' $accent
    Write-Output 'PASS repository icon and accent color across language changes'
} finally {
    if (Test-Path -LiteralPath $capture) { Remove-Item -LiteralPath $capture }
    if ($env:WINAPP_UI_WORKFLOW_ID) { winapp ui yield | Out-Null }
}
