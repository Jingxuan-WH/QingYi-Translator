using System.ComponentModel;
using Translator.Core;

namespace Translator.Views;

/// <summary>An entry of a language drop-down. The "detect" entry (null language) renames itself to show what it detected.</summary>
public sealed class LanguageOption(Language? language, string displayName) : INotifyPropertyChanged
{
    private string _displayName = displayName;

    public LanguageOption(Language language) : this(language, language.LocalName)
    {
    }

    public Language? Language { get; } = language;

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

/// <summary>A drop-down entry with a stored value and a label in both interface languages.</summary>
public sealed class ChoiceOption(string id, LocText label) : INotifyPropertyChanged
{
    public string Id { get; } = id;

    public string DisplayName => label;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Call after the interface language changed.</summary>
    public void Refresh() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DisplayName)));

    public override string ToString() => DisplayName;
}
