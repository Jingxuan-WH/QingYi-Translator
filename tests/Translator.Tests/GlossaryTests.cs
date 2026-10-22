using Translator.Core;
using Xunit;

namespace Translator.Tests;

public class GlossaryTests
{
    [Fact]
    public void ContainsTermNeedsWordStart()
    {
        Assert.True(Glossary.ContainsTerm("We use AI models", "AI"));
        Assert.False(Glossary.ContainsTerm("Send an email", "AI"));
        Assert.True(Glossary.ContainsTerm("The power flows here", "power flow"));
        Assert.True(Glossary.ContainsTerm("计算潮流分布", "潮流"));
    }

    [Fact]
    public void ParseReadsCommonFormats()
    {
        var entries = Glossary.Parse("术语\t译法\npower flow\t潮流\ndroop control = 下垂控制\ninverter -> 逆变器\nno separator");
        Assert.Equal(["power flow", "droop control", "inverter"], entries.Select(entry => entry.Source));
        Assert.Equal("下垂控制", entries[1].Target);
    }
}
