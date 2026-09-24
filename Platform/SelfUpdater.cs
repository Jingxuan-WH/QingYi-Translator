using System.Diagnostics;
using System.IO;
using Translator.Core;

namespace Translator.Platform;

/// <summary>
/// Replaces the running single-file exe with a downloaded version. Windows won't let a running exe be overwritten,
/// but it can be renamed: the old file becomes Translator.exe.old and the new one takes its name.
/// </summary>
internal static class SelfUpdater
{
    private static string ExePath => Environment.ProcessPath ?? throw new InvalidOperationException("No process path");

    public static string DownloadPath => ExePath + ".download";

    private static string BackupPath => ExePath + ".old";

    /// <summary>
    /// True for the published single-file build in a writable folder. Development builds (exe + dll)
    /// and read-only locations fall back to the download page.
    /// </summary>
    public static bool CanUpdateInPlace()
    {
        // Location is empty exactly when running from a single-file bundle, which is what this checks.
#pragma warning disable IL3000
        if (!string.IsNullOrEmpty(typeof(SelfUpdater).Assembly.Location))
            return false; // not a single-file bundle: replacing the exe alone would not update the program
#pragma warning restore IL3000
        try
        {
            string probe = Path.Combine(Path.GetDirectoryName(ExePath)!, $".qingyi-update-test-{Environment.ProcessId}");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>Swaps <paramref name="downloaded"/> in and starts it. The caller must exit right after.</summary>
    public static void Install(string downloaded, bool showWindow)
    {
        string exe = ExePath;
        // Sync tools and virus scanners often hold new files for a moment, hence the retries.
        Retry(() =>
        {
            if (File.Exists(BackupPath))
                File.Delete(BackupPath);
        });
        Retry(() => File.Move(exe, BackupPath));
        try
        {
            Retry(() => File.Move(downloaded, exe));
        }
        catch
        {
            TryRun(() => File.Move(BackupPath, exe));
            throw;
        }

        // The new copy waits for this process to exit before taking over the hotkeys and the tray.
        string arguments = $"--updated --wait-pid {Environment.ProcessId}" + (showWindow ? "" : " --minimized");
        try
        {
            Process.Start(new ProcessStartInfo(exe, arguments) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! })?.Dispose();
        }
        catch
        {
            TryRun(() => File.Move(exe, downloaded, overwrite: true));
            TryRun(() => File.Move(BackupPath, exe));
            throw;
        }
        Log.Info($"已安装更新，正在重启：{exe}");
    }

    /// <summary>Deletes what an earlier update left behind. The old process may still be closing, so this keeps trying for a while.</summary>
    public static void CleanUpInBackground()
    {
        string[] leftovers;
        try
        {
            leftovers = [BackupPath, DownloadPath];
        }
        catch (InvalidOperationException)
        {
            return;
        }
        if (!leftovers.Any(File.Exists))
            return;
        Task.Run(async () =>
        {
            for (int attempt = 0; attempt < 30 && leftovers.Any(File.Exists); attempt++)
            {
                foreach (string path in leftovers)
                    TryRun(() => File.Delete(path));
                await Task.Delay(1000);
            }
        });
    }

    private static void Retry(Action action)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException && attempt < 15)
            {
                Thread.Sleep(200);
            }
        }
    }

    private static void TryRun(Action action)
    {
        try
        {
            action();
        }
        catch (Exception ex)
        {
            Log.Error("更新时清理文件失败", ex);
        }
    }
}
