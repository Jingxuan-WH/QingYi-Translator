using System.Diagnostics;
using Translator.Core;

namespace Translator.Platform;

/// <summary>
/// Microphone and/or system audio → mixer → <see cref="SpeechSegmenter"/> → Whisper, all off the UI thread.
/// While someone speaks, the utterance so far is recognized about once a second for partial results (skipped when the
/// machine can't keep up); when the pause comes, the whole utterance is recognized once more for the final result.
/// Events are raised on the synchronization context the transcriber was created on (the UI thread).
/// </summary>
internal sealed class LiveTranscriber : IDisposable
{
    private const int Rate = AudioCapture.SampleRate;
    private const double MinPartialSeconds = 0.6;

    private readonly SynchronizationContext _ui;
    private readonly object _audioLock = new();
    private readonly object _jobLock = new();
    private readonly Queue<Job> _finals = new();
    private readonly SemaphoreSlim _jobSignal = new(0);
    private readonly List<float> _utteranceAudio = [];
    private readonly SpeechSegmenter _segmenter = new(Rate);
    private readonly CancellationTokenSource _stop = new();
    private WhisperRecognizer? _recognizer;
    private AudioMixer? _mixer;
    private AudioCapture? _microphone;
    private AudioCapture? _system;
    private Task? _pump;
    private Task? _worker;
    private Job? _partial;
    private volatile int _closedUtterance;  // highest utterance that ended or was discarded
    private int _utterance;
    private long _utteranceStart;
    private int _lastPartialAt;
    private double _partialSeconds = 1.0;
    private volatile string? _lastLanguage;
    private volatile bool _finishing;      // stopped: recognize what is queued, then free the model
    private float _micLevel;
    private float _systemLevel;
    private long _lastLevelReport;
    private bool _disposed;

    public LiveTranscriber(SynchronizationContext ui) => _ui = ui;

    /// <summary>(utterance, text, start seconds)</summary>
    public event Action<int, string, double>? Partial;

    /// <summary>(utterance, text, start, end, language)</summary>
    public event Action<int, string, double, double, string?>? Final;

    public event Action<int>? Discarded;

    /// <summary>Recent loudness of the microphone and the system audio, 0–1.</summary>
    public event Action<float, float>? Levels;

    /// <summary>A device stopped or recognition failed; the message is for the user.</summary>
    public event Action<string>? Failed;

    public bool IsCapturing => _microphone is not null || _system is not null;

    /// <summary>Loads the model (slow: do not call on the UI thread) and starts the workers.</summary>
    public void Load(WhisperModelInfo model, Language? source, bool useGpu)
    {
        var watch = Stopwatch.StartNew();
        var recognizer = WhisperRecognizer.Load(WhisperModels.PathFor(model), source, useGpu);
        lock (_jobLock)
        {
            if (_disposed)
            {
                recognizer.Dispose(); // stopped while loading
                throw new OperationCanceledException();
            }
            _recognizer = recognizer;
        }
        Log.Info($"已加载语音模型 {model.Id}（{WhisperRuntime.Loaded}），用时 {watch.Elapsed.TotalSeconds:0.0} 秒");
        _pump = Task.Run(PumpAsync);
        _worker = Task.Run(WorkAsync);
    }

    /// <summary>Opens the devices. Throws <see cref="AudioCaptureException"/> when one can't be opened.</summary>
    public void StartCapture(string audioSource, string? microphoneId)
    {
        StopCapture();
        bool useMicrophone = audioSource is LiveSettings.SourceMicrophone or LiveSettings.SourceBoth;
        bool useSystem = audioSource is LiveSettings.SourceSystem or LiveSettings.SourceBoth;
        lock (_audioLock)
            _mixer = new AudioMixer(2, Rate);
        try
        {
            if (useMicrophone)
                _microphone = Open(AudioCapture.Microphone(microphoneId), 0);
            if (useSystem)
                _system = Open(AudioCapture.SystemAudio(), 1);
        }
        catch
        {
            StopCapture();
            throw;
        }
    }

    /// <summary>Releases the devices; the sentence in progress is finished. The model stays loaded.</summary>
    public void StopCapture()
    {
        _microphone?.Dispose();
        _system?.Dispose();
        _microphone = null;
        _system = null;
        lock (_audioLock)
        {
            if (_mixer is not null)
                HandleEvents(_segmenter.Flush());
            _mixer = null;
        }
        _micLevel = _systemLevel = 0;
        Post(() => Levels?.Invoke(0, 0));
    }

    /// <summary>
    /// Releases the devices at once. The sentence in progress is still recognized (its Final event follows), then
    /// the model is freed. Doesn't block the caller.
    /// </summary>
    public void Dispose()
    {
        lock (_jobLock)
        {
            if (_disposed)
                return;
            _disposed = true;
        }
        StopCapture();
        _finishing = true;
        _stop.Cancel(); // stops the audio pump
        _jobSignal.Release();
    }

    private AudioCapture Open(AudioCapture capture, int index)
    {
        capture.SamplesAvailable += samples =>
        {
            float level = Math.Min(1f, SpeechSegmenter.Rms(samples) * 4);
            lock (_audioLock)
            {
                _mixer?.Push(index, samples, Environment.TickCount64);
                if (index == 0)
                    _micLevel = Math.Max(level, _micLevel * 0.8f);
                else
                    _systemLevel = Math.Max(level, _systemLevel * 0.8f);
            }
        };
        capture.Stopped += error =>
        {
            Log.Error($"录音设备停止：{capture.Name}", error);
            Post(() => Failed?.Invoke(index == 0
                ? Loc.T($"麦克风“{capture.Name}”已断开或停止工作。", $"The microphone “{capture.Name}” was disconnected or stopped working.")
                : Loc.T($"播放设备“{capture.Name}”已断开或停止工作。", $"The playback device “{capture.Name}” was disconnected or stopped working.")));
        };
        try
        {
            capture.Start();
        }
        catch
        {
            capture.Dispose();
            throw;
        }
        return capture;
    }

    // ---------------- audio thread ----------------

    private async Task PumpAsync()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(40));
        try
        {
            while (await timer.WaitForNextTickAsync(_stop.Token))
            {
                lock (_audioLock)
                {
                    if (_mixer is null)
                        continue;
                    long now = Environment.TickCount64;
                    float[] mixed = _mixer.Drain(now);
                    if (mixed.Length > 0)
                        HandleEvents(_segmenter.Process(mixed));
                    if (now - _lastLevelReport >= 80)
                    {
                        _lastLevelReport = now;
                        float mic = _micLevel, system = _systemLevel;
                        _micLevel *= 0.7f;
                        _systemLevel *= 0.7f;
                        Post(() => Levels?.Invoke(mic, system));
                    }
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Stopped.
        }
        catch (Exception ex)
        {
            Log.Error("实时转录的音频处理出错", ex);
            Post(() => Failed?.Invoke(Loc.T($"音频处理出错：{ex.Message}", $"Audio processing failed: {ex.Message}")));
        }
    }

    // Called with _audioLock held.
    private void HandleEvents(List<SegmentEvent> events)
    {
        foreach (var e in events)
        {
            switch (e.Kind)
            {
                case SegmentEventKind.Started:
                    _utterance = e.Utterance;
                    _utteranceStart = e.Sample;
                    _utteranceAudio.Clear();
                    _lastPartialAt = 0;
                    break;
                case SegmentEventKind.Audio:
                    _utteranceAudio.AddRange(e.Samples!);
                    if (_utteranceAudio.Count >= MinPartialSeconds * Rate && _utteranceAudio.Count - _lastPartialAt >= _partialSeconds * Rate)
                    {
                        _lastPartialAt = _utteranceAudio.Count;
                        Submit(new Job(_utterance, [.. _utteranceAudio], Seconds(_utteranceStart), Seconds(e.Sample), IsFinal: false));
                    }
                    break;
                case SegmentEventKind.Ended:
                    _closedUtterance = e.Utterance;
                    Submit(new Job(e.Utterance, [.. _utteranceAudio], Seconds(_utteranceStart), Seconds(e.Sample), IsFinal: true));
                    ReleaseUtteranceBuffer();
                    break;
                case SegmentEventKind.Discarded:
                    _closedUtterance = e.Utterance;
                    int discarded = e.Utterance;
                    Post(() => Discarded?.Invoke(discarded));
                    ReleaseUtteranceBuffer();
                    break;
            }
        }
    }

    // A long utterance grows the buffer to about 2 MB; don't keep that around for the rest of the session.
    private void ReleaseUtteranceBuffer()
    {
        _utteranceAudio.Clear();
        if (_utteranceAudio.Capacity > Rate * 10)
            _utteranceAudio.Capacity = Rate * 10;
    }

    private void Submit(Job job)
    {
        lock (_jobLock)
        {
            if (job.IsFinal)
                _finals.Enqueue(job);
            else
                _partial = job; // only the newest partial matters
        }
        _jobSignal.Release();
    }

    // ---------------- recognition thread ----------------

    private async Task WorkAsync()
    {
        try
        {
            while (true)
            {
                await _jobSignal.WaitAsync();
                Job? job;
                lock (_jobLock)
                {
                    if (_finals.Count > 0)
                    {
                        job = _finals.Dequeue();
                    }
                    else
                    {
                        job = _finishing ? null : _partial;
                        _partial = null;
                        if (_finishing)
                            break;
                    }
                }
                if (job is null || (!job.IsFinal && job.Utterance <= _closedUtterance))
                    continue;
                await RecognizeAsync(job);
            }
        }
        catch (Exception ex)
        {
            Log.Error("语音识别线程出错", ex);
        }
        finally
        {
            _recognizer?.Dispose(); // frees the model
            _recognizer = null;
        }
    }

    private async Task RecognizeAsync(Job job)
    {
        var watch = Stopwatch.StartNew();
        RecognizedText result;
        try
        {
            result = await _recognizer!.RecognizeAsync(job.Samples, job.IsFinal ? null : _lastLanguage, CancellationToken.None);
        }
        catch (Exception ex)
        {
            Log.Error("语音识别失败", ex);
            Post(() => Failed?.Invoke(Loc.T($"语音识别失败：{ex.Message}", $"Speech recognition failed: {ex.Message}")));
            return;
        }

        if (job.IsFinal)
        {
            if (result.Language is { Length: > 0 } language)
                _lastLanguage = language;
            Post(() => Final?.Invoke(job.Utterance, result.Text, job.Start, job.End, result.Language));
        }
        else
        {
            // Partial passes take a full model run each; space them out when the machine is slow.
            _partialSeconds = Math.Clamp(watch.Elapsed.TotalSeconds * 1.5, 0.8, 4);
            if (job.Utterance > _closedUtterance && result.Text.Length > 0)
                Post(() => Partial?.Invoke(job.Utterance, result.Text, job.Start));
        }
    }

    private static double Seconds(long sample) => (double)sample / Rate;

    private void Post(Action action) => _ui.Post(_ => action(), null);

    private sealed record Job(int Utterance, float[] Samples, double Start, double End, bool IsFinal);
}
