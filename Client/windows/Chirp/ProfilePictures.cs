using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Chirp;

public sealed partial class MainPage
{
    private static readonly MemberProfiles<BitmapImage> profiles = new(async (id, revision, token) =>
    {
        token.ThrowIfCancellationRequested();
        var result = await App.Primary.Page.Rpc("getAvatar", new { id, key = revision });
        token.ThrowIfCancellationRequested();
        return await Dialogs.Bitmap(Convert.FromBase64String(result.Str("file")));
    });

    private static PersonPicture ProfilePicture(string identity, int size, string fallbackName = "")
    {
        var account = identity.Split(".login_", 2, StringSplitOptions.None)[0];
        var color = account.EnumerateRunes().Sum(r => r.Value) % 4;
        var picture = new PersonPicture { Width = size, Height = size, Style = Design($"ChirpAvatar{color}") };
        AutomationProperties.SetAccessibilityView(picture, AccessibilityView.Raw);
        void Update()
        {
            var name = fallbackName.Length > 0 ? fallbackName : profiles.Profile(identity).Str("display_name");
            picture.Initials = StringInfo.GetNextTextElement(name.Trim());
            picture.ProfilePicture = profiles.Image(identity);
        }
        picture.Loaded += (_, _) => { profiles.Changed += Update; Update(); };
        picture.Unloaded += (_, _) => profiles.Changed -= Update;
        Update();
        return picture;
    }

    private static void ApplyOwnProfile(JsonNode? login, JsonNode? profile)
    {
        if (login is null || !ReferenceEquals(login, member) || profile is null || profile.Str("id") != login.Str("id")) return;
        profiles.Apply(profile);
        foreach (var page in App.Pages) page.UpdateSidebarIdentity();
    }
}
