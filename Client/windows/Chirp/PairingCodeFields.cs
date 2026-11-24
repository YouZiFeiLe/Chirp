using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace Chirp;

public sealed partial class MainPage
{
    private const int PairingGroupLength = 4;
    private string SecurityCodeGroupLabel(int position) => T($"第 {position} 组", $"Group {position}");

    private TextBox[] AddPairingCodeFields(StackPanel body, ContentDialog dialog)
    {
        TextBox[] fields = [new(), new(), new()];
        var row = new Grid { ColumnSpacing = 10 };
        bool Complete() => fields.All(field => field.Text.Length == PairingGroupLength);

        foreach (var (index, field) in fields.Index())
        {
            var position = index + 1;
            field.Header = Secondary(SecurityCodeGroupLabel(position), 12);
            field.MaxLength = PairingGroupLength;
            field.MinWidth = 0;
            field.TextAlignment = TextAlignment.Center;
            field.FontFamily = new FontFamily("Consolas");
            field.FontSize = 22;
            field.InputScope = new InputScope { Names = { new InputScopeName { NameValue = InputScopeNameValue.Digits } } };
            AutomationProperties.SetName(field, T($"新设备安全码，第 {position} 组，4 位数字", $"New device security code, group {position}, 4 digits"));
            AutomationProperties.SetAutomationId(field, $"PairingCodeGroup{position}");
            field.BeforeTextChanging += (_, e) => e.Cancel = e.NewText.Length > PairingGroupLength || !e.NewText.All(char.IsAsciiDigit);
            // Move focus before the next keystroke, even when all twelve digits are typed quickly.
            field.TextChanging += (_, _) =>
            {
                dialog.IsPrimaryButtonEnabled = Complete();
                if (field.FocusState != FocusState.Unfocused && field.Text.Length == PairingGroupLength &&
                    position < fields.Length && fields[position].Text.Length == 0)
                    fields[position].Focus(FocusState.Keyboard);
            };
            field.PreviewKeyDown += (_, e) =>
            {
                if (e.Key != VirtualKey.Back || field.Text.Length != 0 || index == 0) return;
                e.Handled = true;
                var previous = fields[index - 1];
                previous.Focus(FocusState.Keyboard);
                if (previous.Text.Length > 0) previous.Text = previous.Text[..^1];
                previous.Select(previous.Text.Length, 0);
            };
            field.Paste += async (_, e) =>
            {
                e.Handled = true;
                await Run(() => PastePairingCode(fields, index));
            };
            row.ColumnDefinitions.Add(new ColumnDefinition());
            Grid.SetColumn(field, index);
            row.Children.Add(field);
        }
        body.Children.Add(row);
        dialog.IsPrimaryButtonEnabled = false;
        dialog.PrimaryButtonClick += (_, e) => e.Cancel = !Complete();
        dialog.Opened += (_, _) => fields[0].Focus(FocusState.Programmatic);
        return fields;
    }

    private static async Task PastePairingCode(TextBox[] fields, int index)
    {
        var field = fields[index];
        var clipboard = Clipboard.GetContent();
        if (!clipboard.Contains(StandardDataFormats.Text)) return;
        var original = field.Text;
        var start = field.SelectionStart;
        var selected = field.SelectionLength;
        var text = await clipboard.GetTextAsync();
        if (!field.IsLoaded || field.FocusState == FocusState.Unfocused ||
            field.Text != original || field.SelectionStart != start || field.SelectionLength != selected) return;
        if (text.Length > 32 || text.Any(c => !char.IsAsciiDigit(c) && c is not (' ' or '-' or '\t' or '\r' or '\n'))) return;
        var digits = string.Concat(text.Where(char.IsAsciiDigit));
        if (digits.Length == 0) return;
        if (digits.Length + original.Length - selected <= PairingGroupLength)
        {
            field.SelectedText = digits;
            return;
        }

        // A whole code replaces all groups, even when pasted into the middle field.
        var wholeCode = digits.Length == fields.Length * PairingGroupLength;
        var first = wholeCode ? 0 : index;
        var value = wholeCode ? digits : original.Remove(start, selected).Insert(start, digits);
        if (value.Length > (fields.Length - first) * PairingGroupLength) return;
        var last = first;
        for (var offset = 0; offset < value.Length; offset += PairingGroupLength)
        {
            last = first + offset / PairingGroupLength;
            fields[last].Text = value.Substring(offset, Math.Min(PairingGroupLength, value.Length - offset));
        }
        var target = fields[last];
        if (target.Text.Length == PairingGroupLength && last + 1 < fields.Length && fields[last + 1].Text.Length == 0)
            target = fields[last + 1];
        target.Focus(FocusState.Keyboard);
        target.Select(target.Text.Length, 0);
    }
}
