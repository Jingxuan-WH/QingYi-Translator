using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using Translator.Core;
using Xunit;

namespace Translator.Tests;

public class WhisperModelsTests
{
    [Fact]
    public void Catalog()
    {
        Assert.Equal("small", WhisperModels.Find("missing").Id);
        Assert.Equal(["base", "small", "large-v3-turbo-q5_0"], WhisperModels.All.Select(model => model.Id));
        Assert.All(WhisperModels.All, model => Assert.Matches("^[0-9a-f]{40}$", model.Sha1));
        var mirror = WhisperModels.ResolveSource(WhisperModels.MirrorId);
        Assert.Equal("https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
            WhisperModels.DownloadUrl(WhisperModels.Find("small"), mirror).ToString());
        Assert.Equal("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
            WhisperModels.DownloadUrl(WhisperModels.Find("base"), WhisperModels.ResolveSource(WhisperModels.HuggingFaceId)).ToString());
        Assert.Contains(WhisperModels.ResolveSource("").Id, new[] { WhisperModels.MirrorId, WhisperModels.HuggingFaceId });
    }

    [Fact]
    public void HashAndVerifiedMarker()
    {
        string dir = Directory.CreateTempSubdirectory().FullName;
        string path = Path.Combine(dir, "model.bin");
        File.WriteAllText(path, "abc");
        const string sha1 = "a9993e364706816aba3e25717850c26c9cd0d89d";
        Assert.True(WhisperModels.HashMatches(path, sha1));
        Assert.True(WhisperModels.HashMatches(path, sha1.ToUpperInvariant()));
        Assert.False(WhisperModels.HashMatches(path, new string('0', 40)));

        Assert.False(WhisperModels.IsMarkedVerified(path, sha1));
        WhisperModels.MarkVerified(path, sha1);
        Assert.True(WhisperModels.IsMarkedVerified(path, sha1));
        Assert.False(WhisperModels.IsMarkedVerified(path, new string('0', 40)));
        File.AppendAllText(path, "d"); // changed afterwards
        Assert.False(WhisperModels.IsMarkedVerified(path, sha1));
    }

    [Fact]
    public async Task DownloadResumesAndVerifies()
    {
        byte[] content = RandomNumberGenerator.GetBytes(300_000);
        string sha1 = Convert.ToHexString(SHA1.HashData(content));
        using var server = new RangeServer(content, cutFirstAfter: 100_000);
        string dir = Directory.CreateTempSubdirectory().FullName;
        string path = Path.Combine(dir, "model.bin");
        var reports = new List<DownloadProgress>();
        var progress = new SyncProgress(reports.Add);

        await Assert.ThrowsAsync<DownloadException>(() =>
            WhisperModels.DownloadFileAsync(server.Url, path, file => WhisperModels.HashMatches(file, sha1), progress, CancellationToken.None));
        Assert.False(File.Exists(path));
        long partial = new FileInfo(path + ".part").Length;
        Assert.InRange(partial, 1, content.Length - 1);

        await WhisperModels.DownloadFileAsync(server.Url, path, file => WhisperModels.HashMatches(file, sha1), progress, CancellationToken.None);
        Assert.Equal(content, File.ReadAllBytes(path));
        Assert.False(File.Exists(path + ".part"));
        Assert.Equal($"bytes={partial}-", server.LastRange);
        Assert.True(reports[^1].Verifying);
        Assert.Equal(content.Length, reports[^1].Total);
    }

    [Fact]
    public async Task FailedVerificationDeletesTheDownload()
    {
        byte[] content = RandomNumberGenerator.GetBytes(50_000);
        using var server = new RangeServer(content);
        string path = Path.Combine(Directory.CreateTempSubdirectory().FullName, "model.bin");
        await Assert.ThrowsAsync<DownloadException>(() =>
            WhisperModels.DownloadFileAsync(server.Url, path, _ => false, null, CancellationToken.None));
        Assert.False(File.Exists(path));
        Assert.False(File.Exists(path + ".part"));
    }

    [Fact]
    public async Task HttpErrorsAreReported()
    {
        using var server = new RangeServer([], status: 404);
        string path = Path.Combine(Directory.CreateTempSubdirectory().FullName, "model.bin");
        var error = await Assert.ThrowsAsync<DownloadException>(() =>
            WhisperModels.DownloadFileAsync(server.Url, path, _ => true, null, CancellationToken.None));
        Assert.Contains("404", error.Message);
    }

    private sealed class SyncProgress(Action<DownloadProgress> report) : IProgress<DownloadProgress>
    {
        public void Report(DownloadProgress value) => report(value);
    }

    /// <summary>A tiny HTTP server that honors Range requests and can drop the first connection halfway.</summary>
    private sealed class RangeServer : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly byte[] _content;
        private readonly int _status;
        private int _cutFirstAfter;

        public RangeServer(byte[] content, int cutFirstAfter = 0, int status = 200)
        {
            _content = content;
            _cutFirstAfter = cutFirstAfter;
            _status = status;
            _listener.Start();
            _ = Task.Run(ServeAsync);
        }

        public Uri Url => new($"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}/model.bin");

        public string? LastRange { get; private set; }

        private async Task ServeAsync()
        {
            while (true)
            {
                using var client = await _listener.AcceptTcpClientAsync();
                using var stream = client.GetStream();
                var reader = new StreamReader(stream);
                string? line;
                string? range = null;
                while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync()))
                {
                    if (line.StartsWith("Range:", StringComparison.OrdinalIgnoreCase))
                        range = line[6..].Trim();
                }
                LastRange = range;
                int start = range is null ? 0 : int.Parse(range["bytes=".Length..].TrimEnd('-'));
                string head = _status != 200 ? $"HTTP/1.1 {_status} Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    : range is null
                        ? $"HTTP/1.1 200 OK\r\nContent-Length: {_content.Length}\r\nConnection: close\r\n\r\n"
                        : $"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{_content.Length - 1}/{_content.Length}\r\nContent-Length: {_content.Length - start}\r\nConnection: close\r\n\r\n";
                await stream.WriteAsync(System.Text.Encoding.ASCII.GetBytes(head));
                if (_status != 200)
                    continue;
                int length = _content.Length - start;
                if (_cutFirstAfter > 0)
                {
                    length = _cutFirstAfter;
                    _cutFirstAfter = 0;
                }
                await stream.WriteAsync(_content.AsMemory(start, length));
                await stream.FlushAsync();
            }
        }

        public void Dispose() => _listener.Stop();
    }
}

public class SpeechTextTests
{
    [Fact]
    public void CleansTags()
    {
        Assert.Equal("hello world", SpeechText.Clean("[BLANK_AUDIO]  hello   world (music) ♪♪"));
        Assert.Equal("我们开始上课", SpeechText.Clean("（音乐）我们开始上课"));
        Assert.Equal("问题（一）怎么解", SpeechText.Clean("问题（一）怎么解"));
        Assert.Equal("next", SpeechText.Clean(" - next"));
    }

    [Fact]
    public void DetectsTypicalHallucinations()
    {
        Assert.True(SpeechText.IsLikelyHallucination("谢谢观看。"));
        Assert.True(SpeechText.IsLikelyHallucination("Thanks for watching!"));
        Assert.True(SpeechText.IsLikelyHallucination("字幕由Amara.org社区提供"));
        Assert.True(SpeechText.IsLikelyHallucination("..."));
        Assert.False(SpeechText.IsLikelyHallucination("今天我们讲潮流计算"));
        Assert.False(SpeechText.IsLikelyHallucination("Thank you for coming today."));
    }
}
