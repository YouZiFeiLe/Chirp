using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Chirp;

public sealed partial class SpeakingHalo : UserControl
{
    private bool animate;

    public SpeakingHalo()
    {
        InitializeComponent();
        Loaded += (_, _) => SetPulse(animate);
        Unloaded += (_, _) => SetPulse(false);
    }

    internal void Update(bool speaking, bool animationsEnabled)
    {
        Visibility = speaking ? Visibility.Visible : Visibility.Collapsed;
        var shouldAnimate = speaking && animationsEnabled;
        if (animate == shouldAnimate) return;
        animate = shouldAnimate;
        if (IsLoaded) SetPulse(animate);
    }

    private void SetPulse(bool enabled) => VisualStateManager.GoToState(this, enabled ? "Pulsing" : "Still", false);
}
