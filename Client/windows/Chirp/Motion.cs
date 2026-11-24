using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.UI.ViewManagement;

namespace Chirp;

public sealed partial class MainPage
{
    private readonly UISettings motionSettings = new();
    private readonly Dictionary<FrameworkElement, Storyboard> motions = new();
    private bool chatClosing;

    private void MotionPreferenceChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (closed) return;
        if (!motionSettings.AnimationsEnabled)
        {
            StopMotions();
            LayoutChat();
        }
        UpdatePeerIndicators(call);
    });

    private void StopMotions()
    {
        chatClosing = false;
        foreach (var animation in motions.Values) animation.Stop();
        motions.Clear();
    }

    private void MoveSurface(FrameworkElement surface, double x = 0, double y = 0, bool leaving = false, Action? finished = null)
    {
        if (motions.Remove(surface, out var previous)) previous.Stop();
        if (!motionSettings.AnimationsEnabled || closed)
        {
            finished?.Invoke();
            return;
        }
        var shift = surface.RenderTransform as TranslateTransform ?? new TranslateTransform();
        surface.RenderTransform = shift;
        var duration = new Duration(TimeSpan.FromMilliseconds(leaving ? 145 : 225));
        var ease = new CubicEase { EasingMode = leaving ? EasingMode.EaseIn : EasingMode.EaseOut };
        var story = new Storyboard { FillBehavior = FillBehavior.Stop };
        void Track(DependencyObject target, string property, double from, double to)
        {
            var animation = new DoubleAnimation { From = from, To = to, Duration = duration, EasingFunction = ease };
            Storyboard.SetTarget(animation, target);
            Storyboard.SetTargetProperty(animation, property);
            story.Children.Add(animation);
        }
        Track(surface, "Opacity", leaving ? 1 : 0, leaving ? 0 : 1);
        if (x != 0) Track(shift, "X", leaving ? 0 : x, leaving ? x : 0);
        if (y != 0) Track(shift, "Y", leaving ? 0 : y, leaving ? y : 0);
        story.Completed += (_, _) =>
        {
            if (motions.GetValueOrDefault(surface) != story) return;
            motions.Remove(surface);
            finished?.Invoke();
        };
        motions[surface] = story;
        story.Begin();
    }
}
