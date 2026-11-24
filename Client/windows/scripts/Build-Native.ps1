[CmdletBinding()]
param([switch]$Test, [string]$ProjectAssetsFile)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$dest = Join-Path $root '.build/winui-native'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$previousPath = $env:Path
# rustup selects Client/windows/rust-toolchain.toml from Cargo's working directory.
Push-Location (Join-Path $PSScriptRoot '..')
try {
    & (Join-Path $PSScriptRoot 'Use-DevTools.ps1')
    & (Join-Path $PSScriptRoot 'Build-Audio.ps1') -Output $dest
    cargo rustc --locked --release --lib --manifest-path ../apple/MLS/native/Cargo.toml --target-dir $dest --crate-type cdylib
    if ($LASTEXITCODE) { throw 'OpenMLS build failed' }
    cargo build --locked --release --manifest-path audio/Cargo.toml --target-dir $dest
    if ($Test) {
        cargo test --locked --release --manifest-path audio/Cargo.toml --target-dir $dest
    }
    python (Join-Path $root 'scripts/prepare-mls-notices.py') --windows

    Set-Location -LiteralPath $root
    foreach ($source in @((Join-Path $dest 'release/chirp_mls_native.dll'),(Join-Path $dest 'release/chirp_windows_audio.dll'),'Client/apple/Shared/Resources/AuthorizationTrust.json')) {
        $target = Join-Path $dest (Split-Path $source -Leaf)
        if (!(Test-Path -LiteralPath $target) -or (Get-FileHash $source).Hash -ne (Get-FileHash $target).Hash) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }

    # Build only this client with the pinned SDK overlay. The server and the Go
    # module cache keep their upstream source and build flags.
    $sdk = go list -m -f '{{.Dir}}' github.com/livekit/server-sdk-go/v2
    if (!$sdk) { go mod download github.com/livekit/server-sdk-go/v2; $sdk = go list -m -f '{{.Dir}}' github.com/livekit/server-sdk-go/v2 }
    $sdkCopy = Join-Path $dest 'livekit-sdk'
    $pinned = (Split-Path $sdk -Leaf)
    $stamp = Join-Path $sdkCopy '.chirp-version'
    if (!(Test-Path -LiteralPath $stamp) -or [IO.File]::ReadAllText($stamp) -ne $pinned) {
        New-Item -ItemType Directory -Force -Path $sdkCopy | Out-Null
        Get-ChildItem -LiteralPath $sdk | Copy-Item -Destination $sdkCopy -Recurse -Force
        [IO.File]::WriteAllText($stamp,$pinned)
    }
    function Edit-SdkFile($file, $anchor, $replacement, $append, $extra = @()) {
        $original = Join-Path $sdk $file
        $source = [IO.File]::ReadAllText($original)
        if ($source.Split([string[]]@($anchor),[StringSplitOptions]::None).Length -ne 2) { throw "Review LiveKit overlay for $file" }
        $patched = $source.Replace($anchor,$replacement) + $append
        foreach ($edit in $extra) {
            if ($patched.Split([string[]]@($edit.Anchor),[StringSplitOptions]::None).Length -ne ($edit.CountExpected + 1)) { throw "Review LiveKit overlay for $file" }
            $patched = $patched.Replace($edit.Anchor,$edit.Value)
        }
        $output = Join-Path $sdkCopy $file
        (Get-Item -LiteralPath $output).IsReadOnly = $false
        [IO.File]::WriteAllText($output,$patched)
    }
    $channelAccess = @'

func (r *Room) ChirpReliable() (*webrtc.DataChannel, *webrtc.DataChannel) {
    return r.engine.GetDataChannel(livekit.DataPacket_RELIABLE), r.engine.GetDataChannelSub(livekit.DataPacket_RELIABLE)
}
func (r *Room) ChirpAllowLoopback() { r.engine.chirpLoopback = true }
func (r *Room) ChirpPrepareData() {
    if publisher, ok := r.engine.Publisher(); ok && !publisher.IsConnected() {
        publisher.Negotiate()
    }
}
'@
    $engineEdits = @(
        @{ Anchor='type RTCEngine struct {'; Value="type RTCEngine struct {`n    chirpLoopback bool"; CountExpected=1 }
        @{ Anchor='IPv6Only:                   connParams.IPv6Only,'; Value="IPv6Only:                   connParams.IPv6Only,`n        chirpLoopback: e.chirpLoopback,"; CountExpected=2 }
    )
    Edit-SdkFile 'engine.go' 'protosignalling.FromProtoIceServers(iceServers)' 'protosignalling.FromProtoIceServers(nil)' $channelAccess $engineEdits
    $transportSettings = @'
if err := webrtc.ConfigureStatsInterceptor(i); err != nil {
        return nil, err
    }
    se := webrtc.SettingEngine{}
    se.SetIncludeLoopbackCandidate(params.chirpLoopback)
    se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4, webrtc.NetworkTypeUDP6})
'@
    # The microphone encodes Opus. Only the subscriber can consume an encrypted RED track.
    $receiveRed = @'
if !params.IsSender && len(params.Codecs) == 0 {
        if err := m.RegisterCodec(codecs.RedCodecParameters, webrtc.RTPCodecTypeAudio); err != nil {
            return nil, err
        }
    }
    audioLevelExtension :=
'@
    Edit-SdkFile 'transport.go' 'se := webrtc.SettingEngine{}' $transportSettings '' @(
        @{ Anchor='type PCTransportParams struct {'; Value="type PCTransportParams struct {`n    chirpLoopback bool"; CountExpected=1 }
        @{ Anchor='"github.com/pion/webrtc/v4"'; Value='"github.com/pion/webrtc/v4"' + "`n" + '    "github.com/livekit/protocol/codecs"'; CountExpected=1 }
        @{ Anchor='audioLevelExtension :='; Value=$receiveRed; CountExpected=1 }
    )
    $modfile = Join-Path $dest 'windows.mod'
    Copy-Item -LiteralPath 'go.mod' -Destination $modfile -Force
    Copy-Item -LiteralPath 'go.sum' -Destination (Join-Path $dest 'windows.sum') -Force
    go mod edit "-modfile=$modfile" "-replace=github.com/livekit/server-sdk-go/v2=$sdkCopy"
    python Client/windows/scripts/Notices.py go $modfile (Join-Path $dest 'go-third-party.txt')
    go build -trimpath "-modfile=$modfile" -o (Join-Path $dest 'Chirp.Protocol.exe') ./Client/windows/engine
    if ($LASTEXITCODE) { throw 'Native protocol build failed' }
    if ($Test) {
        go test "-modfile=$modfile" -c -o (Join-Path $dest 'Chirp.Checks.exe') ./Client/windows/engine
        if ($LASTEXITCODE) { throw 'Protocol test build failed' }
        & (Join-Path $dest 'Chirp.Checks.exe') '-test.v'
        if ($LASTEXITCODE) { throw 'Protocol tests failed' }
    }
    if ($ProjectAssetsFile) {
        python (Join-Path $PSScriptRoot 'Notices.py') dotnet $ProjectAssetsFile (Join-Path $dest 'dotnet-third-party.txt')
    }
} finally {
    Pop-Location
    $env:Path = $previousPath
}
