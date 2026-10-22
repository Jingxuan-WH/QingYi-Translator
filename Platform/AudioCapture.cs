using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Dmo;
using NAudio.Dsp;
using NAudio.Wave;
using Translator.Core;

namespace Translator.Platform;

/// <summary>A microphone the user can pick.</summary>
internal sealed record AudioDeviceInfo(string Id, string Name);

/// <summary>Opening a device failed; the message is meant for the user.</summary>
internal sealed class AudioCaptureException(string message, bool microphonePrivacy = false, Exception? inner = null) : Exception(message, inner)
{
    /// <summary>Windows privacy settings block microphone access for desktop apps.</summary>
    public bool MicrophonePrivacy { get; } = microphonePrivacy;
}

/// <summary>
/// Records a WASAPI endpoint, either a microphone or the speakers in loopback mode (what the PC is playing),
/// and delivers 16 kHz mono float samples. Events are raised on NAudio's capture thread.
/// </summary>
internal sealed class AudioCapture : IDisposable
{
    public const int SampleRate = 16000;
    private const int E_ACCESSDENIED = unchecked((int)0x80070005);

    private readonly WasapiCapture _capture;
    private readonly WaveFormat _format;
    private readonly bool _isFloat;
    private readonly WdlResampler? _resampler;
    private float[] _mono = [];
    private float[] _resampled = [];
    private bool _disposed;

    public event Action<float[]>? SamplesAvailable;

    /// <summary>The device stopped by itself (unplugged, disabled…); null for a normal stop.</summary>
    public event Action<Exception?>? Stopped;

    private AudioCapture(WasapiCapture capture, string name)
    {
        _capture = capture;
        Name = name;
        _format = capture.WaveFormat;
        _isFloat = _format.Encoding == WaveFormatEncoding.IeeeFloat
            || (_format is WaveFormatExtensible extensible && extensible.SubFormat == AudioMediaSubtypes.MEDIASUBTYPE_IEEE_FLOAT);
        if (_format.SampleRate != SampleRate)
        {
            _resampler = new WdlResampler();
            _resampler.SetMode(true, 2, false, 64, 32);
            _resampler.SetFilterParms(0.693f, 0.707f);
            _resampler.SetFeedMode(true);
            _resampler.SetRates(_format.SampleRate, SampleRate);
        }
        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += (_, e) =>
        {
            if (!_disposed)
                Stopped?.Invoke(e.Exception);
        };
    }

    public string Name { get; }

    public static IReadOnlyList<AudioDeviceInfo> Microphones()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var devices = new List<AudioDeviceInfo>();
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                using (device)
                    devices.Add(new AudioDeviceInfo(device.ID, device.FriendlyName));
            }
            return devices;
        }
        catch (Exception ex)
        {
            Log.Error("无法列出麦克风", ex);
            return [];
        }
    }

    /// <param name="deviceId">Null (or a device that is gone) uses the Windows default microphone.</param>
    public static AudioCapture Microphone(string? deviceId)
    {
        MMDevice device;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            device = TryGetDevice(enumerator, deviceId) ?? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        }
        catch (COMException ex)
        {
            throw new AudioCaptureException(Loc.T("没有找到麦克风，请检查麦克风是否已连接并在系统声音设置中启用。",
                "No microphone was found. Check that one is connected and enabled in the Windows sound settings."), inner: ex);
        }
        return Open(() => new WasapiCapture(device), device.FriendlyName, microphone: true);
    }

    /// <summary>Loopback recording of the default playback device.</summary>
    public static AudioCapture SystemAudio()
    {
        MMDevice device;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        }
        catch (COMException ex)
        {
            throw new AudioCaptureException(Loc.T("没有找到播放设备（扬声器或耳机），无法录制电脑的声音。",
                "No playback device (speakers or headphones) was found, so the PC's sound can't be recorded."), inner: ex);
        }
        return Open(() => new WasapiLoopbackCapture(device), device.FriendlyName, microphone: false);
    }

    public void Start()
    {
        try
        {
            _capture.StartRecording();
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            throw Describe(ex, microphone: _capture is not WasapiLoopbackCapture);
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _capture.DataAvailable -= OnDataAvailable;
        try
        {
            _capture.StopRecording();
        }
        catch (Exception ex)
        {
            Log.Error("停止录音失败", ex);
        }
        _capture.Dispose();
    }

    private static MMDevice? TryGetDevice(MMDeviceEnumerator enumerator, string? id)
    {
        if (string.IsNullOrEmpty(id))
            return null;
        try
        {
            var device = enumerator.GetDevice(id);
            if (device.State == DeviceState.Active)
                return device;
            device.Dispose();
        }
        catch (COMException)
        {
            // Unplugged since it was picked; fall back to the default.
        }
        return null;
    }

    private static AudioCapture Open(Func<WasapiCapture> create, string name, bool microphone)
    {
        try
        {
            return new AudioCapture(create(), name);
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or ArgumentException)
        {
            throw Describe(ex, microphone);
        }
    }

    private static AudioCaptureException Describe(Exception ex, bool microphone)
    {
        Log.Error(microphone ? "无法打开麦克风" : "无法录制系统声音", ex);
        if (microphone && (ex is UnauthorizedAccessException || ex.HResult == E_ACCESSDENIED))
            return new AudioCaptureException(Loc.T("Windows 不允许轻译使用麦克风。请在“设置 › 隐私和安全性 › 麦克风”中打开“麦克风访问权限”和“允许桌面应用访问你的麦克风”。",
                "Windows doesn’t let QingYi use the microphone. Turn on “Microphone access” and “Let desktop apps access your microphone” under Settings › Privacy & security › Microphone."),
                microphonePrivacy: true, ex);
        return new AudioCaptureException(microphone
            ? Loc.T($"无法打开麦克风：{ex.Message}", $"Couldn’t open the microphone: {ex.Message}")
            : Loc.T($"无法录制电脑的声音：{ex.Message}", $"Couldn’t record the PC’s sound: {ex.Message}"), inner: ex);
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        int channels = Math.Max(1, _format.Channels);
        int bytesPerSample = Math.Max(1, _format.BitsPerSample / 8);
        int frames = e.BytesRecorded / (bytesPerSample * channels);
        if (frames == 0)
            return;
        if (_mono.Length < frames)
            _mono = new float[frames];
        Downmix(e.Buffer, frames, channels, bytesPerSample);

        float[] output;
        if (_resampler is null)
        {
            output = _mono[..frames];
        }
        else
        {
            int needed = _resampler.ResamplePrepare(frames, 1, out float[] input, out int offset);
            Array.Copy(_mono, 0, input, offset, Math.Min(needed, frames));
            int capacity = (int)((long)frames * SampleRate / _format.SampleRate) + 64;
            if (_resampled.Length < capacity)
                _resampled = new float[capacity];
            int produced = _resampler.ResampleOut(_resampled, 0, Math.Min(needed, frames), capacity, 1);
            output = _resampled[..produced];
        }
        if (output.Length > 0)
            SamplesAvailable?.Invoke(output);
    }

    // Averages the channels of 16/24/32-bit PCM or 32-bit float audio into _mono.
    private void Downmix(byte[] buffer, int frames, int channels, int bytesPerSample)
    {
        var span = buffer.AsSpan();
        for (int frame = 0; frame < frames; frame++)
        {
            float sum = 0;
            int at = frame * channels * bytesPerSample;
            for (int channel = 0; channel < channels; channel++, at += bytesPerSample)
            {
                sum += bytesPerSample switch
                {
                    4 when _isFloat => BitConverter.ToSingle(span.Slice(at, 4)),
                    4 => BitConverter.ToInt32(span.Slice(at, 4)) / 2147483648f,
                    3 => ((span[at] << 8 | span[at + 1] << 16 | span[at + 2] << 24) >> 8) / 8388608f,
                    2 => BitConverter.ToInt16(span.Slice(at, 2)) / 32768f,
                    _ => (span[at] - 128) / 128f,
                };
            }
            _mono[frame] = sum / channels;
        }
    }
}
