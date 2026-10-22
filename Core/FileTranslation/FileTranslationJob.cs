namespace Translator.Core.FileTranslation;

/// <summary>Sends one request: a system prompt and a user message, returning the model's whole answer.</summary>
public delegate Task<TranslationResult> CompletionCall(string systemPrompt, string userMessage, CancellationToken ct);

public sealed record FileTranslationProgress(int Done, int Total);

/// <param name="Profile">Field, style and terms the user confirmed; null when they skipped that step.</param>
/// <param name="Terms">The terms to enforce (the user's glossary entries and the confirmed detected terms).</param>
public sealed record FileTranslationOptions(
    Language Target,
    DomainProfile? Profile,
    IReadOnlyList<GlossaryEntry> Terms,
    string ExtraInstructions = "",
    bool SkipReferences = true,
    bool Bilingual = false);

public sealed record FileTranslationResult(string OutputPath, string? BilingualPath, int Translated, int Untranslated, IReadOnlyList<string> Warnings);

/// <summary>
/// Translates one document: identifies its field and terms, translates the segments in batches with limited
/// concurrency and automatic retries, and saves the copy next to the original. Translations already received
/// are kept, so running <see cref="TranslateAsync"/> again after an error only sends what is still missing.
/// </summary>
public sealed class FileTranslationJob(TranslatableDocument document, CompletionCall call, int maxConcurrency = 4)
{
    private const int MaxAttempts = 3;

    private readonly Dictionary<string, string> _done = new(StringComparer.Ordinal); // tagged source text → translation
    private readonly object _gate = new();
    private string? _doneKey;

    public TranslatableDocument Document { get; } = document;

    /// <summary>Waits before retry n (1-based); tests shorten it.</summary>
    public Func<int, TimeSpan> RetryDelay { get; init; } = attempt => TimeSpan.FromSeconds(attempt * attempt * 2);

    /// <summary>The language the document seems to be written in, from a sample of its text.</summary>
    public Language? DetectSourceLanguage() =>
        LanguageDetector.Detect(string.Join('\n', Document.Segments.Take(200).Select(segment => segment.PlainText)));

    public int CharacterCount => Document.Segments.Sum(segment => segment.Text.Text.Length);

    /// <summary>Asks the model for the document's field, style and key terms. Returns null if the answer can't be read.</summary>
    public async Task<DomainProfile?> AnalyzeAsync(Language target, Language answerLanguage, CancellationToken ct)
    {
        string sample = DomainAnalyzer.BuildSample(Document.Segments);
        if (sample.Length == 0)
            return null;
        var result = await call(DomainAnalyzer.BuildSystemPrompt(target, answerLanguage), sample, ct);
        var profile = DomainAnalyzer.Parse(result.Text);
        if (profile is null)
            Log.Info($"领域识别的回答无法解析：{(result.Text.Length > 300 ? result.Text[..300] : result.Text)}");
        return profile;
    }

    /// <summary>The segments that will be sent, grouped by identical text (repeated headers, table headings… are translated once).</summary>
    private List<(string Text, int Count)> PendingTexts(FileTranslationOptions options)
    {
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        var order = new List<string>();
        foreach (var segment in Document.Segments)
        {
            if (options.SkipReferences && segment.IsReference)
                continue;
            if (!counts.TryGetValue(segment.Text.Text, out int count))
                order.Add(segment.Text.Text);
            counts[segment.Text.Text] = count + 1;
        }
        return order.Select(text => (text, counts[text])).ToList();
    }

    public async Task<FileTranslationResult> TranslateAsync(FileTranslationOptions options, IProgress<FileTranslationProgress>? progress,
        CancellationToken ct)
    {
        // Translations made for another target language or other terms don't carry over.
        string key = string.Join('\u001F', options.Target.Code, options.Profile?.DomainText, options.Profile?.Style, options.ExtraInstructions,
            string.Join('\u001E', options.Terms.Select(term => term.Source + '=' + term.Target)));
        lock (_gate)
        {
            if (_doneKey != key)
                _done.Clear();
            _doneKey = key;
        }

        var texts = PendingTexts(options);
        int total = texts.Sum(text => text.Count);
        int done;
        lock (_gate)
            done = texts.Where(text => _done.ContainsKey(text.Text)).Sum(text => text.Count);
        progress?.Report(new FileTranslationProgress(done, total));

        var todo = texts.Where(text => !_done.ContainsKey(text.Text)).ToList();
        var batches = SegmentBatcher.Plan(todo, text => text.Text.Length);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        using var gate = new SemaphoreSlim(Math.Max(1, maxConcurrency));
        var untranslated = new HashSet<string>(StringComparer.Ordinal);

        Exception? failure = null;

        async Task RunBatch(List<(string Text, int Count)> batch)
        {
            try
            {
                await gate.WaitAsync(linked.Token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            try
            {
                var missing = await TranslateBatchAsync(batch.Select(item => item.Text).ToList(), options, linked.Token);
                // Segments the model left out are tried again one by one.
                foreach (string text in missing)
                {
                    var retry = await TranslateBatchAsync([text], options, linked.Token);
                    if (retry.Count > 0)
                    {
                        lock (_gate)
                            untranslated.Add(text);
                    }
                }
                int finished = batch.Sum(item => item.Count);
                progress?.Report(new FileTranslationProgress(Interlocked.Add(ref done, finished), total));
            }
            catch (OperationCanceledException) when (linked.IsCancellationRequested)
            {
                // Stopped by the user or by another batch's error.
            }
            catch (Exception ex)
            {
                // Stop the other batches at the first error; the translations received so far stay for a retry.
                lock (_gate)
                    failure ??= ex;
                linked.Cancel();
            }
            finally
            {
                gate.Release();
            }
        }

        await Task.WhenAll(batches.Select(RunBatch));
        ct.ThrowIfCancellationRequested();
        if (failure is not null)
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Throw(failure);

        var translations = new Dictionary<int, string>();
        lock (_gate)
        {
            foreach (var segment in Document.Segments)
            {
                if (_done.TryGetValue(segment.Text.Text, out string? translation) && !(options.SkipReferences && segment.IsReference))
                    translations[segment.Id] = translation;
            }
        }

        string output = OutputPaths.For(Document.SourcePath, options.Target);
        string? bilingual = options.Bilingual && Document.SupportsBilingual ? OutputPaths.For(Document.SourcePath, options.Target, "bilingual") : null;
        ct.ThrowIfCancellationRequested();
        Document.Save(output, translations, new DocumentSaveOptions(options.Target, bilingual));
        int failed = Document.Segments.Count(segment => untranslated.Contains(segment.Text.Text));
        return new FileTranslationResult(output, bilingual, translations.Count, failed, Document.Warnings.ToList());
    }

    /// <summary>
    /// Translates the texts in one request, retrying on network and server errors. Returns the texts the
    /// answer left out. Errors the user has to fix (API key, model) are thrown at once.
    /// </summary>
    private async Task<List<string>> TranslateBatchAsync(List<string> texts, FileTranslationOptions options, CancellationToken ct)
    {
        var glossary = Glossary.Match(options.Terms, string.Join('\n', texts.Select(TaggedText.StripTags)));
        string system = SegmentBatcher.BuildSystemPrompt(options.Target, options.Profile, glossary, Document.PromptHint, options.ExtraInstructions);
        string user = SegmentBatcher.BuildUserMessage(texts);
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                var result = await call(system, user, ct);
                var parsed = SegmentBatcher.ParseResponse(result.Text, texts.Count, complete: result.FinishReason != "length");
                var missing = new List<string>();
                lock (_gate)
                {
                    for (int i = 0; i < texts.Count; i++)
                    {
                        if (parsed.TryGetValue(i, out string? translation) && translation.Length > 0)
                            _done[texts[i]] = translation;
                        else
                            missing.Add(texts[i]);
                    }
                }
                if (missing.Count > 0)
                    Log.Info($"文件翻译：{texts.Count} 段中有 {missing.Count} 段没有返回（finish_reason={result.FinishReason}）");
                return missing;
            }
            catch (TranslationException ex) when (!ex.NeedsSettings && attempt < MaxAttempts)
            {
                Log.Info($"文件翻译请求失败，第 {attempt} 次重试：{ex.Message}");
                await Task.Delay(RetryDelay(attempt), ct);
            }
        }
    }
}
