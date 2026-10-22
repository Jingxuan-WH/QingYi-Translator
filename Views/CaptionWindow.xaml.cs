using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using Translator.Core;
using Translator.Platform;

namespace Translator.Views;

/// <summary>
/// A translucent always-on-top bar with the last sentence or two and their translations, for watching a video or a
/// meeting in another window. Drag it anywhere; the buttons appear on hover.
/// </summary>
public partial class CaptionWindow : Window
{
    private readonly AppSettings _settings;

    public event Action? CloseRequested;

    internal CaptionWindow(AppSettings settings)
    {
        _settings = settings;
        InitializeComponent();
        ApplyFontSize();
        MouseEnter += (_, _) => Tools.Opacity = 1;
        MouseLeave += (_, _) => Tools.Opacity = 0;
        SourceInitialized += (_, _) =>
        {
            if (settings.Live.CaptionBounds is not { } saved || !WindowUtil.TryRestorePlacement(this, saved))
                PlaceAtBottom();
            SizeToContent = SizeToContent.Height; // the restored placement includes an old height
        };
        Closing += OnClosing;
    }

    /// <summary>Shows <paramref name="previous"/> above <paramref name="current"/>; either may be null.</summary>
    internal void ShowLines(TranscriptLine? previous, TranscriptLine? current)
    {
        Set(PreviousSource, previous?.Text);
        Set(PreviousTranslation, previous?.Translation);
        Set(CurrentSource, current?.Text);
        Set(CurrentTranslation, current?.Translation);
        PreviousTranslation.Margin = new Thickness(0, 2, 0, current is null ? 0 : 8);
        if (!IsVisible)
            Show();
    }

    private static void Set(System.Windows.Controls.TextBlock block, string? text)
    {
        block.Text = text ?? "";
        block.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ApplyFontSize()
    {
        double size = _settings.Live.CaptionFontSize;
        PreviousSource.FontSize = size * 0.7;
        PreviousTranslation.FontSize = size * 0.8;
        CurrentSource.FontSize = size * 0.8;
        CurrentTranslation.FontSize = size;
    }

    private void ChangeFontSize(double delta)
    {
        _settings.Live.CaptionFontSize = Math.Clamp(_settings.Live.CaptionFontSize + delta, LiveSettings.MinCaptionFontSize, LiveSettings.MaxCaptionFontSize);
        _settings.Save();
        ApplyFontSize();
    }

    private void LargerButton_Click(object sender, RoutedEventArgs e) => ChangeFontSize(2);

    private void SmallerButton_Click(object sender, RoutedEventArgs e) => ChangeFontSize(-2);

    private void CloseButton_Click(object sender, RoutedEventArgs e) => CloseRequested?.Invoke();

    private void Panel_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed)
            return;
        DragMove();
        SaveBounds();
    }

    private void SaveBounds()
    {
        if (WindowUtil.GetPlacement(this) is { } bounds)
        {
            _settings.Live.CaptionBounds = bounds;
            _settings.Save();
        }
    }

    // Default spot: centered near the bottom of the primary screen, above the taskbar.
    private void PlaceAtBottom()
    {
        Rect area = SystemParameters.WorkArea;
        Width = Math.Min(Width, area.Width - 80);
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Bottom - 220;
    }

    private void OnClosing(object? sender, CancelEventArgs e) => SaveBounds();

    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
    {
        base.OnRenderSizeChanged(sizeInfo);
        // Grows upwards when a longer sentence needs another line, so the bar stays where it was put.
        if (sizeInfo.HeightChanged && sizeInfo.PreviousSize.Height > 0)
            Top -= sizeInfo.NewSize.Height - sizeInfo.PreviousSize.Height;
    }
}
