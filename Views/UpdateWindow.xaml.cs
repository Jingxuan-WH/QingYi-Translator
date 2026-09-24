using System.ComponentModel;
using System.Text.RegularExpressions;
using System.Windows;
using Translator.Core;
using Translator.Platform;

namespace Translator.Views;

/// <summary>Shows what's new in a release and downloads and installs it on request.</summary>
public partial class UpdateWindow : Window
{
    private readonly ReleaseInfo _release;
    private readonly App _app;
    private CancellationTokenSource? _download;

    internal UpdateWindow(ReleaseInfo release, App app)
    {
        _release = release;
        _app = app;
        InitializeComponent();
        ThemeManager.Track(this, "SurfaceBrush");
        RefreshText();
        Loc.Changed += RefreshText;
        Closed += (_, _) => Loc.Changed -= RefreshText;
        Closing += OnClosing;
    }

    private void RefreshText()
    {
        string version = _release.VersionText;
        string current = UpdateService.CurrentVersionText;
        string date = _release.PublishedAt is { } at ? at.LocalDateTime.ToString("yyyy-MM-dd") : "";
        HeadingText.Text = Loc.T($"轻译 {version} 已发布", $"QingYi Translator {version} is available");
        SubText.Text = date.Length > 0
            ? Loc.T($"当前版本 {current} · 发布于 {date}", $"You have {current} · released {date}")
            : Loc.T($"当前版本 {current}", $"You have {current}");
        NotesText.Text = FormatNotes(_release.Notes);
        LaterButton.Content = _download is null ? Loc.T("以后再说", "Later") : Loc.T("取消", "Cancel");
    }

    /// <summary>Release notes are Markdown; show them as tidy plain text.</summary>
    internal static string FormatNotes(string markdown)
    {
        if (string.IsNullOrWhiteSpace(markdown))
            return Loc.T("（这个版本没有更新说明）", "(No release notes)");
        var lines = new List<string>();
        foreach (string raw in markdown.Replace("\r\n", "\n").Split('\n'))
        {
            string line = raw.TrimEnd();
            string trimmed = line.TrimStart();
            if (trimmed.StartsWith('#'))
                line = trimmed.TrimStart('#').Trim();
            else if (trimmed.StartsWith("- ") || trimmed.StartsWith("* "))
                line = "• " + trimmed[2..];
            line = Regex.Replace(line, @"!?\[([^\]]*)\]\([^)]*\)", "$1"); // links and images → their text
            line = line.Replace("**", "").Replace("__", "").Replace("`", "");
            if (line.Length == 0 && (lines.Count == 0 || lines[^1].Length == 0))
                continue; // no leading or repeated blank lines
            lines.Add(line);
        }
        return string.Join("\n", lines).Trim();
    }

    private async void InstallButton_Click(object sender, RoutedEventArgs e)
    {
        ErrorText.Visibility = Visibility.Collapsed;
        if (!SelfUpdater.CanUpdateInPlace())
        {
            ShowError(Loc.T("无法在当前位置自动更新（程序所在的文件夹不可写入，或者这不是正式发布的版本）。请点“在网页中查看”下载新版本，替换原来的 Translator.exe。",
                "Can’t update automatically here (the program folder isn’t writable, or this isn’t a release build). Click “View on GitHub”, download the new version and replace Translator.exe."));
            return;
        }

        var cts = new CancellationTokenSource();
        _download = cts;
        SetBusy(true);
        var progress = new Progress<double>(fraction =>
        {
            Progress.Value = fraction;
            ProgressText.Text = Loc.T($"正在下载… {fraction:P0}", $"Downloading… {fraction:P0}");
        });
        try
        {
            string path = SelfUpdater.DownloadPath;
            await UpdateService.DownloadAsync(_release, path, progress, cts.Token);
            ProgressText.Text = Loc.T("下载完成，正在重启轻译…", "Downloaded. Restarting…");
            _download = null;
            _app.InstallUpdate(path); // exits the app when it succeeds
        }
        catch (OperationCanceledException) when (cts.IsCancellationRequested)
        {
            SetBusy(false);
        }
        catch (UpdateException ex)
        {
            ShowError(ex.Message);
            SetBusy(false);
        }
        catch (Exception ex)
        {
            Log.Error("安装更新失败", ex);
            ShowError(Loc.T($"更新失败：{ex.Message}", $"Update failed: {ex.Message}"));
            SetBusy(false);
        }
        finally
        {
            if (_download == cts)
                _download = null;
            cts.Dispose();
        }
    }

    private void SetBusy(bool busy)
    {
        ProgressPanel.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        Progress.Value = 0;
        ProgressText.Text = busy ? Loc.T("正在连接…", "Connecting…") : "";
        InstallButton.IsEnabled = !busy;
        SkipButton.IsEnabled = !busy;
        LaterButton.Content = busy ? Loc.T("取消", "Cancel") : Loc.T("以后再说", "Later");
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }

    // IsCancel closes the dialog after this; during a download OnClosing keeps it open and only the download stops.
    private void LaterButton_Click(object sender, RoutedEventArgs e) => _download?.Cancel();

    private void SkipButton_Click(object sender, RoutedEventArgs e)
    {
        _app.SkipUpdate(_release);
        Close();
    }

    private void PageButton_Click(object sender, RoutedEventArgs e) => App.OpenUrl(_release.PageUrl);

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        // Closing during a download (Esc, Cancel or the X button) stops the download first.
        if (_download is { } download && !_app.IsExiting)
        {
            download.Cancel();
            e.Cancel = true;
        }
    }
}
