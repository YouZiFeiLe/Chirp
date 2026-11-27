using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Chirp;

internal sealed class UnprotectedLoginKeyException() : CryptographicException("HELLO_KEY_UNAVAILABLE");

internal sealed class WindowsHelloLoginKey(string storage)
{
    private static readonly CngProvider Provider = new("Microsoft Passport Key Storage Provider");
    private const string CacheType = "NgcCacheType";
    private const int AuthMandatory = 1, Pkcs1 = 2, Silent = 0x40;
    private const int SilentContext = unchecked((int)0x80090022), UiRequired = unchecked((int)0x8009002E);
    private const int UserCancelled = unchecked((int)0x80090036), Cancelled = unchecked((int)0x800704C7);
    private static bool Missing(CryptographicException error) =>
        error.HResult is unchecked((int)0x8009000D) or unchecked((int)0x80090016) or unchecked((int)0x80090011);
    private readonly string name = KeyName(storage);

    private static string KeyName(string storage)
    {
        using var user = WindowsIdentity.GetCurrent();
        var installation = SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(storage).ToUpperInvariant()));
        return $"{user.User!.Value}//cn.youzifeile.Chirp//Login-v1-{Convert.ToHexString(installation)}";
    }

    [DllImport("ncrypt.dll")]
    private static extern int NCryptDecrypt(SafeNCryptKeyHandle key, byte[] input, int inputSize,
        nint padding, [Out] byte[] output, int outputSize, out int written, int flags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    private static extern int NCryptExportKey(SafeNCryptKeyHandle key, nint target, string format, nint parameters,
        [Out] byte[]? output, int outputSize, out int written, int flags);

    private static int Decrypt(CngKey key, byte[] wrapped, byte[] output, int flags, out int size)
    {
        using var handle = key.Handle;
        return NCryptDecrypt(handle, wrapped, wrapped.Length, 0, output, output.Length, out size, Pkcs1 | flags);
    }

    private static CngProperty Integer(string property, int value) =>
        new(property, BitConverter.GetBytes(value), CngPropertyOptions.None);

    private static int ReadPolicy(CngKey key, string property)
    {
        var value = key.GetProperty(property, (CngPropertyOptions)Silent).GetValue();
        return value is { Length: sizeof(int) } ? BitConverter.ToInt32(value) : throw new UnprotectedLoginKeyException();
    }

    private CngKey OpenChecked(CngKeyOpenOptions options)
    {
        var key = CngKey.Open(name, Provider, options);
        try
        {
            if (ReadPolicy(key, CacheType) != AuthMandatory || ReadPolicy(key, "Key Usage") != (int)CngKeyUsages.Decryption ||
                ReadPolicy(key, "Export Policy") != (int)CngExportPolicies.None)
                throw new UnprotectedLoginKeyException();
            return key;
        }
        catch { key.Dispose(); throw; }
    }

    // Use a real ciphertext and a real output buffer. A size query or an
    // unrelated provider error does not establish that user presence is required.
    private void RequireSilentDenial(byte[] wrapped)
    {
        using var key = OpenChecked(CngKeyOpenOptions.Silent);
        var output = new byte[256];
        try
        {
            var status = Decrypt(key, wrapped, output, Silent, out _);
            if (status == 0) throw new UnprotectedLoginKeyException();
            if (status is not (SilentContext or UiRequired))
                throw new CryptographicException("HELLO_KEY_UNAVAILABLE");
        }
        finally { CryptographicOperations.ZeroMemory(output); }
    }

    // Login may reuse an enrolled key. Only the Settings action may create one.
    public byte[]? ExistingPublicKey()
    {
        CngKey key;
        try { key = OpenChecked(CngKeyOpenOptions.Silent); }
        catch (CryptographicException e) when (Missing(e)) { return null; }
        using (key)
        using (var handle = key.Handle)
        {
            // RSA-2048 public blob: BCRYPT_RSAKEY_BLOB header, exponent 65537, modulus.
            var blob = new byte[24 + 3 + 256];
            var status = NCryptExportKey(handle, 0, "RSAPUBLICBLOB", 0, blob, blob.Length, out var written, Silent);
            if (status != 0) throw new CryptographicException(status);
            if (written != blob.Length) throw new UnprotectedLoginKeyException();
            using var publicKey = CngKey.Import(blob, CngKeyBlobFormat.GenericPublicBlob);
            using var rsa = new RSACng(publicKey);
            var probe = RandomNumberGenerator.GetBytes(32);
            try { RequireSilentDenial(rsa.Encrypt(probe, RSAEncryptionPadding.Pkcs1)); }
            finally { CryptographicOperations.ZeroMemory(probe); }
            return rsa.ExportSubjectPublicKeyInfo();
        }
    }

    public byte[] Enroll(nint owner)
    {
        if (ExistingPublicKey() is { } existing) return existing;
        var options = new CngKeyCreationParameters { Provider = Provider, ParentWindowHandle = owner };
        // Passport consumes key-creation properties without NCRYPT_PERSIST_FLAG.
        options.Parameters.Add(Integer("Key Usage", (int)CngKeyUsages.Decryption));
        options.Parameters.Add(Integer("Length", 2048));
        options.Parameters.Add(Integer(CacheType, AuthMandatory));
        try { using var created = CngKey.Create(CngAlgorithm.Rsa, name, options); }
        catch (CryptographicException e) when (e.HResult is UserCancelled or Cancelled)
        { throw new OperationCanceledException("Windows Hello", e); }
        return ExistingPublicKey() ?? throw new CryptographicException("HELLO_KEY_UNAVAILABLE");
    }

    public byte[] Unlock(nint owner, string prompt, byte[] wrapped)
    {
        if (wrapped.Length != 256) throw new CryptographicException("HELLO_KEY_UNAVAILABLE");
        RequireSilentDenial(wrapped);
        using var key = OpenChecked(CngKeyOpenOptions.None);
        key.ParentWindowHandle = owner;
        key.SetProperty(new CngProperty("Use Context", Encoding.Unicode.GetBytes(prompt + '\0'), CngPropertyOptions.None));
        key.SetProperty(Integer("PinCacheIsGestureRequired", 1));
        var output = new byte[256];
        try
        {
            var status = Decrypt(key, wrapped, output, 0, out var size);
            if (status is UserCancelled or Cancelled) throw new OperationCanceledException();
            if (status != 0 || size != 32) throw new CryptographicException(status);
            RequireSilentDenial(wrapped);
            return output[..size];
        }
        finally { CryptographicOperations.ZeroMemory(output); }
    }

    public void Delete()
    {
        try
        {
            using var key = CngKey.Open(name, Provider, CngKeyOpenOptions.Silent);
            key.Delete();
        }
        catch (CryptographicException e) when (Missing(e)) { }
    }
}
