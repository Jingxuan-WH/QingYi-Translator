using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Translator.Core;
using Translator.Platform;

namespace Translator.Views;

/// <summary>
/// Switches between Themes/Light.xaml and Themes/Dark.xaml at runtime (every color is a DynamicResource),
/// follows the Windows app theme when set to "system", and keeps native title bars in step.
/// </summary>
internal static class ThemeManager
{
    private static readonly Uri LightPalette = new("pack://application:,,,/Themes/Light.xaml", UriKind.Absolute);
    private static readonly Uri DarkPalette = new("pack://application:,,,/Themes/Dark.xaml", UriKind.Absolute);
    private static readonly ConditionalWeakTable<Window, CaptionStyle> Captions = new();

    private static string _setting = AppSettings.ThemeSystem;
    private static bool _applied;
    private static bool _listening;

    public static bool IsDark { get; private set; }

    /// <summary>Raised after the palette changed, for colors set outside XAML (e.g. the tray menu).</summary>
    public static event Action? Changed;

    /// <summary>"system", "light" or "dark".</summary>
    public static void Apply(string? setting)
    {
        _setting = setting is AppSettings.ThemeLight or AppSettings.ThemeDark ? setting : AppSettings.ThemeSystem;
        if (!_listening)
        {
            _listening = true;
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        }
        SetDark(_setting == AppSettings.ThemeDark || (_setting == AppSettings.ThemeSystem && SystemUsesDarkTheme()));
    }

    /// <summary>
    /// Colors the window's title bar like its content: <paramref name="captionBrushKey"/> is the brush the top of
    /// the window is painted with. Applied when the handle exists and again after every theme change.
    /// </summary>
    public static void Track(Window window, string captionBrushKey, bool hideTitle = false)
    {
        Captions.AddOrUpdate(window, new CaptionStyle(captionBrushKey, hideTitle));
        if (window.IsInitialized && PresentationSource.FromVisual(window) is not null)
            StyleCaption(window);
        else
            window.SourceInitialized += (_, _) => StyleCaption(window);
    }

    public static void Stop()
    {
        if (_listening)
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        _listening = false;
    }

    private static void SetDark(bool dark)
    {
        if (_applied && dark == IsDark)
            return;
        _applied = true;
        IsDark = dark;

        var merged = Application.Current.Resources.MergedDictionaries;
        var palette = new ResourceDictionary { Source = dark ? DarkPalette : LightPalette };
        // The palette is the first merged dictionary (see App.xaml); styles come after it.
        if (merged.Count > 0 && merged[0].Source is { } source && (source.OriginalString.EndsWith("Light.xaml") || source.OriginalString.EndsWith("Dark.xaml")))
            merged[0] = palette;
        else
            merged.Insert(0, palette);

        foreach (Window window in Application.Current.Windows)
            StyleCaption(window);
        Changed?.Invoke();
    }

    private static void StyleCaption(Window window)
    {
        if (!Captions.TryGetValue(window, out var style))
            return;
        var resources = Application.Current.Resources;
        Color caption = resources[style.BrushKey] is SolidColorBrush brush ? brush.Color : Colors.White;
        Color text = resources["TextPrimaryBrush"] is SolidColorBrush textBrush ? textBrush.Color : Colors.Black;
        WindowUtil.StyleCaption(window, caption, text, IsDark, style.HideTitle);
    }

    private static void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        // Switching the Windows theme raises a "General" change (ImmersiveColorSet).
        if (e.Category != UserPreferenceCategory.General)
            return;
        Application.Current?.Dispatcher.BeginInvoke(() =>
        {
            if (_setting == AppSettings.ThemeSystem)
                SetDark(SystemUsesDarkTheme());
        });
    }

    /// <summary>The "Choose your app mode" setting of Windows.</summary>
    public static bool SystemUsesDarkTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        catch (Exception ex)
        {
            Log.Error("读取系统主题失败", ex);
            return false;
        }
    }

    private sealed record CaptionStyle(string BrushKey, bool HideTitle);
}
