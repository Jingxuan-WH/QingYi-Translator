namespace Translator.Core;

/// <summary>A built-in AI service. Every preset speaks the OpenAI-compatible chat-completions protocol.</summary>
/// <param name="BaseUrl">The endpoint is BaseUrl + "/chat/completions".</param>
/// <param name="Hint">One line shown under the provider picker.</param>
/// <param name="ModelHint">Explains the suggested models.</param>
/// <param name="Temperature">Sent unless null. Omitted automatically if the service rejects it.</param>
/// <param name="ExtraBody">JSON object merged into the request, e.g. to switch off "thinking" for faster translations.</param>
public sealed record ProviderPreset(
    string Id,
    LocText DisplayName,
    string BaseUrl,
    string DefaultModel,
    IReadOnlyList<string> SuggestedModels,
    string? KeyUrl,
    LocText Hint,
    LocText ModelHint = default,
    bool RequiresApiKey = true,
    double? Temperature = 0.3,
    string? ExtraBody = null);

public static class ProviderCatalog
{
    public const string DeepSeekId = "DeepSeek";
    public const string CustomId = "Custom";

    public static IReadOnlyList<ProviderPreset> All { get; } =
    [
        new(DeepSeekId, "DeepSeek", "https://api.deepseek.com", "deepseek-flash",
            ["deepseek-flash", "deepseek-v4-pro"],
            "https://platform.deepseek.com/api_keys",
            new("国内直连，价格低，中英翻译质量好", "Low cost and strong at Chinese–English; reachable directly from mainland China"),
            new("deepseek-flash 速度快、价格低，适合日常翻译；deepseek-v4-pro 质量更高，但更慢、更贵。",
                "deepseek-flash is fast and cheap for everyday use; deepseek-v4-pro gives higher quality but is slower and pricier."),
            // DeepSeek's docs recommend 1.3 for translation; thinking is on by default and only adds latency.
            Temperature: 1.3, ExtraBody: """{"thinking":{"type":"disabled"}}"""),

        // Model names, "thinking" switches and temperature rules below were checked against each
        // provider's official docs in September 2026; models change often, so the model field stays editable.
        new("Qwen", new("通义千问（阿里云百炼）", "Qwen (Alibaba Cloud Model Studio)"),
            "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-flash",
            ["qwen-flash", "qwen-plus", "qwen3.8-max"],
            "https://bailian.console.aliyun.com/cn-beijing/model/settings/api-key",
            new("国内直连 · API Key 只能在创建它的地域使用", "Reachable from mainland China · an API key only works in the region where it was created"),
            new("qwen-flash 便宜、速度快；qwen-plus 质量更好；qwen3.8-max 是旗舰模型。",
                "qwen-flash is cheap and fast; qwen-plus is better; qwen3.8-max is the flagship."),
            ExtraBody: """{"enable_thinking":false}"""),

        new("Kimi", new("Kimi（月之暗面）", "Kimi (Moonshot AI)"), "https://api.moonshot.cn/v1", "kimi-k2.6",
            ["kimi-k2.6", "kimi-k3"],
            "https://platform.kimi.com/console/api-keys",
            new("国内直连", "Reachable from mainland China"),
            new("kimi-k2.6 可以关闭思考，速度较快；kimi-k3 质量更高，但总会先思考，较慢。",
                "kimi-k2.6 can skip thinking and is faster; kimi-k3 is better but always thinks first, so it is slower."),
            // Kimi fixes the temperature and rejects any value that is sent.
            Temperature: null, ExtraBody: """{"thinking":{"type":"disabled"}}"""),

        new("Zhipu", new("智谱 GLM", "Zhipu GLM"), "https://open.bigmodel.cn/api/paas/v4", "glm-4.7-flash",
            ["glm-4.7-flash", "glm-4-flash-250414", "glm-5.2"],
            "https://bigmodel.cn/usercenter/proj-mgmt/apikeys",
            new("国内直连 · 有免费模型", "Reachable from mainland China · free models available"),
            new("glm-4.7-flash 和 glm-4-flash-250414 免费，适合翻译；glm-5.2 质量更高。",
                "glm-4.7-flash and glm-4-flash-250414 are free and fine for translation; glm-5.2 is better."),
            ExtraBody: """{"thinking":{"type":"disabled"}}"""),

        new("Doubao", new("豆包（火山方舟）", "Doubao (Volcano Engine Ark)"), "https://ark.cn-beijing.volces.com/api/v3",
            "doubao-seed-2-0-mini-260428",
            ["doubao-seed-2-0-mini-260428", "doubao-seed-2-1-lite-260915", "doubao-seed-2-1-pro-260628"],
            "https://ark.volcengine.com/region:cn-beijing/apiKey",
            new("国内直连 · 需要先在火山方舟控制台“开通管理”里开通所用模型",
                "Reachable from mainland China · activate the model under “开通管理” in the Ark console first"),
            new("mini 最便宜；lite 均衡；pro 质量最高。", "mini is the cheapest; lite is balanced; pro gives the best quality."),
            ExtraBody: """{"thinking":{"type":"disabled"}}"""),

        new("SiliconFlow", new("硅基流动 SiliconFlow", "SiliconFlow"), "https://api.siliconflow.cn/v1", "Qwen/Qwen3-30B-A3B-Instruct-2507",
            ["Qwen/Qwen3-30B-A3B-Instruct-2507", "deepseek-ai/DeepSeek-V3.2", "tencent/Hunyuan-MT-7B"],
            "https://cloud.siliconflow.cn/account/ak",
            new("国内直连 · 汇集多家开源模型，部分免费；账号需要实名认证",
                "Reachable from mainland China · many open models, some free; requires identity verification"),
            new("Qwen3-30B 速度快；DeepSeek-V3.2 质量高；Hunyuan-MT-7B 是免费的专用翻译模型。",
                "Qwen3-30B is fast; DeepSeek-V3.2 is high quality; Hunyuan-MT-7B is a free dedicated translation model."),
            ExtraBody: """{"enable_thinking":false}"""),

        new("Hunyuan", new("腾讯混元", "Tencent Hunyuan"), "https://tokenhub.tencentmaas.com/v1", "hy3",
            ["hy3", "hy-mt2-lite", "hy-mt2-pro"],
            "https://console.cloud.tencent.com/tokenhub/apikey",
            new("国内直连 · 通过腾讯云 TokenHub 调用，需要先开通所用模型",
                "Reachable from mainland China · called through Tencent Cloud TokenHub; activate the model first"),
            new("hy3 是通用模型；hy-mt2 系列是腾讯的专用翻译模型。",
                "hy3 is general-purpose; the hy-mt2 models are Tencent’s dedicated translation models."),
            ExtraBody: """{"thinking":{"type":"disabled"}}"""),

        new("Qianfan", new("百度千帆（文心）", "Baidu Qianfan (ERNIE)"), "https://qianfan.baidubce.com/v2", "ernie-4.5-turbo-32k",
            ["ernie-4.5-turbo-32k", "ernie-5.1", "deepseek-v3.2"],
            "https://console.bce.baidu.com/iam/#/iam/apikey/list",
            new("国内直连 · 创建 API Key 时选择“千帆ModelBuilder”",
                "Reachable from mainland China · choose “千帆ModelBuilder” when creating the API key"),
            new("ernie-4.5-turbo-32k 速度快；ernie-5.1 是旗舰模型；也可以用千帆上的 deepseek-v3.2。",
                "ernie-4.5-turbo-32k is fast; ernie-5.1 is the flagship; deepseek-v3.2 on Qianfan works too.")),

        new("MiniMax", "MiniMax", "https://api.minimax.cn/v1", "MiniMax-M3",
            ["MiniMax-M3", "MiniMax-M2.7-highspeed"],
            "https://platform.minimax.cn/user-center/basic-information/interface-key",
            new("国内直连", "Reachable from mainland China"),
            new("MiniMax-M3 速度快，可以关闭思考。", "MiniMax-M3 is fast and can skip thinking."),
            Temperature: null, ExtraBody: """{"thinking":{"type":"disabled"}}"""),

        new("OpenAI", "OpenAI", "https://api.openai.com/v1", "gpt-6-luna",
            ["gpt-6-luna", "gpt-5.4-mini", "gpt-6-sol"],
            "https://platform.openai.com/api-keys",
            new("需要能访问 OpenAI 的网络环境", "Requires a network that can reach OpenAI"),
            new("gpt-6-luna 最便宜、速度快；gpt-5.4-mini 同样便宜；gpt-6-sol 质量最高，价格也最高。",
                "gpt-6-luna is the cheapest and fast; gpt-5.4-mini is also cheap; gpt-6-sol has the best quality and the highest price."),
            // GPT-6 models reason by default and then reject temperature; "none" keeps translations fast.
            Temperature: null, ExtraBody: """{"reasoning_effort":"none"}"""),

        new("Gemini", "Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-3.5-flash-lite",
            ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.8-flash"],
            "https://aistudio.google.com/apikey",
            new("需要能访问 Google 服务的网络环境", "Requires a network that can reach Google services"),
            new("Flash-Lite 系列便宜、速度快，默认只做很少的思考；gemini-3.8-flash 质量更高。",
                "The Flash-Lite models are cheap and fast and think very little by default; gemini-3.8-flash is better."),
            // Google recommends leaving Gemini 3's temperature at its default.
            Temperature: null),

        new("OpenRouter", "OpenRouter", "https://openrouter.ai/api/v1", "google/gemini-3.5-flash-lite",
            ["google/gemini-3.5-flash-lite", "openai/gpt-6-luna", "openai/gpt-6-sol"],
            "https://openrouter.ai/settings/keys",
            new("一个 Key 调用多家的模型；需要能访问国外网站", "One key for models from many vendors; requires access to sites outside mainland China"),
            new("模型名格式为“厂商/模型”，全部模型可在 OpenRouter 官网查看。",
                "Model names look like “vendor/model”; the full list is on the OpenRouter website."),
            Temperature: null),

        new("Ollama", new("Ollama（本地模型）", "Ollama (local models)"), "http://localhost:11434/v1", "qwen3.5:4b",
            ["qwen3.5:4b", "qwen3.5:9b", "gemma3:4b"],
            null,
            new("在本机运行：免费、离线、文字不出电脑。需先安装 Ollama 并下载模型，例如 ollama pull qwen3.5:4b",
                "Runs on your computer: free, offline, and your text never leaves it. Install Ollama and pull a model first, e.g. ollama pull qwen3.5:4b"),
            new("qwen3.5 中英翻译效果好，显存小选 4b、大一些选 9b；gemma3:4b 不做思考，速度快。",
                "qwen3.5 translates Chinese and English well: 4b for small GPUs, 9b with more memory; gemma3:4b doesn’t think and is fast."),
            RequiresApiKey: false, ExtraBody: """{"reasoning_effort":"none"}"""),

        new(CustomId, new("自定义（OpenAI 兼容接口）", "Custom (OpenAI-compatible)"), "", "", [], null,
            new("任何兼容 OpenAI 接口格式的服务，填写接口地址和模型名即可",
                "Any service with an OpenAI-compatible API: enter its base URL and model name"),
            new("填写服务商提供的模型名称。", "Enter the model name given by your provider.")),
    ];

    public static ProviderPreset Get(string id) =>
        All.FirstOrDefault(preset => preset.Id == id) ?? All.First(preset => preset.Id == CustomId);
}
