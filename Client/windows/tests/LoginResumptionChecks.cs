using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Chirp;
using Windows.Security.Credentials.UI;

internal static class LoginResumptionChecks
{
    [DllImport("kernel32.dll")] private static extern nint GetConsoleWindow();

    public static void CheckLock()
    {
        var state = new LoginLock();
        var wrapped = new byte[256];
        if (state.Begin(manual: false, 99) is not null || state.Begin(manual: true, 99) is not null)
            throw new Exception("a first launch offered Windows Hello");
        state.Load(100, wrapped, 99);
        var first = state.Begin(manual: false, 99) ?? throw new Exception("missing cold launch prompt");
        if (state.Begin(manual: false, 99) is not null) throw new Exception("second window duplicated the prompt");
        state.Interrupt();
        if (state.Current(first, 99) || state.Begin(manual: false, 99) is not null)
            throw new Exception("background/cancel allowed automatic retry");
        var retry = state.Begin(manual: true, 99) ?? throw new Exception("manual retry was refused");
        if (!state.Current(retry, 99) || state.Current(first, 99) || state.Current(retry, 100))
            throw new Exception("attempt or deadline mismatch");
        state.Clear();
        if (state.Locked || state.Current(retry, 99) || state.Begin(manual: true, 99) is not null)
            throw new Exception("logout retained the locked login");
        state.Load(100, wrapped, 100);
        if (state.Locked) throw new Exception("expired login offered Hello");
        Console.WriteLine("PASS cold launch, concurrent windows, manual retry, late response and absolute expiry");
    }

    // Use a unique container and public test data, independent of any installed Chirp login.
    public static async Task CheckProvider(bool interactive)
    {
        var availability = await UserConsentVerifier.CheckAvailabilityAsync();
        if (availability != UserConsentVerifierAvailability.Available)
        {
            Console.WriteLine($"SKIP Windows Hello provider ({availability})");
            return;
        }
        var key = new WindowsHelloLoginKey(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")));
        var owner = GetConsoleWindow();
        try
        {
            if (key.ExistingPublicKey() is not null || key.ExistingPublicKey() is not null)
                throw new Exception("first sign-in created a Windows Hello key");
            Console.WriteLine("PASS first sign-in checks a fresh container twice without enrollment or verification");
            if (!interactive) return;
            var enrolled = key.Enroll(owner);
            if (!enrolled.AsSpan().SequenceEqual(key.ExistingPublicKey()))
                throw new Exception("subsequent sign-in could not silently reuse the enrolled key");
            using var rsa = RSA.Create();
            rsa.ImportSubjectPublicKeyInfo(enrolled, out _);
            Console.WriteLine("PASS Windows Hello denied silent decryption of a freshly wrapped key");
            var value = RandomNumberGenerator.GetBytes(32);
            var wrapped = rsa.Encrypt(value, RSAEncryptionPadding.Pkcs1);
            for (var i = 0; i < 2; i++)
            {
                var result = key.Unlock(owner, "Unlock the Chirp test record", wrapped);
                if (!CryptographicOperations.FixedTimeEquals(value, result)) throw new Exception("wrong test data key");
                CryptographicOperations.ZeroMemory(result);
            }
            Console.WriteLine("PASS two interactive unlocks, with silent reads denied before and after each");
        }
        finally { key.Delete(); }
    }
}
