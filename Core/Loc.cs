using System.ComponentModel;
using System.Globalization;

namespace Translator.Core;

/// <summary>A text in both interface languages; converts to the one currently shown.</summary>
public readonly record struct LocText(string Zh, string En)
{
    public static implicit operator LocText(string same) => new(same, same);

    public static implicit operator string(LocText text) => text.ToString();

    public override string ToString() => (Loc.IsEnglish ? En : Zh) ?? "";
}

/// <summary>
/// The interface language (Chinese or English). XAML binds to <see cref="English"/> through the T markup extension,
/// so switching updates every open window at once; text set from code listens to <see cref="Changed"/>.
/// </summary>
public sealed class Loc : INotifyPropertyChanged
{
    public const string SystemCode = "system";
    public const string ChineseCode = "zh";
    public const string EnglishCode = "en";

    public static Loc Instance { get; } = new();

    public static bool IsEnglish { get; private set; }

    /// <summary>Raised after the language changed.</summary>
    public static event Action? Changed;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Binding source for XAML.</summary>
    public bool English => IsEnglish;

    public static string T(string zh, string en) => IsEnglish ? en : zh;

    /// <summary>Settings value → language: "zh", "en", or anything else to follow the Windows display language.</summary>
    public static bool ResolvesToEnglish(string? setting) => setting switch
    {
        EnglishCode => true,
        ChineseCode => false,
        _ => !CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase),
    };

    public static void Apply(string? setting)
    {
        bool english = ResolvesToEnglish(setting);
        if (english == IsEnglish)
            return;
        IsEnglish = english;
        Instance.PropertyChanged?.Invoke(Instance, new PropertyChangedEventArgs(nameof(English)));
        Changed?.Invoke();
    }
}
