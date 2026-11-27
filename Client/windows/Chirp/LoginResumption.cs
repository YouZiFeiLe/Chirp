using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Security.Credentials.UI;

namespace Chirp;

public sealed partial class MainPage
{
    private static readonly LoginLock loginLock = new();
    private static WindowsHelloLoginKey HelloKey => new(data.LocalPath);
    private static string? helloAttempt;
    private static MainWindow? helloOwner;
    private static bool helloOpen => helloAttempt is not null;
    private static bool sessionLocked;
    private static DispatcherTimer? unlockMonitor, loginDeadline;
    private static long onlineExpires;
    private static string onlineLogin = "", resumption = "";
    private static bool enrollingHello;
    private static int helloKeyGeneration;
    private static long NowSeconds => DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    private static MainPage? ForegroundPage => sessionLocked ? null :
        App.Pages.FirstOrDefault(p => p.loaded && !p.closed && p.Owner.AtFront());

    private async Task<JsonNode?> CompletePasskey(string op, string? url = null, string? id = null)
    {
        byte[]? publicKey = null;
        var available = false;
        try
        {
            publicKey = await Task.Run(HelloKey.ExistingPublicKey);
            available = publicKey is not null || await UserConsentVerifier.CheckAvailabilityAsync() == UserConsentVerifierAvailability.Available;
        }
        catch (UnprotectedLoginKeyException) { DeleteHelloKey(); available = true; }
        catch (Exception e) when (e is CryptographicException or UnauthorizedAccessException or COMException or PlatformNotSupportedException) { }
        return await Rpc(op, new { url, id, enabled = available, file = publicKey });
    }

    private async Task EnableLoginResumption()
    {
        var login = onlineLogin;
        if (enrollingHello || resumption != "available" || !Online()) return;
        bool Online() => !App.Exiting && !closed && member is not null && login == onlineLogin && onlineExpires > NowSeconds;
        var generation = helloKeyGeneration;
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(Owner);
        enrollingHello = true;
        try
        {
            var publicKey = await Task.Run(() => HelloKey.Enroll(hwnd));
            if (generation != helloKeyGeneration) { DeleteHelloKey(); return; }
            if (!Online()) return;
            await Rpc("enableLoginResumption", new { id = login, file = publicKey });
            if (!Online()) return;
            resumption = "enabled";
            foreach (var page in App.Pages)
                if (page.selectionType == "settings") page.Render();
            Show(() => T("已启用 Windows Hello，下次打开 Chirp 时可用它解锁。", "Windows Hello is enabled for the next time you open Chirp."), InfoBarSeverity.Success);
        }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is CryptographicException or UnauthorizedAccessException or COMException or PlatformNotSupportedException)
        {
            if (e is UnprotectedLoginKeyException) DeleteHelloKey();
            if (Online()) Show(() => T("未能启用 Windows Hello。可以继续使用 Chirp，稍后在设置中重试。",
                "Windows Hello could not be enabled. You can keep using Chirp and try again in Settings."), InfoBarSeverity.Error);
        }
        finally { enrollingHello = false; }
    }

    private static void DeleteHelloKey()
    {
        helloKeyGeneration++;
        try { HelloKey.Delete(); }
        catch (Exception e) when (e is CryptographicException or UnauthorizedAccessException or PlatformNotSupportedException) { }
    }

    private async Task ForgetLogin()
    {
        try { await Rpc("logout"); }
        catch (IOException e) when (e is not ProtocolException || e.Message == "LOGIN_STORAGE_UNAVAILABLE")
        {
            // If local deletion could not be confirmed, invalidate its wrapping key as well.
            DeleteHelloKey();
            throw;
        }
    }

    private async Task LoadLoginLock()
    {
        var hint = await Rpc("savedLogin");
        if (hint is null || closed) return;
        loginLock.Load(hint.Num("expires"), Convert.FromBase64String(hint.Str("wrappedKey")), NowSeconds);
        SetLoginDeadline(loginLock.Expires);
        UpdateLockControls();
    }

    private static void SetLoginDeadline(long expires)
    {
        loginDeadline?.Stop();
        if (expires == 0) return;
        if (loginDeadline is null)
        {
            loginDeadline = new DispatcherTimer();
            loginDeadline.Tick += (_, _) => CheckLoginDeadline();
        }
        loginDeadline.Interval = TimeSpan.FromMilliseconds(Math.Max(1,
            (DateTimeOffset.FromUnixTimeSeconds(expires) - DateTimeOffset.UtcNow).TotalMilliseconds));
        loginDeadline.Start();
    }

    private static void CheckLoginDeadline()
    {
        if (App.Exiting) return;
        var now = NowSeconds;
        if (member is not null && onlineExpires > 0 && onlineExpires <= now)
        {
            protocol?.Notify("checkLogin", new { });
            App.Primary.Page.SignedOut(restore: false, reason: "CLIENT_LOGIN_EXPIRED");
        }
        else if (loginLock.Locked && loginLock.Expires <= now)
        {
            InterruptUnlock();
            loginLock.Clear();
            SetLoginDeadline(0);
            protocol?.Notify("savedLogin", new { });
            UpdateLockControls();
            foreach (var page in App.Pages) page.ShowError("CLIENT_LOGIN_EXPIRED");
        }
    }

    private static void UpdateLockControls()
    {
        foreach (var page in App.Pages)
        {
            page.UpdateLoginStage();
            page.UpdateLoginBusy();
        }
    }

    internal static void SessionLockChanged(bool locked)
    {
        sessionLocked = locked;
        if (locked) InterruptUnlock();
        else UpdateUnlockActivity();
    }

    internal static void LeftForeground()
    {
        if (!helloOpen) InterruptUnlock();
    }

    internal static void InterruptUnlock(bool cancelRequest = true)
    {
        if (loginLock.Attempt is not { } id) return;
        loginLock.Interrupt();
        if (cancelRequest) protocol?.Notify("cancelResume", new { id });
        unlockMonitor?.Stop();
        UpdateLockControls();
    }

    internal static void UpdateUnlockActivity()
    {
        if (App.Exiting) return;
        CheckLoginDeadline();
        if (!loginLock.Locked || !loginInitialized) return;
        var front = ForegroundPage;
        if (front is null || !ClockReady)
        {
            // The OS owns focus during Hello. Deactivation to another app or a
            // minimized owner cancels this attempt, including a late HTTP success.
            if (!helloOpen || !ClockReady || sessionLocked || helloOwner?.HasHelloForeground() != true)
                InterruptUnlock();
            return;
        }
        if (!busy && !helloOpen) _ = front.UnlockLogin(manual: false);
    }

    private async void UnlockClick(object sender, RoutedEventArgs args) => await UnlockLogin(manual: true);

    private async Task UnlockLogin(bool manual)
    {
        if (ForegroundPage != this || !ClockReady || helloOpen || busy || loginLock.Begin(manual, NowSeconds) is not { } id) return;
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(Owner);
        var prompt = T("解锁 Chirp", "Unlock Chirp");
        var wrapped = loginLock.WrappedKey;
        if (unlockMonitor is null)
        {
            unlockMonitor = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
            unlockMonitor.Tick += (_, _) => UpdateUnlockActivity();
        }
        unlockMonitor.Start();
        helloAttempt = id;
        helloOwner = Owner;
        UpdateLockControls();
        bool Current() => !App.Exiting && ClockReady && !sessionLocked && loginLock.Current(id, NowSeconds);
        void EndPrompt()
        {
            if (helloAttempt == id) { helloAttempt = null; helloOwner = null; }
        }
        try
        {
            var key = await Task.Run(() => HelloKey.Unlock(hwnd, prompt, wrapped));
            try
            {
                // CredentialUIBroker may release its HWND just before the owner
                // receives activation. Keep network traffic behind real foreground.
                for (var i = 0; Current() && ForegroundPage is null && Owner.HasHelloForeground() && i < 20; i++)
                    await Task.Delay(50);
                EndPrompt();
                if (!Current() || ForegroundPage is null) return;
                await Rpc("resumeLogin", new { id, file = key });
            }
            finally { CryptographicOperations.ZeroMemory(key); }
            if (!Current() || ForegroundPage is null) return;
            var result = await Rpc("commitResume", new { id });
            if (!Current() || ForegroundPage is null) return;
            loginLock.Clear();
            unlockMonitor.Stop();
            await AfterLogin(result);
        }
        catch (OperationCanceledException) { }
        catch (UnprotectedLoginKeyException)
        {
            if (!App.Exiting && ReferenceEquals(wrapped, loginLock.WrappedKey))
            {
                DeleteHelloKey();
                try { await DiscardLockedLogin(); ShowError("HELLO_KEY_UNAVAILABLE"); }
                catch (IOException ex) { ShowError(ex); }
            }
        }
        catch (Exception ex)
        {
            if (!Current()) return;
            if (ex is ProtocolException)
            {
                // The engine removes definitively invalid records. Transient
                // failures keep the same absolute deadline and permit manual retry.
                JsonNode? hint;
                try { hint = await Rpc("savedLogin"); }
                catch (IOException error) { if (Current()) ShowError(error); return; }
                if (!Current()) return;
                if (hint is null)
                {
                    loginLock.Clear();
                    SetLoginDeadline(0);
                    if (ex.Message is "CLIENT_UPDATE_REQUIRED" or "SERVER_CONFIGURATION_CHANGED") connection = null;
                }
            }
            if (ex is CryptographicException) ShowError("HELLO_KEY_UNAVAILABLE");
            else ShowError(ex);
        }
        finally
        {
            EndPrompt();
            if (loginLock.Attempt == id) InterruptUnlock();
            if (loginLock.Attempt is null) unlockMonitor.Stop();
            if (!App.Exiting) UpdateLockControls();
        }
    }

    private async void UsePasskeyClick(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        await DiscardLockedLogin();
        LoginNotice.IsOpen = false;
        if (connection is not null && ClockReady) await OpenPasskey();
    }, true);

    private async Task DiscardLockedLogin()
    {
        InterruptUnlock(cancelRequest: false);
        try { await ForgetLogin(); }
        finally
        {
            loginLock.Clear();
            SetLoginDeadline(0);
            UpdateLockControls();
        }
    }
}
