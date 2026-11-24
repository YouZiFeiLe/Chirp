using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace Chirp;

public sealed partial class MainPage
{
    private static Style Design(string key) => (Style)Application.Current.Resources[key];

    private static TextBlock Text(string value, double size = 14, string style = "ChirpBody") => new()
    {
        Style = Design(style),
        Text = value,
        FontSize = size,
        VerticalAlignment = VerticalAlignment.Center
    };

    private static TextBlock Secondary(string value, double size = 13) => Text(value, size, "ChirpSecondary");

    private static TextBlock Heading(string value, double size = 20)
    {
        var heading = Text(value, size, "ChirpHeading");
        AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level2);
        return heading;
    }

    private static StackPanel Stack(params UIElement[] children)
    {
        var panel = new StackPanel { Spacing = 10 };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    private static ActionWrapPanel Row(params UIElement[] children)
    {
        var panel = new ActionWrapPanel();
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    // Give the text the remaining width so long names and translations can wrap.
    private static Grid Line(FrameworkElement content, FrameworkElement? leading = null, FrameworkElement? trailing = null)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        if (leading is not null)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(leading);
        }
        Grid.SetColumn(content, grid.ColumnDefinitions.Count);
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(content);
        if (trailing is not null)
        {
            Grid.SetColumn(trailing, grid.ColumnDefinitions.Count);
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(trailing);
        }
        return grid;
    }

    private static Border Card(params UIElement[] children) => new() { Style = Design("ChirpCard"), Child = Stack(children) };

    private static FontIcon Glyph(string glyph, double size = 16)
    {
        var icon = new FontIcon { Glyph = glyph, FontSize = size };
        AutomationProperties.SetAccessibilityView(icon, AccessibilityView.Raw);
        return icon;
    }

    private static Border IconTile(string glyph)
    {
        var icon = Glyph(glyph, 19);
        icon.Style = Design("ChirpBrandIcon");
        return new Border { Style = Design("ChirpInset"), Width = 38, Height = 38, Child = icon };
    }

    private static void Label(FrameworkElement element, string label)
    {
        AutomationProperties.SetName(element, label);
        ToolTipService.SetToolTip(element, label);
    }

    private static void ButtonLabel(Button button, string label, string glyph)
    {
        if (button.Content is Grid && AutomationProperties.GetName(button) == label) return;
        var line = Line(new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center }, Glyph(glyph));
        line.ColumnSpacing = 8;
        button.Content = line;
        AutomationProperties.SetName(button, label);
    }

    private Button ActionButton(string label, Func<Task> action, bool primary = false, string? glyph = null)
    {
        var button = new Button { Content = label, Style = Design(primary ? "ChirpPrimary" : "ChirpButton") };
        if (glyph is not null) ButtonLabel(button, label, glyph);
        button.Click += async (_, _) => { button.IsEnabled = false; await Run(action); button.IsEnabled = true; };
        return button;
    }

    private static Border EmptyState(string title, string detail, FrameworkElement illustration)
    {
        var copy = Stack(Heading(title, 18), Secondary(detail, 14));
        copy.Spacing = 5;
        return Card(Line(copy, illustration));
    }
}

// Native buttons keep their normal tab order when a narrow pane or larger text wraps a row.
public sealed partial class ActionWrapPanel : Panel
{
    private const double Gap = 8;

    protected override Size MeasureOverride(Size available) => Layout(available.Width, arrange: false);

    protected override Size ArrangeOverride(Size final)
    {
        Layout(final.Width, arrange: true);
        return final;
    }

    private Size Layout(double width, bool arrange)
    {
        double x = 0, y = 0, rowHeight = 0, usedWidth = 0;
        foreach (var child in Children)
        {
            if (child.Visibility == Visibility.Collapsed) continue;
            if (!arrange) child.Measure(new Size(width, double.PositiveInfinity));
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > width)
            {
                x = 0;
                y += rowHeight + Gap;
                rowHeight = 0;
            }
            if (arrange) child.Arrange(new Rect(x, y, size.Width, size.Height));
            usedWidth = Math.Max(usedWidth, x + size.Width);
            x += size.Width + Gap;
            rowHeight = Math.Max(rowHeight, size.Height);
        }
        return new Size(usedWidth, y + rowHeight);
    }
}
