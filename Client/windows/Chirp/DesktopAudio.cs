using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Windows.Devices.Enumeration;
using Windows.Media.Devices;

namespace Chirp;

public sealed partial class MainPage
{
    private static AudioRoute CurrentRoute() => new(audio.InputId, audio.OutputId, audio.Preset);
    private static event Action? RoutesChanged;
    private static string resolvedInput = "", resolvedOutput = "", captureFailedEntry = "";
    private static volatile bool routeSuspended;
    private static bool changingMicrophone;
    private static bool resumingAudio, routeFellBack;
    private static int interruption;
    private static long nextPlaybackCheck;
    private DeviceWatcher? inputWatcher, outputWatcher;
    private DispatcherTimer? routeTimer;
    private PowerCallback? powerCallback;
    private nint powerRegistration;
    private delegate nint PowerCallback(nint hwnd, uint message, nuint wParam, nint lParam, nuint subclass, nuint data);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(nint hwnd, PowerCallback callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(nint hwnd, PowerCallback callback, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern nint RegisterSuspendResumeNotification(nint recipient, uint flags);
    [DllImport("user32.dll")] private static extern bool UnregisterSuspendResumeNotification(nint registration);

    private void WatchAudioRoutes()
    {
        routeTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        routeTimer.Tick += (_, _) => { routeTimer.Stop(); _ = Run(() => { RefreshRoutes(); return Task.CompletedTask; }); };
        DeviceWatcher Watch(DeviceClass kind)
        {
            var watcher = DeviceInformation.CreateWatcher(kind);
            watcher.Added += (_, _) => QueueRouteRefresh(); watcher.Removed += (_, _) => QueueRouteRefresh();
            watcher.Updated += (_, _) => QueueRouteRefresh(); watcher.Start(); return watcher;
        }
        inputWatcher = Watch(DeviceClass.AudioCapture); outputWatcher = Watch(DeviceClass.AudioRender);
        MediaDevice.DefaultAudioCaptureDeviceChanged += DefaultInputChanged;
        MediaDevice.DefaultAudioRenderDeviceChanged += DefaultOutputChanged;
        NetworkChange.NetworkAvailabilityChanged += NetworkChanged;
        powerCallback = (hwnd, message, wParam, lParam, _, _) =>
        {
            if (message == 0x0218 && !closed)
            {
                if (wParam == 4) _ = Run(SuspendAudio);
                if (wParam is 7 or 18) _ = Run(ResumeAudio);
            }
            return DefSubclassProc(hwnd, message, wParam, lParam);
        };
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(Owner);
        if (SetWindowSubclass(hwnd, powerCallback, 1, 0)) powerRegistration = RegisterSuspendResumeNotification(hwnd, 0);
        QueueRouteRefresh();
    }
    private void NetworkChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        if (e.IsAvailable) DispatcherQueue.TryEnqueue(() => _ = Run(RefreshNetwork));
        else DispatcherQueue.TryEnqueue(MarkDirectoryStale);
    }
    private async Task RefreshNetwork()
    {
        if (member is null) return;
        await Rpc("networkRestored"); if (directoryActive) await Refresh();
    }
    private async Task SuspendAudio()
    {
        interruption++;
        routeSuspended = true;
        presence.Resynchronize(); StopCues();
        audio.CancelTest(); audio.BeginEntry(ownEntry); audio.StopCapture(); audio.StopOutput();
        RedrawRooms();
        if (ownEntry.Length != 0) await Rpc("audioSuspended", new { entry = ownEntry, enabled = true });
    }
    private async Task ResumeAudio()
    {
        if (!routeSuspended || resumingAudio) return;
        var operation = interruption;
        var entry = ownEntry;
        resumingAudio = true;
        try
        {
            if (member is not null) await RefreshNetwork();
            if (operation != interruption) return;
            if (entry.Length != 0 && entry == ownEntry)
                await Rpc("audioSuspended", new { entry, enabled = false });
            if (operation != interruption) return;
            routeSuspended = false;
            nextPlaybackCheck = 0; RefreshRoutes();
            if (call is not null) ApplyCall(await Rpc("room"));
        }
        finally { resumingAudio = false; RedrawRooms(); }
    }
    private void KeepRoomOutput()
    {
        if (routeSuspended || ownEntry.Length == 0 || resolvedOutput.Length == 0 || AudioService.Now < nextPlaybackCheck) return;
        nextPlaybackCheck = AudioService.Now + 1000;
        try { audio.OpenOutput(); }
        catch (Exception ex) when (ex is COMException or IOException or InvalidOperationException)
        { nextPlaybackCheck += 4000; App.Shell.Page.ShowError(ex); }
    }
    private void QueueRouteRefresh() => DispatcherQueue.TryEnqueue(() => { if (!closed) { routeTimer?.Stop(); routeTimer?.Start(); } });
    private void DefaultInputChanged(object sender, DefaultAudioCaptureDeviceChangedEventArgs args) => QueueRouteRefresh();
    private void DefaultOutputChanged(object sender, DefaultAudioRenderDeviceChangedEventArgs args) => QueueRouteRefresh();
    private void UnwatchAudioRoutes()
    {
        routeTimer?.Stop(); inputWatcher?.Stop(); outputWatcher?.Stop();
        MediaDevice.DefaultAudioCaptureDeviceChanged -= DefaultInputChanged;
        MediaDevice.DefaultAudioRenderDeviceChanged -= DefaultOutputChanged;
        NetworkChange.NetworkAvailabilityChanged -= NetworkChanged;
        if (powerRegistration != 0) UnregisterSuspendResumeNotification(powerRegistration);
        if (powerCallback is not null) RemoveWindowSubclass(WinRT.Interop.WindowNative.GetWindowHandle(Owner), powerCallback, 1);
    }
    private void RefreshRoutes()
    {
        if (routeSuspended) return;
        var saved = CurrentRoute();
        var available = saved.WithAvailableEndpoints(AudioService.ActiveId);
        ChangeRoute(available);
        if (saved != available) routeFellBack = true;
        KeepRoomOutput();
        RoutesChanged?.Invoke();
    }
    private void ChangeRoute(AudioRoute next)
    {
        var previous = CurrentRoute();
        var input = AudioService.ActiveId(true, next.Input); var output = AudioService.ActiveId(false, next.Output);
        if (next.Input.Length > 0 && input.Length == 0 || next.Output.Length > 0 && output.Length == 0) throw new IOException("AUDIO_DEVICE_UNAVAILABLE");
        if (next == previous && input == resolvedInput && output == resolvedOutput) return;
        var needInput = next.Input != previous.Input || input != resolvedInput || next.Preset != previous.Preset;
        var needOutput = next.Output != previous.Output || output != resolvedOutput;
        var capture = needInput && !changingMicrophone && !call.Bool("muted") && audio.Permitted(ownEntry, call.Str("group"));
        var play = needOutput && (audio.HasOutput || ownEntry.Length > 0);
        void Apply(AudioRoute route, bool canCapture, bool canPlay)
        {
            if (needInput) { audio.CancelTest(); audio.StopCapture(); }
            if (needOutput) { StopCues(); audio.StopOutput(); }
            audio.InputId = route.Input; audio.OutputId = route.Output;
            audio.Preset = route.Preset;
            if (canPlay) audio.OpenOutput();
            if (canCapture) audio.StartCapture(call.Str("group"));
        }
        if (next.Preset != previous.Preset) AudioService.ValidateProcessing(next.Preset != 2, next.Preset != AudioService.SystemCommunicationsPreset);
        next.ApplyOrRestore(() => Apply(next, capture && input.Length != 0, play && output.Length != 0),
            () => Apply(previous, capture && AudioService.ActiveId(true, previous.Input) != "", play && AudioService.ActiveId(false, previous.Output) != ""),
            rollback => CaptureFailed(rollback.Message));
        resolvedInput = input; resolvedOutput = output;
        SyncLogAudio();
        LogUI("routeChanged");
        Set("input", next.Input); Set("output", next.Output);
        if (next.Preset != previous.Preset) Set("preset", next.Preset);
        if (capture && input.Length == 0) CaptureFailed("AUDIO_DEVICE_UNAVAILABLE");
    }
    private void AudioFailed(string message)
    {
        LogUI("captureFailed", outcome: "failed");
        if (closed || routeSuspended) return;
        if (audio.TestBusy) { audio.CancelTest(); App.Shell.Page.ShowError(message); return; }
        try
        {
            var old = resolvedInput; RefreshRoutes();
            if (old != resolvedInput && audio.Capturing(call.Str("group"))) return;
        }
        catch (Exception) { }
        CaptureFailed(message);
    }
    private void CaptureFailed(string message)
    {
        audio.StopCapture();
        var entry = ownEntry;
        if (entry.Length > 0 && entry != captureFailedEntry)
        {
            captureFailedEntry = entry;
            _ = Run(async () => { if (ownEntry == entry) await Rpc("mute", new { enabled = true, entry }); });
        }
        App.Shell.Page.ShowError(message);
    }

    private static readonly List<(bool Joined, long Deadline)> cues = new();
    private static int cueGeneration;
    private static bool playingCues;
    private void Sound(bool joined)
    {
        if (GetInt("sounds", 1) == 0 || !audio.Listen || routeSuspended) return;
        var now = AudioService.Now;
        cues.RemoveAll(c => c.Deadline < now);
        if (cues.Count > 0 && cues[^1].Joined == joined) cues[^1] = (joined, now + 3000);
        else { if (cues.Count == 4) cues.RemoveAt(0); cues.Add((joined, now + 3000)); }
        if (!playingCues) _ = PlayCues(cueGeneration);
    }
    private async Task PlayCues(int generation)
    {
        playingCues = true;
        try
        {
            while (generation == cueGeneration && cues.Count > 0)
            {
                var next = cues[0]; cues.RemoveAt(0);
                if (next.Deadline < AudioService.Now) continue;
                try
                {
                    var samples = await Task.Run(() => AudioService.ReadCue(next.Joined));
                    if (generation != cueGeneration || next.Deadline < AudioService.Now) continue;
                    await Task.Delay(audio.PlayCue(samples));
                }
                catch (Exception ex) when (ex is COMException or IOException or ArgumentException or InvalidOperationException)
                { if (generation == cueGeneration) ShowError(ex); }
            }
        }
        finally { if (generation == cueGeneration) playingCues = false; }
    }
    private static void StopCues()
    {
        cueGeneration++; cues.Clear(); playingCues = false;
        audio.StopCue();
    }
}
