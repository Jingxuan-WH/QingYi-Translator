using System.Text.RegularExpressions;
using Translator.Core;
using Translator.Core.FileTranslation;
using Xunit;

namespace Translator.Tests;

/// <summary>A document whose segments are given directly; Save records what it was asked to write.</summary>
internal sealed class FakeDocument : TranslatableDocument
{
    public FakeDocument(params string[] texts) : base(Path.Combine(Path.GetTempPath(), $"qy-fake-{Guid.NewGuid():N}.txt"))
    {
        foreach (string text in texts)
            AddSegment(text);
    }

    public DocumentSegment Add(IReadOnlyList<InlinePiece> pieces, SegmentRole role = SegmentRole.Body) => AddSegment(pieces, role);

    public IReadOnlyDictionary<int, string>? Saved { get; private set; }

    public override void Save(string outputPath, IReadOnlyDictionary<int, string> translations, DocumentSaveOptions options) =>
        Saved = translations;
}

public class FileTranslationJobTests
{
    private static readonly Regex Segment = new("<seg id=\"(\\d+)\">(.*?)</seg>", RegexOptions.Singleline);

    /// <summary>A model that upper-cases each segment, with hooks to misbehave.</summary>
    private sealed class FakeModel
    {
        public int Calls;
        public List<string> SystemPrompts { get; } = [];
        public Func<int, string, string?>? Override; // call number, user message → answer (null: normal)

        public Task<TranslationResult> Call(string system, string user, CancellationToken ct)
        {
            int call = Interlocked.Increment(ref Calls);
            lock (SystemPrompts)
                SystemPrompts.Add(system);
            if (Override?.Invoke(call, user) is { } answer)
                return Task.FromResult(new TranslationResult(answer, "stop"));
            string text = Segment.Replace(user, m => $"<seg id=\"{m.Groups[1].Value}\">{m.Groups[2].Value.ToUpperInvariant()}</seg>");
            return Task.FromResult(new TranslationResult(text, "stop"));
        }
    }

    private static FileTranslationOptions Options(params GlossaryEntry[] terms) =>
        new(Languages.SimplifiedChinese, new DomainProfile("Law", "", "Contract", []), terms);

    [Fact]
    public async Task TranslatesEverySegmentOnceAndReportsProgress()
    {
        var document = new FakeDocument("alpha", "beta", "alpha", "gamma");
        var model = new FakeModel();
        var reports = new List<FileTranslationProgress>();
        var job = new FileTranslationJob(document, model.Call);
        var result = await job.TranslateAsync(Options(), new SyncProgress<FileTranslationProgress>(reports.Add), CancellationToken.None);

        Assert.Equal(["ALPHA", "BETA", "ALPHA", "GAMMA"], document.Saved!.OrderBy(p => p.Key).Select(p => p.Value));
        Assert.Equal(1, model.Calls); // one batch, the repeated "alpha" sent once
        Assert.Equal(4, reports[^1].Done);
        Assert.Equal(4, reports[^1].Total);
        Assert.Equal(0, result.Untranslated);
        Assert.Contains("Field: Law", model.SystemPrompts[0]);
    }

    [Fact]
    public async Task OnlyMatchingTermsAreSentWithEachBatch()
    {
        var document = new FakeDocument("The tort of negligence.");
        var model = new FakeModel();
        await new FileTranslationJob(document, model.Call).TranslateAsync(
            Options(new GlossaryEntry { Source = "tort", Target = "侵权" }, new GlossaryEntry { Source = "estoppel", Target = "禁反言" }), null, CancellationToken.None);
        Assert.Contains("- tort = 侵权", model.SystemPrompts[0]);
        Assert.DoesNotContain("estoppel", model.SystemPrompts[0]);
    }

    [Fact]
    public async Task RetriesNetworkErrorsAndSegmentsTheModelSkipped()
    {
        var document = new FakeDocument("one", "two", "three");
        var model = new FakeModel
        {
            Override = (call, user) => call switch
            {
                1 => throw new TranslationException("busy"),
                2 => "<seg id=\"1\">ONE</seg><seg id=\"3\">THREE</seg>", // "two" left out
                _ => null,
            },
        };
        var job = new FileTranslationJob(document, model.Call) { RetryDelay = _ => TimeSpan.Zero };
        var result = await job.TranslateAsync(Options(), null, CancellationToken.None);
        Assert.Equal(["ONE", "TWO", "THREE"], document.Saved!.OrderBy(p => p.Key).Select(p => p.Value));
        Assert.Equal(3, model.Calls);
        Assert.Equal(0, result.Untranslated);
    }

    [Fact]
    public async Task SettingsErrorsStopAtOnceAndARetryResumes()
    {
        var texts = Enumerable.Range(0, 80).Select(i => $"segment {i} " + new string('x', 100)).ToArray();
        var document = new FakeDocument(texts);
        bool broken = true;
        var model = new FakeModel { Override = (call, user) => broken && call == 2 ? throw new TranslationException("bad key", needsSettings: true) : null };
        var job = new FileTranslationJob(document, model.Call, maxConcurrency: 1) { RetryDelay = _ => TimeSpan.Zero };
        var error = await Assert.ThrowsAsync<TranslationException>(() => job.TranslateAsync(Options(), null, CancellationToken.None));
        Assert.True(error.NeedsSettings);
        Assert.Equal(2, model.Calls);

        broken = false;
        int before = model.Calls;
        var reports = new List<FileTranslationProgress>();
        await job.TranslateAsync(Options(), new SyncProgress<FileTranslationProgress>(reports.Add), CancellationToken.None);
        Assert.Equal(80, document.Saved!.Count);
        // The first batch was kept; only the rest was sent again.
        Assert.True(reports[0].Done > 0);
        Assert.Equal(SegmentBatcher.Plan(texts, t => t.Length).Count - 1, model.Calls - before);
    }

    [Fact]
    public async Task UnanswerableSegmentsKeepTheirOriginal()
    {
        var document = new FakeDocument("keep me", "fine");
        var model = new FakeModel { Override = (_, user) => user.Contains("keep me") && !user.Contains("fine") ? "" : user.Contains("fine") ? "<seg id=\"2\">FINE</seg>" : null };
        var result = await new FileTranslationJob(document, model.Call).TranslateAsync(Options(), null, CancellationToken.None);
        Assert.Equal(1, result.Untranslated);
        Assert.False(document.Saved!.ContainsKey(0));
        Assert.Equal("FINE", document.Saved[1]);
    }

    [Fact]
    public async Task ReferencesAreSkippedWhenAsked()
    {
        var document = new FakeDocument("Body text");
        document.Add([InlinePiece.Of("[1] A. Author, Title.", 0)]).IsReference = true;
        var model = new FakeModel();
        await new FileTranslationJob(document, model.Call).TranslateAsync(Options() with { SkipReferences = true }, null, CancellationToken.None);
        Assert.Equal([0], document.Saved!.Keys);
        await new FileTranslationJob(document, model.Call).TranslateAsync(Options() with { SkipReferences = false }, null, CancellationToken.None);
        Assert.Equal([0, 1], document.Saved!.Keys.Order());
    }

    [Fact]
    public async Task AnalyzeReadsTheProfile()
    {
        var document = new FakeDocument("Contract law basics", "The tort of negligence requires a duty of care.");
        var model = new FakeModel { Override = (_, _) => """{"domain":"法学","subdomain":"侵权法","style":"教材","terms":[{"source":"duty of care","target":"注意义务"}]}""" };
        var profile = await new FileTranslationJob(document, model.Call).AnalyzeAsync(Languages.SimplifiedChinese, Languages.SimplifiedChinese, CancellationToken.None);
        Assert.Equal("法学 · 侵权法", profile!.DomainText);
        Assert.Equal("注意义务", profile.Terms[0].Target);
        Assert.Contains("into Simplified Chinese", model.SystemPrompts[0]);
    }

    /// <summary>Reports synchronously (Progress&lt;T&gt; posts to the thread pool, which makes tests racy).</summary>
    private sealed class SyncProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value)
        {
            lock (this)
                report(value);
        }
    }
}
