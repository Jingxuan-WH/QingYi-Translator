using System.Windows;
using Translator.Core;

namespace Translator.Views;

/// <summary>A small themed replacement for MessageBox, which ignores dark mode.</summary>
public partial class MessageDialog : Window
{
    private MessageDialog(Window? owner, string heading, string message, string primary, string? secondary, bool danger)
    {
        InitializeComponent();
        Title = Loc.T("轻译", "QingYi Translator");
        HeadingText.Text = heading;
        MessageText.Text = message;
        MessageText.Visibility = message.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        PrimaryButton.Content = primary;
        if (danger)
            PrimaryButton.Style = (Style)FindResource("DangerButton");
        if (secondary is null)
            SecondaryButton.Visibility = Visibility.Collapsed;
        else
            SecondaryButton.Content = secondary;

        if (owner is { IsVisible: true })
            Owner = owner;
        else
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ThemeManager.Track(this, "SurfaceBrush");
    }

    /// <summary>Asks a yes/no question; true when the primary button was clicked.</summary>
    public static bool Confirm(Window? owner, string heading, string message, string confirmText, bool danger = false) =>
        new MessageDialog(owner, heading, message, confirmText, Loc.T("取消", "Cancel"), danger).ShowDialog() == true;

    public static void Inform(Window? owner, string heading, string message) =>
        new MessageDialog(owner, heading, message, Loc.T("确定", "OK"), null, danger: false).ShowDialog();

    private void PrimaryButton_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
