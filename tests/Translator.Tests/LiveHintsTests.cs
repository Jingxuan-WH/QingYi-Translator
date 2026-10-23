using Translator.Core;
using Xunit;

namespace Translator.Tests;

public class ChinesePunctuationTests
{
    [Theory]
    [InlineData("在电力系统中,储能装置可以平抑新能源发电的波动,提高效率", "在电力系统中，储能装置可以平抑新能源发电的波动，提高效率")]
    [InlineData("你好吗?我很好!", "你好吗？我很好！")]
    [InlineData("注意: 使用 AI, 效果更好; 访问 https://example.com", "注意：使用 AI，效果更好；访问 https://example.com")]
    [InlineData("比例是3:2,总共3,000元", "比例是3:2，总共3,000元")]
    [InlineData("他说 Hello, world 然后走了", "他说 Hello, world 然后走了")]
    [InlineData("已经是全角，不用改。", "已经是全角，不用改。")]
    public void ConvertsMarksOutsideLatinText(string input, string expected) =>
        Assert.Equal(expected, SpeechText.UseChinesePunctuation(input));
}

public class SilenceWatchTests
{
    [Fact]
    public void ReportsOnceAfterContinuousSilence()
    {
        var watch = new SilenceWatch(seconds: 8);
        Assert.False(watch.Update(0, 0));
        Assert.False(watch.Update(0.0001f, 7.9));
        Assert.True(watch.Update(0, 8));
        Assert.False(watch.Update(0, 20)); // only once
    }

    [Fact]
    public void AnySoundEndsTheWatch()
    {
        var watch = new SilenceWatch(seconds: 8);
        Assert.False(watch.Update(0, 0));
        Assert.False(watch.Update(0.01f, 3)); // a quiet room still has some noise
        Assert.False(watch.Update(0, 30));
    }

    [Fact]
    public void ResetStartsOver()
    {
        var watch = new SilenceWatch(seconds: 8);
        watch.Update(0.2f, 0);
        watch.Reset();
        Assert.False(watch.Update(0, 10));
        Assert.True(watch.Update(0, 18));
    }
}
