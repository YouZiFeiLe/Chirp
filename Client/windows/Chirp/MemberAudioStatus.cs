using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Chirp;

public sealed partial class MainPage
{
    private static bool IsSpeaking(JsonNode? peer) => peer.Bool("mic") && peer.Bool("speaking");

    private sealed class MemberAudioIndicator
    {
        private readonly FontIcon icon = Glyph("", 18);
        private readonly TextBlock caption = Secondary("");
        public StackPanel View { get; }

        public MemberAudioIndicator()
        {
            View = Stack(icon, caption);
            View.Orientation = Orientation.Horizontal;
            View.Spacing = 4;
        }

        public void Update(bool? enabled, string glyph, string title, bool showLabel)
        {
            if (AutomationProperties.GetName(View) == title) return;
            icon.Glyph = glyph;
            icon.Style = enabled == true ? Design("ChirpBrandIcon") : null;
            caption.Text = showLabel ? title : enabled is null ? "?" : "";
            caption.Visibility = Visible(caption.Text.Length > 0);
            Label(View, title);
        }
    }

    private (StackPanel View, Func<JsonNode?, string> Update) MemberAudioIndicators(bool showLabels)
    {
        var mic = new MemberAudioIndicator();
        var speaker = new MemberAudioIndicator();
        var view = Stack(mic.View, speaker.View);
        view.Orientation = showLabels ? Orientation.Vertical : Orientation.Horizontal;
        view.HorizontalAlignment = showLabels ? HorizontalAlignment.Left : HorizontalAlignment.Center;
        view.Spacing = showLabels ? 6 : 16;

        string Update(JsonNode? peer)
        {
            var microphone = peer?["mic"]?.GetValue<bool>();
            var listening = peer?["listening"]?.GetValue<bool>();
            var speaking = IsSpeaking(peer);
            var micTitle = microphone switch
            {
                true when speaking => L("正在讲话"),
                true => L("麦克风已开启"),
                false => L("麦克风已静音"),
                null => L("麦克风状态待同步")
            };
            var playbackTitle = listening switch
            {
                true => L("房间收听已开启"),
                false => L("房间收听已暂停"),
                null => L("收听状态待同步")
            };
            mic.Update(microphone, microphone == false ? "\uEC54" : "\uE720", micTitle, showLabels || speaking);
            speaker.Update(listening, listening == false ? "\uE74F" : "\uE767", playbackTitle, showLabels);
            return micTitle + " · " + playbackTitle;
        }
        return (view, Update);
    }
}
