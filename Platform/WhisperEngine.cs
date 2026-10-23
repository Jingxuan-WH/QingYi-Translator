using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics.X86;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Translator.Core;
using Whisper.net;
using Whisper.net.LibraryLoader;
using Whisper.net.Logger;

namespace Translator.Platform;

/// <summary>
/// The native whisper.cpp libraries. The CPU builds (with and without AVX) are embedded in Translator.exe and
/// unpacked to %LOCALAPPDATA%\QingYiTranslator\whisper-runtime on first use. The Vulkan build for GPU acceleration
/// is about 58 MB, so it is downloaded only when wanted, from NuGet (the Whisper.net.Runtime.Vulkan package) and
/// checked against the package's SHA-512.
/// </summary>
internal static class WhisperRuntime
{
    public const string Version = "1.9.1";
    public const int GpuDownloadMegabytes = 36;
    private const string GpuPackageId = "whisper.net.runtime.vulkan";
    private const string GpuPackageSha512 = "hRYbrj76y09g38wZccGb3DvNiempYMq6Zf6FX/gKzxjS2Ff1JeTZ/XSSuJ0UgU13q/TAsD/Gl/Ctu0PmNcFjdA==";
    private const string NuGetBase = "https://api.nuget.org/v3-flatcontainer/";
    private const string MirrorIndex = "https://repo.huaweicloud.com/repository/nuget/v3/index.json";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private static readonly string[] VisualCppLibraries = ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll", "vcomp140.dll"];
    // Programs built with Visual Studio 17.10 or later (whisper.cpp is) crash in std::mutex with an older runtime.
    private static readonly Version MinimumVisualCpp = new(14, 40);
    private static bool _configured;
    private static IDisposable? _logger;
    private static Exception? _loadError;

    public static string Directory { get; } = Path.Combine(Path.GetDirectoryName(WhisperModels.Directory)!, $"whisper-runtime-{Version}");

    private static string GpuDirectory => Path.Combine(Directory, "runtimes", "vulkan", "win-x64");

    public static bool IsGpuInstalled => File.Exists(Path.Combine(GpuDirectory, "whisper.dll")) && File.Exists(Path.Combine(GpuDirectory, "ggml-vulkan-whisper.dll"));

    /// <summary>GPU drivers with Vulkan support install vulkan-1.dll; without it the GPU build can't run.</summary>
    public static bool HasVulkanDriver => File.Exists(Path.Combine(Environment.SystemDirectory, "vulkan-1.dll"));

    /// <summary>The x64 app runs emulated, e.g. on Windows on ARM.</summary>
    public static bool IsEmulated => RuntimeInformation.ProcessArchitecture != RuntimeInformation.OSArchitecture;

    /// <summary>
    /// Whether GPU acceleration is worth offering. Under emulation the x64 Vulkan build is untested (the driver is
    /// native), so only the CPU is used there.
    /// </summary>
    public static bool CanUseGpu => HasVulkanDriver && !IsEmulated;

    /// <summary>Microsoft's installer for the Visual C++ runtime that whisper.cpp is built against.</summary>
    public const string VisualCppDownloadUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe";

    /// <summary>
    /// whisper.cpp needs the Visual C++ 2015–2022 runtime (x64), version 14.40 or later. Most PCs have it from other
    /// programs, but a fresh Windows may not, and its license doesn't allow shipping it here, so the user is pointed to
    /// Microsoft's installer. Each library is loaded the way whisper.cpp will load it, and its version checked.
    /// </summary>
    /// <returns>Null when the runtime is fine; otherwise what is missing or too old.</returns>
    public static string? CheckVisualCppRuntime()
    {
        var found = new List<string>();
        var problems = new List<string>();
        foreach (string name in VisualCppLibraries)
        {
            if (!NativeLibrary.TryLoad(name, out IntPtr handle))
            {
                problems.Add(Loc.T($"缺少 {name}", $"{name} is missing"));
                continue;
            }
            try
            {
                string? path = ModulePath(handle);
                var info = path is null ? null : FileVersionInfo.GetVersionInfo(path);
                var version = info is null ? null : new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart);
                found.Add($"{name} {version?.ToString() ?? "?"}（{path}）");
                if (version is not null && version < MinimumVisualCpp)
                    problems.Add(Loc.T($"{name} 的版本 {version} 太旧", $"{name} is too old ({version})"));
            }
            finally
            {
                NativeLibrary.Free(handle); // an updated runtime loads fresh next time
            }
        }
        Log.Info($"Visual C++ 运行库：{(found.Count == 0 ? "-" : string.Join("；", found))}{(problems.Count == 0 ? "" : "；问题：" + string.Join("；", problems))}");
        return problems.Count == 0 ? null : string.Join(Loc.T("；", "; "), problems);
    }

    /// <summary>The native library failed to load; Whisper.net keeps that result until the app restarts.</summary>
    public static bool LoadFailed => _loadError is not null;

    /// <summary>Loads the native library if that hasn't happened yet. Throws <see cref="WhisperRuntimeException"/>.</summary>
    public static void EnsureLoaded()
    {
        if (Loaded is not null)
            return;
        if (_loadError is not null)
            throw new WhisperRuntimeException(_loadError);
        try
        {
            string? info = WhisperFactory.GetRuntimeInfo();
            Log.Info($"已加载 whisper.cpp 运行库：{Loaded}；{info?.Trim()}");
        }
        catch (Exception ex)
        {
            _loadError = ex;
            Log.Error("无法加载 whisper.cpp 运行库", ex);
            throw new WhisperRuntimeException(ex);
        }
    }

    /// <summary>Which build was loaded: "Vulkan", "Cpu" or "CpuNoAvx"; null before the first model is loaded.</summary>
    public static RuntimeLibrary? Loaded => RuntimeOptions.LoadedLibrary;

    /// <summary>
    /// Unpacks the embedded CPU builds and tells Whisper.net where to find them. The native library is loaded
    /// once per process, so turning GPU acceleration on only takes effect after a restart.
    /// </summary>
    public static void Prepare(bool useGpu)
    {
        if (_configured)
            return;
        _logger ??= LogProvider.AddLogger(OnWhisperLog);
        var assembly = typeof(WhisperRuntime).Assembly;
        foreach (string resource in assembly.GetManifestResourceNames())
        {
            string? folder = resource.StartsWith("whisper/cpu/", StringComparison.Ordinal) ? Path.Combine("runtimes", "win-x64")
                : resource.StartsWith("whisper/noavx/", StringComparison.Ordinal) ? Path.Combine("runtimes", "noavx", "win-x64")
                : null;
            if (folder is not null)
                Extract(assembly, resource, Path.Combine(Directory, folder, resource[(resource.LastIndexOf('/') + 1)..]));
        }
        // Whisper.net looks for "runtimes\…" next to the directory of this path.
        RuntimeOptions.LibraryPath = Path.Combine(Directory, "whisper.dll");
        // The AVX build may load on a CPU without AVX2 / FMA and then crash on the first sentence; use the other one there.
        bool avx = Avx.IsSupported && Avx2.IsSupported && Fma.IsSupported;
        var order = new List<RuntimeLibrary>();
        if (useGpu && IsGpuInstalled && !IsEmulated)
            order.Add(RuntimeLibrary.Vulkan);
        if (avx)
            order.Add(RuntimeLibrary.Cpu);
        order.Add(RuntimeLibrary.CpuNoAvx);
        RuntimeOptions.RuntimeLibraryOrder = order;
        Log.Info($"whisper.cpp 运行库：{Directory}，加载顺序 {string.Join(" → ", order)}（AVX {Avx.IsSupported}、AVX2 {Avx2.IsSupported}、FMA {Fma.IsSupported}；"
            + $"进程 {RuntimeInformation.ProcessArchitecture}，系统 {RuntimeInformation.OSArchitecture}）");
        _configured = true;
    }

    // whisper.cpp's own errors and warnings, and the loader's reasons for skipping a build, go to the app log.
    private static void OnWhisperLog(WhisperLogLevel level, string? message)
    {
        if (string.IsNullOrWhiteSpace(message))
            return;
        message = message.Trim();
        if (level == WhisperLogLevel.Error)
            Log.Error($"whisper.cpp：{message}");
        else if (level == WhisperLogLevel.Warning || (level == WhisperLogLevel.Debug && message.Contains("fail", StringComparison.OrdinalIgnoreCase)))
            Log.Info($"whisper.cpp：{message}");
    }

    private static string? ModulePath(IntPtr module)
    {
        var buffer = new char[1024];
        int length = GetModuleFileName(module, buffer, buffer.Length);
        return length > 0 ? new string(buffer, 0, length) : null;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetModuleFileNameW", SetLastError = true)]
    private static extern int GetModuleFileName(IntPtr hModule, [Out] char[] lpFilename, int nSize);

    public static string DescribeLoaded() => Loaded switch
    {
        RuntimeLibrary.Vulkan => Loc.T("GPU 加速（Vulkan）", "GPU (Vulkan)"),
        RuntimeLibrary.CpuNoAvx => Loc.T("CPU（兼容模式）", "CPU (compatibility mode)"),
        null => "",
        _ => "CPU",
    };

    /// <summary>Downloads the GPU build; tries the mirror in China first when <paramref name="preferMirror"/> is set.</summary>
    public static async Task DownloadGpuAsync(bool preferMirror, IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        string package = Path.Combine(Directory, "vulkan.nupkg");
        Func<CancellationToken, Task<Uri>>[] sources =
        [
            _ => Task.FromResult(PackageUrl(NuGetBase)),
            async token => PackageUrl(await ResolveMirrorBaseAsync(token)),
        ];
        if (preferMirror)
            Array.Reverse(sources);

        DownloadException? last = null;
        foreach (var source in sources)
        {
            try
            {
                Uri url = await source(ct);
                await WhisperModels.DownloadFileAsync(url, package, path => Sha512Matches(path), progress, ct);
                last = null;
                break;
            }
            catch (DownloadException ex)
            {
                last = ex;
            }
            catch (Exception ex) when (ex is HttpRequestException or JsonException or IOException || (ex is OperationCanceledException && !ct.IsCancellationRequested))
            {
                last = new DownloadException(Loc.T("无法连接到下载源。", "Couldn’t reach the download source."), ex);
            }
        }
        if (last is not null)
            throw last;

        await Task.Run(() =>
        {
            System.IO.Directory.CreateDirectory(GpuDirectory);
            using var zip = ZipFile.OpenRead(package);
            foreach (var entry in zip.Entries)
            {
                if (entry.FullName.StartsWith("build/win-x64/", StringComparison.Ordinal) && entry.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                    entry.ExtractToFile(Path.Combine(GpuDirectory, entry.Name), overwrite: true);
            }
        }, ct);
        File.Delete(package);
        if (!IsGpuInstalled)
        {
            Log.Error($"GPU 加速组件解压后缺少文件：{GpuDirectory}");
            throw new DownloadException(Loc.T("GPU 加速组件的文件不完整，无法使用。", "The GPU acceleration files are incomplete and can’t be used."));
        }
        Log.Info($"已下载 GPU 加速组件（Vulkan）：{GpuDirectory}");
    }

    private static Uri PackageUrl(string baseUrl) =>
        new($"{baseUrl.TrimEnd('/')}/{GpuPackageId}/{Version}/{GpuPackageId}.{Version}.nupkg");

    // NuGet mirrors publish their download address in the service index ("PackageBaseAddress").
    private static async Task<string> ResolveMirrorBaseAsync(CancellationToken ct)
    {
        using var doc = JsonDocument.Parse(await Http.GetStringAsync(MirrorIndex, ct));
        foreach (var resource in doc.RootElement.GetProperty("resources").EnumerateArray())
        {
            if (resource.TryGetProperty("@type", out var type) && type.GetString()?.StartsWith("PackageBaseAddress/3.0.0", StringComparison.Ordinal) == true)
                return resource.GetProperty("@id").GetString()!;
        }
        throw new JsonException("PackageBaseAddress not found");
    }

    private static bool Sha512Matches(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToBase64String(SHA512.HashData(stream)) == GpuPackageSha512;
    }

    private static void Extract(Assembly assembly, string resource, string path)
    {
        using var source = assembly.GetManifestResourceStream(resource)!;
        if (File.Exists(path) && new FileInfo(path).Length == source.Length)
            return;
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temp = path + ".tmp";
        using (var file = File.Create(temp))
            source.CopyTo(file);
        File.Move(temp, path, overwrite: true);
    }
}

/// <summary>The native whisper.cpp library couldn't be loaded; the app has to restart before it is tried again.</summary>
internal sealed class WhisperRuntimeException(Exception inner) : Exception(inner.Message, inner);

internal readonly record struct RecognizedText(string Text, string? Language);

/// <summary>
/// A loaded Whisper model. Not thread-safe: <see cref="LiveTranscriber"/> uses it from one worker at a time.
/// Disposing it frees the model's memory.
/// </summary>
internal sealed class WhisperRecognizer : IDisposable
{
    private const int MinSamples = AudioCapture.SampleRate * 11 / 10; // whisper.cpp wants at least a second

    private readonly WhisperFactory _factory;
    private readonly WhisperProcessor _processor;
    private readonly Language? _source;
    private string? _language;

    private WhisperRecognizer(WhisperFactory factory, WhisperProcessor processor, Language? source)
    {
        _factory = factory;
        _processor = processor;
        _source = source;
    }

    /// <param name="source">Null detects the language of each utterance.</param>
    public static WhisperRecognizer Load(string modelPath, Language? source, bool useGpu)
    {
        WhisperRuntime.Prepare(useGpu);
        WhisperRuntime.EnsureLoaded();
        var factory = WhisperFactory.FromPath(modelPath, new WhisperFactoryOptions { UseGpu = useGpu });
        try
        {
            var builder = factory.CreateBuilder()
                .WithThreads(Math.Clamp(Environment.ProcessorCount / 2, 2, 8))
                .WithNoContext()
                .WithSingleSegment()
                .WithLanguage(source is null ? "auto" : WhisperLanguage(source));
            // A prompt in the right script keeps Chinese output in simplified (or traditional) characters.
            if (source == Languages.SimplifiedChinese)
                builder = builder.WithPrompt("以下是普通话的句子。");
            else if (source == Languages.TraditionalChinese)
                builder = builder.WithPrompt("以下是普通話的句子。");
            return new WhisperRecognizer(factory, builder.Build(), source);
        }
        catch
        {
            factory.Dispose();
            throw;
        }
    }

    /// <param name="languageHint">For partial results with automatic detection: the language of the previous sentence.</param>
    public async Task<RecognizedText> RecognizeAsync(float[] samples, string? languageHint, CancellationToken ct)
    {
        if (samples.Length < MinSamples)
            Array.Resize(ref samples, MinSamples);
        string language = _source is not null ? WhisperLanguage(_source) : languageHint ?? "auto";
        if (language != _language)
        {
            _processor.ChangeLanguage(language);
            _language = language;
        }

        var text = new StringBuilder();
        string? detected = null;
        await foreach (var segment in _processor.ProcessAsync(samples, ct))
        {
            if (segment.NoSpeechProbability > 0.8f && segment.Probability < 0.4f)
                continue; // most likely noise
            text.Append(segment.Text);
            detected ??= segment.Language;
        }

        string result = SpeechText.Clean(text.ToString());
        if (SpeechText.IsLikelyHallucination(result))
            return new RecognizedText("", detected);
        if (detected == "zh" && _source != Languages.TraditionalChinese)
            result = ChineseScript.ToSimplified(result);
        if (detected == "zh" || _source?.IsChinese == true)
            result = SpeechText.UseChinesePunctuation(result);
        return new RecognizedText(result, detected);
    }

    public void Dispose()
    {
        _processor.Dispose();
        _factory.Dispose();
    }

    private static string WhisperLanguage(Language language) => language.IsChinese ? "zh" : language.Code;

    /// <summary>Whisper sometimes writes Mandarin in traditional characters; Windows can map them to simplified ones.</summary>
    private static class ChineseScript
    {
        private const uint LCMAP_SIMPLIFIED_CHINESE = 0x02000000;

        public static string ToSimplified(string text)
        {
            if (text.Length == 0)
                return text;
            var buffer = new char[text.Length * 2];
            int length = LCMapStringEx("zh-CN", LCMAP_SIMPLIFIED_CHINESE, text, text.Length, buffer, buffer.Length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            return length > 0 ? new string(buffer, 0, length) : text;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int LCMapStringEx(string lpLocaleName, uint dwMapFlags, string lpSrcStr, int cchSrc,
            [Out] char[] lpDestStr, int cchDest, IntPtr lpVersionInformation, IntPtr lpReserved, IntPtr sortHandle);
    }
}
