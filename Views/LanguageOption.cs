using System.ComponentModel;
using Translator.Core;

namespace Translator.Views;

/// <summary>An entry of a language drop-down. The "detect" entry renames itself to show the detected language.</summary>
public sealed class LanguageOption(Lang lang, string displayName) : INotifyPropertyChanged
{
    private string _displayName = displayName;

    public Lang Lang { get; } = lang;

    public string DisplayName
    {
        get => _displayName;
        set
        {
            if (_displayName == value)
                return;
            _displayName = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DisplayName)));
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public override string ToString() => DisplayName;
}

public sealed record ProviderOption(string Id, string DisplayName);
