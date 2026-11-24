# Use newer portable tools from this checkout when the current PATH resolves an older copy.
$toolsRoot = Join-Path $PSScriptRoot '../../../.build/windows-tools'
foreach ($relativePath in 'git-2.56.1/cmd/git.exe', 'python-3.15.2-embed-amd64/python.exe', 'powershell-7.7.0/pwsh.exe') {
    $portable = Get-Item -LiteralPath (Join-Path $toolsRoot $relativePath) -ErrorAction SilentlyContinue
    if (!$portable) { continue }

    $current = Get-Command $portable.Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$current -or $portable.VersionInfo.ProductVersionRaw -gt $current.Version) {
        $env:Path = $portable.DirectoryName + [IO.Path]::PathSeparator + $env:Path
    }
}
