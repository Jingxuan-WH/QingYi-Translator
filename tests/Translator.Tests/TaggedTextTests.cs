using Translator.Core.FileTranslation;
using Xunit;

namespace Translator.Tests;

public class TaggedTextTests
{
    [Fact]
    public void MainFormatStaysUntaggedAndOthersGetOneNumberEach()
    {
        var tagged = TaggedText.Build(
        [
            InlinePiece.Of("The ", 0), InlinePiece.Of("power flow", 1), InlinePiece.Of(" is solved by ", 0),
            InlinePiece.Of("Newton", 2), InlinePiece.Of(" and ", 0), InlinePiece.Of("Raphson", 2), InlinePiece.Object(0), InlinePiece.Of(".", 0),
        ]);
        Assert.Equal(0, tagged.BaseStyle);
        Assert.Equal("The <1>power flow</1> is solved by <2>Newton</2> and <2>Raphson</2><3/>.", tagged.Text);
    }

    [Fact]
    public void SpacesStayOutsideTheTags()
    {
        var tagged = TaggedText.Build([InlinePiece.Of("plain text here", 0), InlinePiece.Of(" bold ", 1), InlinePiece.Of("x", 0)]);
        Assert.Equal("plain text here <1>bold</1> x", tagged.Text);
    }

    [Fact]
    public void ParseRestoresFormatsInTheTranslatedOrder()
    {
        var tagged = TaggedText.Build([InlinePiece.Of("the ", 0), InlinePiece.Of("red", 1), InlinePiece.Of(" car is fast", 0)]);
        var pieces = tagged.Parse("la voiture <1>rouge</1> est rapide");
        Assert.Equal([InlinePiece.Of("la voiture ", 0), InlinePiece.Of("rouge", 1), InlinePiece.Of(" est rapide", 0)], pieces);
    }

    [Fact]
    public void ParseToleratesBrokenAndUnknownTags()
    {
        var tagged = TaggedText.Build([InlinePiece.Of("aaaa ", 0), InlinePiece.Of("bb", 1), InlinePiece.Object(0), InlinePiece.Of(" cc", 0)]);
        Assert.Equal("aaaa <1>bb</1><2/> cc", tagged.Text);
        // Unclosed tag: the rest takes its format. Unknown tag <7>: kept as text. Atom written as a pair: still the atom.
        var pieces = tagged.Parse("x <1>y <7> z<2></2>");
        Assert.Equal([InlinePiece.Of("x ", 0), InlinePiece.Of("y <7> z", 1), InlinePiece.Object(0)], pieces);
        // A closing tag without an opening one is dropped.
        Assert.Equal([InlinePiece.Of("plain", 0)], tagged.Parse("pl</1>ain"));
    }

    [Fact]
    public void StripTagsGivesPlainText() =>
        Assert.Equal("a b c", TaggedText.StripTags("a <1>b</1><2/> c"));

    [Fact]
    public void WhitespaceOnlyPiecesInOtherFormatsAreNotTagged()
    {
        var tagged = TaggedText.Build([InlinePiece.Of("one", 0), InlinePiece.Of(" ", 1), InlinePiece.Of("two", 0)]);
        Assert.Equal("one two", tagged.Text);
        Assert.False(tagged.HasTags);
    }
}
