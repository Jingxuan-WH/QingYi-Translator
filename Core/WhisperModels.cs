using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace Translator.Core;

/// <summary>A Whisper model in whisper.cpp's ggml format.</summary>
/// <param name="Sha1">Checksum published in whisper.cpp's models/README.md.</param>
public sealed record WhisperModelInfo(string Id, string FileName, string DisplayName, int Megabytes, string Sha1, LocText Speed);

/// <summary>Where models are downloaded from: Hugging Face itself or a mirror reachable from mainland China.</summary>
public sealed record ModelSource(string Id, LocText Name, string BaseUrl);

public sealed record DownloadProgress(long Received, long Total, bool Verifying = false)
{
    public double Fraction => Total > 0 ? Math.Min(1.0, (double)Received / Total) : 0;
}

public sealed class DownloadException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// The speech models the Windows version offers. They are too big to ship inside Translator.exe, so each is
/// downloaded on first use into %LOCALAPPDATA%\QingYiTranslator\models, resuming an interrupted download, and only
/// used once its SHA-1 matches the published checksum.
/// </summary>
public static class WhisperModels
{
    public const string DefaultId = "small";
    public const string HuggingFaceId = "huggingface";
    public const string MirrorId = "hf-mirror";

    public static IReadOnlyList<WhisperModelInfo> All { get; } =
    [
        new("base", "ggml-base.bin", "base", 142, "465707469ff3a37a2b9b8d8f89f2f99de7299dac",
            new("最快，CPU 也能实时；准确度一般", "Fastest, real time even on a CPU; fair accuracy")),
        new("small", "ggml-small.bin", "small", 466, "55356645c2b361a969dfd0ef2c5a50d530afd8d5",
            new("速度和准确度均衡（推荐）", "Balanced speed and accuracy (recommended)")),
        new("large-v3-turbo-q5_0", "ggml-large-v3-turbo-q5_0.bin", "large-v3-turbo（q5_0 量化）", 547, "e050f7970618a659205450ad97eb95a18d69c9ee",
            new("最准确；建议有独立显卡时使用", "Most accurate; best with a dedicated GPU")),
    ];

    public static IReadOnlyList<ModelSource> Sources { get; } =
    [
        new(HuggingFaceId, new("Hugging Face", "Hugging Face"), "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"),
        new(MirrorId, new("hf-mirror.com（国内镜像）", "hf-mirror.com (mirror in China)"), "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/"),
    ];

    private static readonly HttpClient Http = CreateHttpClient();

    public static WhisperModelInfo Find(string? id) => All.FirstOrDefault(model => model.Id == id) ?? All.First(model => model.Id == DefaultId);

    /// <summary>"" (automatic) uses the mirror on a Chinese system and Hugging Face elsewhere.</summary>
    public static ModelSource ResolveSource(string? setting) =>
        Sources.FirstOrDefault(source => source.Id == setting)
        ?? Sources.First(source => source.Id == (CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? MirrorId : HuggingFaceId));

    public static Uri DownloadUrl(WhisperModelInfo model, ModelSource source) => new(source.BaseUrl + model.FileName);

    /// <summary>%LOCALAPPDATA%\QingYiTranslator\models, or a "models" folder in TRANSLATOR_DATA_DIR when that is set.</summary>
    public static string Directory { get; } = AppSettings.UsesCustomDataDirectory
        ? Path.Combine(AppSettings.DataDirectory, "models")
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "QingYiTranslator", "models");

    public static string PathFor(WhisperModelInfo model) => Path.Combine(Directory, model.FileName);

    /// <summary>True when the model file is present and was verified (see <see cref="VerifyAsync"/>).</summary>
    public static bool IsDownloaded(WhisperModelInfo model) => IsMarkedVerified(PathFor(model), model.Sha1);

    /// <summary>
    /// Checks a model that is on disk but not yet marked as verified (e.g. copied there by hand). A file that fails
    /// the check is deleted so the next download starts clean.
    /// </summary>
    public static async Task<bool> VerifyAsync(WhisperModelInfo model, CancellationToken ct)
    {
        string path = PathFor(model);
        if (IsMarkedVerified(path, model.Sha1))
            return true;
        if (!File.Exists(path))
            return false;
        if (await Task.Run(() => HashMatches(path, model.Sha1, ct), ct))
        {
            MarkVerified(path, model.Sha1);
            return true;
        }
        Log.Info($"模型文件校验失败，已删除：{path}");
        TryDelete(path);
        return false;
    }

    public static async Task DownloadAsync(WhisperModelInfo model, ModelSource source, IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        string path = PathFor(model);
        await DownloadFileAsync(DownloadUrl(model, source), path, file => HashMatches(file, model.Sha1, ct), progress, ct);
        MarkVerified(path, model.Sha1);
        Log.Info($"已下载语音模型 {model.Id}（{source.Id}）");
    }

    public static void Delete(WhisperModelInfo model)
    {
        string path = PathFor(model);
        TryDelete(path);
        TryDelete(path + ".part");
        TryDelete(MarkerPath(path));
    }

    // ---------------- downloading ----------------

    /// <summary>
    /// Downloads <paramref name="url"/> to <paramref name="path"/> through "path.part", resuming a partial file left by
    /// an interrupted attempt. The file only takes its final name once <paramref name="verify"/> accepts it.
    /// </summary>
    public static async Task DownloadFileAsync(Uri url, string path, Func<string, bool> verify, IProgress<DownloadProgress>? progress,
        CancellationToken ct)
    {
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string part = path + ".part";
        long existing = File.Exists(part) ? new FileInfo(part).Length : 0;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            if (existing > 0)
                request.Headers.Range = new RangeHeaderValue(existing, null);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            bool complete = existing > 0 && response.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable;
            if (!complete)
            {
                if (!response.IsSuccessStatusCode)
                    throw new DownloadException(Loc.T($"下载失败（HTTP {(int)response.StatusCode}），可以换一个下载源重试。",
                        $"Download failed (HTTP {(int)response.StatusCode}). Try again, or pick another download source."));
                bool append = existing > 0 && response.StatusCode == HttpStatusCode.PartialContent;
                if (!append)
                    existing = 0;
                long total = existing + (response.Content.Headers.ContentLength ?? 0);

                await using var source = await response.Content.ReadAsStreamAsync(timeout.Token);
                await using var file = new FileStream(part, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true);
                byte[] buffer = new byte[1 << 16];
                long received = existing;
                long lastReport = 0;
                while (true)
                {
                    timeout.CancelAfter(TimeSpan.FromSeconds(30)); // between two reads
                    int read = await source.ReadAsync(buffer, timeout.Token);
                    if (read == 0)
                        break;
                    await file.WriteAsync(buffer.AsMemory(0, read), timeout.Token);
                    received += read;
                    if (Environment.TickCount64 - lastReport > 150)
                    {
                        lastReport = Environment.TickCount64;
                        progress?.Report(new DownloadProgress(received, total));
                    }
                }
                if (total > existing && received < total)
                    throw new DownloadException(Loc.T("下载中断，请重试（会从断点继续）。", "The download was interrupted. Try again; it resumes where it stopped."));
                progress?.Report(new DownloadProgress(received, Math.Max(total, received), Verifying: true));
            }
        }
        catch (DownloadException)
        {
            throw;
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException || (ex is OperationCanceledException && !ct.IsCancellationRequested))
        {
            throw new DownloadException(Loc.T("网络连接中断，请检查网络后重试（会从断点继续），或换一个下载源。",
                "The connection was lost. Check your network and try again (it resumes), or pick another download source."), ex);
        }

        timeout.CancelAfter(Timeout.InfiniteTimeSpan);
        if (!await Task.Run(() => verify(part), ct))
        {
            TryDelete(part);
            throw new DownloadException(Loc.T("下载的文件校验失败，已删除，请重试。", "The downloaded file failed verification and was deleted. Please try again."));
        }
        File.Move(part, path, overwrite: true);
    }

    // ---------------- verification ----------------

    public static bool HashMatches(string path, string expectedSha1, CancellationToken ct = default)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
        using var sha1 = IncrementalHash.CreateHash(HashAlgorithmName.SHA1);
        byte[] buffer = new byte[1 << 20];
        int read;
        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
        {
            ct.ThrowIfCancellationRequested();
            sha1.AppendData(buffer, 0, read);
        }
        return Convert.ToHexString(sha1.GetHashAndReset()).Equals(expectedSha1, StringComparison.OrdinalIgnoreCase);
    }

    // Hashing a 500 MB model takes a few seconds, so a verified file is remembered by its checksum, size and time.
    internal static bool IsMarkedVerified(string path, string sha1)
    {
        try
        {
            return File.Exists(path) && File.Exists(MarkerPath(path)) && File.ReadAllText(MarkerPath(path)) == MarkerText(path, sha1);
        }
        catch (IOException)
        {
            return false;
        }
    }

    internal static void MarkVerified(string path, string sha1)
    {
        try
        {
            File.WriteAllText(MarkerPath(path), MarkerText(path, sha1));
        }
        catch (Exception ex)
        {
            Log.Error("无法记录模型校验结果", ex);
        }
    }

    private static string MarkerPath(string path) => path + ".verified";

    private static string MarkerText(string path, string sha1)
    {
        var info = new FileInfo(path);
        return $"{sha1.ToLowerInvariant()}|{info.Length}|{info.LastWriteTimeUtc.Ticks}";
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Error($"无法删除文件：{path}", ex);
        }
    }

    private static HttpClient CreateHttpClient()
    {
        var handler = new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(15),
            AllowAutoRedirect = true, // Hugging Face answers with a redirect to its file servers
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        };
        var http = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"QingYiTranslator/{UpdateService.CurrentVersionText}");
        return http;
    }
}
