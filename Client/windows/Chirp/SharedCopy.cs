using System.Text.Json;

namespace Chirp;

internal static class SharedCopy
{
    private static readonly Dictionary<string, string> ChineseErrors = Read("Errors.zh"), EnglishErrors = Read("Errors.en");
    private static readonly Dictionary<string, string> ChineseInterface = Read("Interface.zh"), EnglishInterface = Read("Interface.en");

    private static Dictionary<string, string> Read(string catalog)
    {
        using var stream = typeof(SharedCopy).Assembly.GetManifestResourceStream("Chirp." + catalog)!;
        using var reader = new StreamReader(stream);
        var messages = new Dictionary<string, string>(StringComparer.Ordinal);
        while (reader.ReadLine() is { } line)
        {
            var separator = line.IndexOf(" = ", StringComparison.Ordinal);
            if (!line.StartsWith('"') || !line.EndsWith(';') || separator < 2) continue;
            var key = JsonSerializer.Deserialize<string>(line[..separator])!;
            messages.Add(key, JsonSerializer.Deserialize<string>(line[(separator + 3)..^1])!);
        }
        return messages;
    }

    internal static string Text(string key, bool english) => (english ? EnglishInterface : ChineseInterface)[key];

    internal static string Error(string code, bool english)
    {
        var messages = english ? EnglishErrors : ChineseErrors;
        var known = messages.GetValueOrDefault(code) ?? messages.GetValueOrDefault("CLIENT_" + code);
        if (known is not null) return known;
        // Keep a support reference for an unfamiliar server code. Never expose raw exception text or file paths.
        if (code.Length is > 1 and <= 81 && char.IsAsciiLetterUpper(code[0]) &&
            code.All(c => char.IsAsciiLetterUpper(c) || char.IsAsciiDigit(c) || c == '_'))
            return $"{messages["CLIENT_UNKNOWN_SERVER_ERROR"]} ({code})";
        return messages["CLIENT_UNEXPECTED"];
    }
}
