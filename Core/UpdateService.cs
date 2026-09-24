using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;

namespace Translator.Core;

/// <summary>A version published on GitHub Releases.</summary>
/// <param name="Sha256">Hex digest GitHub reports for the asset; null for assets uploaded before GitHub added digests.</param>
public sealed record ReleaseInfo(Version Version, string Tag, string Notes, string PageUrl, string DownloadUrl, long Size,
    string? Sha256, DateTimeOffset? PublishedAt)
{
    public string VersionText => Version.ToString(3);
}

public sealed class UpdateException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>Checks GitHub Releases for a newer version and downloads it.</summary>
public static class UpdateService
{
    public const string Repository = "Jingxuan-WH/QingYi-Translator";
    public const string AssetName = "Translator.exe";

    public static string ReleasesPage { get; } = $"https://github.com/{Repository}/releases/latest";

    // TRANSLATOR_UPDATE_URL points the check at a local test server; downloads are then allowed from that server only.
    private static readonly string? TestApiUrl =
        Environment.GetEnvironmentVariable("TRANSLATOR_UPDATE_URL") is { Length: > 0 } url ? url : null;

    // Must stay above Http: static initializers run in textual order and the client's User-Agent needs the version.
    public static Version CurrentVersion { get; } = Normalize(Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0));

    private static readonly HttpClient Http = CreateHttpClient();

    public static string CurrentVersionText => CurrentVersion.ToString(3);

    private static string ApiUrl => TestApiUrl ?? $"https://api.github.com/repos/{Repository}/releases/latest";

    /// <summary>The latest release, or null when none has a Windows build. Throws <see cref="UpdateException"/> on failure.</summary>
    public static async Task<ReleaseInfo?> GetLatestAsync(CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, ApiUrl);
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
            using var response = await Http.SendAsync(request, timeout.Token);
            if (response.StatusCode == HttpStatusCode.NotFound)
                return null; // nothing published yet
            if (response.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests)
                throw new UpdateException(Loc.T("GitHub 访问次数过多，请过一会儿再试。", "Too many requests to GitHub. Please try again later."));
            if (!response.IsSuccessStatusCode)
                throw new UpdateException(Loc.T($"GitHub 返回错误（HTTP {(int)response.StatusCode}）。", $"GitHub returned an error (HTTP {(int)response.StatusCode})."));
            return ParseRelease(await response.Content.ReadAsStringAsync(timeout.Token));
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException || (ex is OperationCanceledException && !ct.IsCancellationRequested))
        {
            throw new UpdateException(Loc.T("无法连接到 GitHub，请检查网络后重试。", "Could not reach GitHub. Please check your network and try again."), ex);
        }
        catch (JsonException ex)
        {
            throw new UpdateException(Loc.T("无法读取版本信息。", "Could not read the release information."), ex);
        }
    }

    /// <summary>Reads a GitHub "release" object. Drafts, pre-releases and releases without Translator.exe are ignored.</summary>
    public static ReleaseInfo? ParseRelease(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object || IsTrue(root, "draft") || IsTrue(root, "prerelease"))
            return null;
        string tag = GetString(root, "tag_name") ?? "";
        if (!TryParseVersion(tag, out var version))
            return null;

        string? downloadUrl = null, sha256 = null;
        long size = 0;
        if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
        {
            foreach (var asset in assets.EnumerateArray())
            {
                if (!string.Equals(GetString(asset, "name"), AssetName, StringComparison.OrdinalIgnoreCase))
                    continue;
                downloadUrl = GetString(asset, "browser_download_url");
                if (asset.TryGetProperty("size", out var s) && s.ValueKind == JsonValueKind.Number)
                    size = s.GetInt64();
                if (GetString(asset, "digest") is { } digest && digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
                    sha256 = digest["sha256:".Length..];
                break;
            }
        }
        if (downloadUrl is null || !IsTrustedDownload(downloadUrl))
            return null;

        DateTimeOffset? published = GetString(root, "published_at") is { } at
            && DateTimeOffset.TryParse(at, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed) ? parsed : null;
        return new ReleaseInfo(version, tag, (GetString(root, "body") ?? "").Trim(), GetString(root, "html_url") ?? ReleasesPage,
            downloadUrl, size, sha256, published);
    }

    public static bool TryParseVersion(string? tag, out Version version)
    {
        version = new Version(0, 0, 0);
        if (string.IsNullOrWhiteSpace(tag))
            return false;
        string text = tag.Trim().TrimStart('v', 'V');
        int suffix = text.IndexOfAny(['-', '+', ' ']);
        if (suffix >= 0)
            text = text[..suffix];
        if (Version.TryParse(text, out var parsed))
        {
            version = Normalize(parsed);
            return true;
        }
        if (int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out int major))
        {
            version = new Version(major, 0, 0);
            return true;
        }
        return false;
    }

    public static bool IsNewer(ReleaseInfo release) => release.Version > CurrentVersion;

    /// <summary>Downloads the release to <paramref name="path"/>, checking its size, file type and SHA-256 digest.</summary>
    public static async Task DownloadAsync(ReleaseInfo release, string path, IProgress<double>? progress, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromMinutes(5));
        try
        {
            using var response = await Http.GetAsync(release.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (!response.IsSuccessStatusCode)
                throw new UpdateException(Loc.T($"下载失败（HTTP {(int)response.StatusCode}）。", $"Download failed (HTTP {(int)response.StatusCode})."));
            long total = response.Content.Headers.ContentLength ?? release.Size;

            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long received = 0;
            byte[] head = new byte[2];
            await using (var source = await response.Content.ReadAsStreamAsync(timeout.Token))
            await using (var file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 81920, useAsync: true))
            {
                byte[] buffer = new byte[81920];
                int read;
                while ((read = await source.ReadAsync(buffer, timeout.Token)) > 0)
                {
                    if (received < 2)
                        Array.Copy(buffer, 0, head, (int)received, (int)Math.Min(2 - received, read));
                    await file.WriteAsync(buffer.AsMemory(0, read), timeout.Token);
                    hash.AppendData(buffer, 0, read);
                    received += read;
                    if (total > 0)
                        progress?.Report(Math.Min(1.0, (double)received / total));
                }
            }

            string digest = Convert.ToHexString(hash.GetHashAndReset());
            bool valid = received > 0 && head is [(byte)'M', (byte)'Z']
                && (release.Size <= 0 || received == release.Size)
                && (release.Sha256 is null || digest.Equals(release.Sha256, StringComparison.OrdinalIgnoreCase));
            if (!valid)
                throw new UpdateException(Loc.T("下载的文件不完整或校验失败，请重试。", "The downloaded file is incomplete or failed verification. Please try again."));
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException || (ex is OperationCanceledException && !ct.IsCancellationRequested))
        {
            TryDelete(path);
            throw new UpdateException(Loc.T("下载中断，请检查网络后重试。", "The download was interrupted. Please check your network and try again."), ex);
        }
        catch
        {
            TryDelete(path);
            throw;
        }
    }

    // Only files attached to this repository's releases are installed (or files from the test server, when one is set).
    private static bool IsTrustedDownload(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri))
            return false;
        if (TestApiUrl is not null && Uri.TryCreate(TestApiUrl, UriKind.Absolute, out var test))
            return uri.Host == test.Host && uri.Port == test.Port;
        return uri.Scheme == Uri.UriSchemeHttps && uri.Host == "github.com"
            && uri.AbsolutePath.StartsWith($"/{Repository}/releases/download/", StringComparison.OrdinalIgnoreCase);
    }

    private static Version Normalize(Version version) => new(version.Major, Math.Max(0, version.Minor), Math.Max(0, version.Build));

    private static bool IsTrue(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    private static string? GetString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch
        {
            // Leftovers are removed on the next start.
        }
    }

    private static HttpClient CreateHttpClient()
    {
        var handler = new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(15),
            AutomaticDecompression = DecompressionMethods.All,
        };
        var http = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"QingYiTranslator/{CurrentVersionText}");
        return http;
    }
}
