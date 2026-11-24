using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;

namespace Chirp;

public sealed partial class MainPage
{
    private static long logGeneration;
    private static event Action? LogPreferenceChanged;
    private static bool LogsEnabled => (logGeneration & 1) != 0;

    private static void ApplyLogState(JsonNode? state)
    {
        var generation = state.Num("generation");
        if (generation <= logGeneration) return;
        logGeneration = generation;
        LogPreferenceChanged?.Invoke();
    }

    internal static void LogUI(string action, bool enabled = true, string outcome = "", long? expected = null, long? durationUs = null)
    {
        var generation = expected ?? logGeneration;
        if ((generation & 1) != 0 && generation == logGeneration)
            protocol?.Notify("logUI", new { action, enabled, outcome, generation, durationUs });
    }

    private readonly struct ScreenLog(string name, long generation) : IDisposable
    {
        public void Dispose() => LogUI(name, enabled: false, expected: generation);
    }

    private static ScreenLog LogScreen(string name)
    {
        LogUI(name);
        return new(name, logGeneration);
    }

    private static async Task<bool> LogAction(string name, Func<Task<bool>> action, long? expected = null)
    {
        var generation = expected ?? logGeneration;
        if ((generation & 1) == 0 || generation != logGeneration) return await action();
        var start = Stopwatch.GetTimestamp();
        LogUI(name, outcome: "started", expected: generation);
        var outcome = "failed";
        try
        {
            var completed = await action();
            outcome = completed ? "succeeded" : "cancelled";
            return completed;
        }
        catch (OperationCanceledException) { outcome = "cancelled"; throw; }
        finally { LogUI(name, outcome: outcome, expected: generation, durationUs: Stopwatch.GetElapsedTime(start).Ticks / 10); }
    }

    private static async Task<string?> LogPicker(string action, Func<Task<string?>> pick)
    {
        string? path = null;
        await LogAction(action, async () => (path = await pick()) is not null);
        return path;
    }

    private static void SyncLogAudio() => protocol?.Notify("logAudioContext", new
    {
        preset = CurrentRoute().Preset, selectedInput = audio.InputId.Length != 0,
        selectedOutput = audio.OutputId.Length != 0, listening = audio.Listen
    });

    private async void LogSettingsClick(object sender, RoutedEventArgs e) => await Run(LogSettings);

    private async Task<bool> SaveLogSnapshot(JsonNode? snapshot)
    {
        try
        {
            var suggested = $"Chirp-{DateTime.Now:yyyy-MM-dd-HHmmss}.chirplog";
            var path = await Dialogs.Save(Owner, suggested, ".chirplog");
            if (path is null) return false;
            var source = snapshot.Str("path");
            var privateFolder = Path.GetDirectoryName(source)! + Path.DirectorySeparatorChar;
            if (Path.GetFullPath(path).StartsWith(privateFolder, StringComparison.OrdinalIgnoreCase))
                throw new IOException();
            await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete, 65536, useAsync: true);
            var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(path)!);
            var target = await folder.CreateFileAsync(Path.GetFileName(path), CreationCollisionOption.OpenIfExists);
            using var transaction = await target.OpenTransactedWriteAsync();
            using var output = transaction.Stream.AsStreamForWrite();
            output.SetLength(0);
            await input.CopyToAsync(output);
            await output.FlushAsync();
            await transaction.CommitAsync();
            return true;
        }
        finally { await Rpc("releaseLogExport", new { id = snapshot.Str("id") }); }
    }

    private async Task LogSettings()
    {
        ApplyLogState(await Rpc("logState"));
        using var screen = LogScreen("logSettings");
        var title = T("日志管理", "Log management");
        var toggle = new ToggleSwitch
        {
            Header = T("记录客户端日志", "Record client logs"),
            OnContent = T("已开启", "On"), OffContent = T("已关闭", "Off"), IsOn = LogsEnabled
        };
        var feedback = new InfoBar { IsOpen = false, IsClosable = true };
        var body = Stack(toggle, Secondary(T(
            "开启后，在这台电脑上保留最近 24 小时的脱敏操作记录和通话诊断。切换账号时沿用此设置。",
            "Keep the last 24 hours of redacted activity and call diagnostics on this PC. This setting applies to all accounts.")), feedback);
        var dialog = Dialogs.Box(XamlRoot, title, body, T("关闭", "Close"), T("导出日志", "Export logs"));
        dialog.SecondaryButtonText = T("清除日志", "Clear logs");
        bool changing = false;
        void SyncToggle() => toggle.IsOn = LogsEnabled;
        void Notice(string text, InfoBarSeverity severity)
        {
            feedback.Message = text;
            feedback.Severity = severity;
            feedback.IsOpen = true;
        }
        toggle.Toggled += async (_, _) =>
        {
            if (changing || toggle.IsOn == LogsEnabled) return;
            changing = true;
            toggle.IsEnabled = dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = false;
            try { ApplyLogState(await Rpc("setLogging", new { enabled = toggle.IsOn })); }
            catch (Exception) { Notice(T("无法更改日志设置。", "Could not change log settings."), InfoBarSeverity.Error); }
            finally
            {
                SyncToggle();
                changing = false;
                toggle.IsEnabled = dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = true;
            }
        };
        LogPreferenceChanged += SyncToggle;
        try
        {
            while (!closed)
            {
                var result = await dialog.ShowAsync();
                if (result == ContentDialogResult.None) return;
                try
                {
                    if (result == ContentDialogResult.Secondary)
                    {
                        if (!await Confirm(T("清除日志？", "Clear logs?"),
                            T("删除此电脑上已记录的日志。已另存的文件会保留。", "Delete recorded logs on this PC. Copies you saved elsewhere are kept."),
                            T("清除日志", "Clear logs"))) continue;
                        ApplyLogState(await Rpc("clearLogs"));
                        Notice(T("本机日志已清除。", "Local logs cleared."), InfoBarSeverity.Success);
                        continue;
                    }
                    var generation = logGeneration;
                    var snapshot = await Rpc("exportLogs");
                    if (snapshot.Bool("empty"))
                    {
                        Notice(T("最近 24 小时没有可导出的日志。", "No logs to export from the last 24 hours."), InfoBarSeverity.Informational);
                        continue;
                    }
                    if (await LogAction("exportLogs", () => SaveLogSnapshot(snapshot), generation))
                        Notice(T("日志已导出。", "Logs exported."), InfoBarSeverity.Success);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
                {
                    Notice(T("日志操作失败，请检查磁盘空间和文件权限后重试。", "Could not complete the log operation. Check disk space and file permissions, then try again."), InfoBarSeverity.Error);
                }
            }
        }
        finally { LogPreferenceChanged -= SyncToggle; }
    }
}
