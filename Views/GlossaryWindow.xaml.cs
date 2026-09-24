using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using Translator.Core;

namespace Translator.Views;

/// <summary>One editable line of the glossary.</summary>
public sealed class GlossaryRow(string source = "", string target = "") : INotifyPropertyChanged
{
    private string _source = source;
    private string _target = target;
    private bool _flagged;

    public string Source
    {
        get => _source;
        set => Set(ref _source, value ?? "");
    }

    public string Target
    {
        get => _target;
        set => Set(ref _target, value ?? "");
    }

    /// <summary>Marked after a save attempt when only one side is filled in.</summary>
    public bool Flagged
    {
        get => _flagged;
        set
        {
            if (_flagged == value)
                return;
            _flagged = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Flagged)));
        }
    }

    public bool IsBlank => Source.Trim().Length == 0 && Target.Trim().Length == 0;

    public bool IsComplete => Source.Trim().Length > 0 && Target.Trim().Length > 0;

    public bool IsIncomplete => !IsBlank && !IsComplete;

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Set(ref string field, string value, [System.Runtime.CompilerServices.CallerMemberName] string name = "")
    {
        if (field == value)
            return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsBlank)));
        Flagged = false;
    }
}

public partial class GlossaryWindow : Window
{
    private readonly ObservableCollection<GlossaryRow> _rows = [];
    private readonly ICollectionView _view;
    private Func<string>? _message;
    private bool _showingIncompleteWarning;

    public GlossaryWindow(Glossary glossary, bool enabled)
    {
        InitializeComponent();
        foreach (var entry in glossary.Entries)
            AddRow(new GlossaryRow(entry.Source, entry.Target));
        EnsureBlankRowAtEnd();
        EnabledToggle.IsChecked = enabled;

        _view = CollectionViewSource.GetDefaultView(_rows);
        _view.Filter = MatchesSearch;
        RowsList.ItemsSource = _view;
        _rows.CollectionChanged += (_, _) => UpdateCount();
        UpdateCount();

        ThemeManager.Track(this, "WindowBrush");
        Loc.Changed += OnInterfaceLanguageChanged;
        Closed += (_, _) => Loc.Changed -= OnInterfaceLanguageChanged;
        Loaded += (_, _) => FocusRow(_rows[^1], target: false);
    }

    /// <summary>The entries to save, once the dialog returned true.</summary>
    public IReadOnlyList<GlossaryEntry> Entries { get; private set; } = [];

    public bool GlossaryEnabled => EnabledToggle.IsChecked == true;

    private void AddRow(GlossaryRow row, int index = -1)
    {
        row.PropertyChanged += OnRowChanged;
        if (index < 0)
            _rows.Add(row);
        else
            _rows.Insert(index, row);
    }

    private void OnRowChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(GlossaryRow.Source) or nameof(GlossaryRow.Target))
        {
            EnsureBlankRowAtEnd();
            UpdateCount();
            if (_showingIncompleteWarning && !_rows.Any(row => row.Flagged))
                SetMessage(null);
        }
    }

    /// <summary>There is always one empty line at the bottom to type a new term into.</summary>
    private void EnsureBlankRowAtEnd()
    {
        if (_rows.Count == 0 || !_rows[^1].IsBlank)
            AddRow(new GlossaryRow());
    }

    private void UpdateCount()
    {
        int count = _rows.Count(row => row.IsComplete);
        CountText.Text = Loc.T($"共 {count} 条", count == 1 ? "1 term" : $"{count} terms");
    }

    private void SetMessage(Func<string>? message, string brushKey = "TextSecondaryBrush")
    {
        _message = message;
        _showingIncompleteWarning = false;
        MessageText.Text = message?.Invoke() ?? "";
        MessageText.SetResourceReference(TextBlock.ForegroundProperty, brushKey);
    }

    private void OnInterfaceLanguageChanged()
    {
        UpdateCount();
        MessageText.Text = _message?.Invoke() ?? "";
    }

    // ---------------- search ----------------

    private bool MatchesSearch(object item)
    {
        string query = SearchBox.Text.Trim();
        return query.Length == 0 || item is not GlossaryRow row || row.IsBlank
            || row.Source.Contains(query, StringComparison.OrdinalIgnoreCase)
            || row.Target.Contains(query, StringComparison.OrdinalIgnoreCase);
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        SearchPlaceholder.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        _view.Refresh();
    }

    // ---------------- editing ----------------

    private void DeleteRow_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: GlossaryRow row })
        {
            row.PropertyChanged -= OnRowChanged;
            _rows.Remove(row);
            EnsureBlankRowAtEnd();
            if (_showingIncompleteWarning && !_rows.Any(other => other.Flagged))
                SetMessage(null);
        }
    }

    /// <summary>Enter moves to the next line (like a spreadsheet); on the last line it starts a new term.</summary>
    private void Cell_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || sender is not TextBox { DataContext: GlossaryRow row } box)
            return;
        e.Handled = true;
        bool target = box.Name == "TargetCell";
        int index = _rows.IndexOf(row);
        EnsureBlankRowAtEnd();
        if (index >= 0 && index + 1 < _rows.Count)
            FocusRow(_rows[index + 1], target: target && !_rows[index + 1].IsBlank);
    }

    private void FocusRow(GlossaryRow row, bool target)
    {
        int index = _view.Cast<object>().ToList().IndexOf(row);
        if (index < 0)
            return;
        RowsList.UpdateLayout();
        if (RowsList.ItemContainerGenerator.ContainerFromIndex(index) is not FrameworkElement container)
        {
            // Virtualized away: scroll it into existence first.
            FindChild<VirtualizingStackPanel>(RowsList)?.BringIndexIntoViewPublic(index);
            RowsList.UpdateLayout();
            if (RowsList.ItemContainerGenerator.ContainerFromIndex(index) is not FrameworkElement generated)
                return;
            container = generated;
        }
        container.BringIntoView();
        if (container is ContentPresenter presenter && presenter.ContentTemplate?.FindName(target ? "TargetCell" : "SourceCell", presenter) is TextBox box)
        {
            box.Focus();
            box.CaretIndex = box.Text.Length;
        }
    }

    private static T? FindChild<T>(DependencyObject parent) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T match)
                return match;
            if (FindChild<T>(child) is { } nested)
                return nested;
        }
        return null;
    }

    /// <summary>Pasting several lines (or two cells copied from Excel) adds one term per line.</summary>
    private void Rows_Pasting(object sender, DataObjectPastingEventArgs e)
    {
        if (e.SourceDataObject.GetData(DataFormats.UnicodeText, true) is not string text || text.IndexOfAny(['\n', '\t']) < 0)
            return;
        var entries = Glossary.Parse(text);
        if (entries.Count == 0)
            return;
        e.CancelCommand();

        var row = (e.OriginalSource as FrameworkElement)?.DataContext as GlossaryRow;
        int index = row is null ? _rows.Count - 1 : _rows.IndexOf(row);
        if (row is { IsBlank: true })
        {
            row.PropertyChanged -= OnRowChanged;
            _rows.RemoveAt(index);
        }
        else
        {
            index++;
        }
        foreach (var entry in entries)
            AddRow(new GlossaryRow(entry.Source, entry.Target), index++);
        EnsureBlankRowAtEnd();
        int count = entries.Count;
        SetMessage(() => Loc.T($"已粘贴 {count} 条术语", count == 1 ? "Pasted 1 term" : $"Pasted {count} terms"));
    }

    // ---------------- import / export ----------------

    private void ImportButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = Loc.T("导入术语表", "Import glossary"),
            Filter = Loc.T("术语表文件 (*.csv;*.tsv;*.txt)|*.csv;*.tsv;*.txt|所有文件 (*.*)|*.*",
                "Glossary files (*.csv;*.tsv;*.txt)|*.csv;*.tsv;*.txt|All files (*.*)|*.*"),
        };
        if (dialog.ShowDialog(this) != true)
            return;
        try
        {
            var entries = Glossary.ReadFile(dialog.FileName);
            if (entries.Count == 0)
            {
                SetMessage(() => Loc.T("文件里没有找到术语。每行一条，两列用逗号、Tab 或 = 分开。",
                    "No terms found. Put one term per line, with the two columns separated by a comma, tab or =."), "ErrorBrush");
                return;
            }
            // Replace the trailing blank line, then keep one at the end.
            var blank = _rows[^1];
            blank.PropertyChanged -= OnRowChanged;
            _rows.Remove(blank);
            foreach (var entry in entries)
                AddRow(new GlossaryRow(entry.Source, entry.Target));
            EnsureBlankRowAtEnd();
            int count = entries.Count;
            SetMessage(() => Loc.T($"已导入 {count} 条术语，保存后生效", count == 1 ? "Imported 1 term. Save to apply" : $"Imported {count} terms. Save to apply"));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            SetMessage(() => Loc.T($"无法读取文件：{ex.Message}", $"Could not read the file: {ex.Message}"), "ErrorBrush");
        }
    }

    private void ExportButton_Click(object sender, RoutedEventArgs e)
    {
        var entries = Glossary.Clean(_rows.Select(row => new GlossaryEntry { Source = row.Source, Target = row.Target }));
        if (entries.Count == 0)
        {
            SetMessage(() => Loc.T("还没有可以导出的术语", "There are no terms to export yet"), "ErrorBrush");
            return;
        }
        var dialog = new SaveFileDialog
        {
            Title = Loc.T("导出术语表", "Export glossary"),
            FileName = Loc.T("术语表.csv", "glossary.csv"),
            Filter = Loc.T("CSV 文件 (*.csv)|*.csv", "CSV files (*.csv)|*.csv"),
        };
        if (dialog.ShowDialog(this) != true)
            return;
        try
        {
            Glossary.WriteCsv(dialog.FileName, entries);
            int count = entries.Count;
            SetMessage(() => Loc.T($"已导出 {count} 条术语", count == 1 ? "Exported 1 term" : $"Exported {count} terms"), "SuccessBrush");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            SetMessage(() => Loc.T($"无法保存文件：{ex.Message}", $"Could not save the file: {ex.Message}"), "ErrorBrush");
        }
    }

    // ---------------- save ----------------

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        var incomplete = _rows.Where(row => row.IsIncomplete).ToList();
        if (incomplete.Count > 0)
        {
            foreach (var row in incomplete)
                row.Flagged = true;
            SearchBox.Clear();
            int count = incomplete.Count;
            SetMessage(() => Loc.T($"有 {count} 条术语只填了一边，请补全或删除", count == 1 ? "1 term is missing one side. Complete or delete it" : $"{count} terms are missing one side. Complete or delete them"), "ErrorBrush");
            _showingIncompleteWarning = true;
            FocusRow(incomplete[0], target: incomplete[0].Source.Trim().Length > 0);
            return;
        }
        Entries = Glossary.Clean(_rows.Select(row => new GlossaryEntry { Source = row.Source, Target = row.Target }));
        DialogResult = true;
    }
}
