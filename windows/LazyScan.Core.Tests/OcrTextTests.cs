using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/LazyScanTests/OCRTextTests.swift: the same cases.

/// <summary>Lines placed on a 1000 × 1000 page by their top-left corner, as a person reads the page.</summary>
internal static class OcrFixtures
{
    public const double PageSize = 1000;

    /// <summary>A line at (<paramref name="left"/>, <paramref name="top"/>), origin top-left, in page units.</summary>
    public static OcrLine Line(string text, double left, double top, double width, double height = 20,
                               float confidence = 1f) =>
        new(text, new RectD(left / PageSize, 1 - (top + height) / PageSize, width / PageSize, height / PageSize),
            confidence);

    public static OcrPage Page(params OcrLine[] lines) => new(lines, PageSize, PageSize);

    public static List<string> Texts(IEnumerable<OcrLine> lines) => lines.Select(l => l.Text).ToList();

    public static List<string> Ordered(params OcrLine[] lines) =>
        Texts(OcrText.ReadingOrder(lines, PageSize, PageSize));
}

public class OcrTextTests
{
    private static OcrLine L(string text, double left, double top, double width, double height = 20) =>
        OcrFixtures.Line(text, left, top, width, height);

    [Fact]
    public void ReadingOrder_TwoColumns_LeftColumnFirst()
    {
        // The engine reads across the gutter, row by row.
        var ordered = OcrFixtures.Ordered(
            L("left 1", 50, 100, 400), L("right 1", 550, 100, 400),
            L("left 2", 50, 140, 400), L("right 2", 550, 140, 400),
            L("left 3", 50, 180, 380), L("right 3", 550, 180, 300));
        Assert.Equal(["left 1", "left 2", "left 3", "right 1", "right 2", "right 3"], ordered);
    }

    [Fact]
    public void ReadingOrder_HeadingAcrossColumns_ComesFirst_ThenEachColumn()
    {
        var ordered = OcrFixtures.Ordered(
            L("right 1", 550, 100, 400), L("left 1", 50, 100, 400),
            L("right 2", 550, 140, 400), L("left 2", 50, 140, 400),
            L("THE HEADING", 200, 40, 600, 30),
            L("footer across the page", 50, 300, 900));
        Assert.Equal(["THE HEADING", "left 1", "left 2", "right 1", "right 2", "footer across the page"], ordered);
    }

    [Fact]
    public void ReadingOrder_SidebarBesideALetterhead_IsReadBeforeIt()
    {
        // A list of names on the left, small print on the right, side by side and interleaved.
        var ordered = OcrFixtures.Ordered(
            L("CLARA BARTON.", 90, 130, 100, 6), L("FOR THE RELIEF OF SUFFERING", 270, 107, 620, 9),
            L("PRESIDENT.", 110, 138, 60, 4), L("EXTENT. THE ORGANIZATION", 310, 117, 540, 8),
            L("MRS. JOHN A. LOGAN.", 90, 148, 130, 5), L("AT GENEVA, SWITZERLAND", 350, 127, 460, 9),
            L("VICE-PRESIDENT.", 110, 156, 80, 4), L("STATES GAVE ITS ADHESION", 390, 137, 390, 9),
            L("August 31, 1903.", 660, 225, 180, 13));
        Assert.Equal(["CLARA BARTON.", "PRESIDENT.", "MRS. JOHN A. LOGAN.", "VICE-PRESIDENT.",
                      "FOR THE RELIEF OF SUFFERING", "EXTENT. THE ORGANIZATION", "AT GENEVA, SWITZERLAND",
                      "STATES GAVE ITS ADHESION", "August 31, 1903."], ordered);
    }

    [Fact]
    public void ReadingOrder_PiecesOfOneRow_JoinedWithASpace_OrATabAcrossAWideGap()
    {
        var ordered = OcrFixtures.Ordered(
            L("Charles G. Washburn,", 280, 100, 210), L("Honorable", 165, 101, 100),
            L("Green Sea Turtle 25", 70, 200, 185), L("Vegetable with Macaroni 10", 630, 199, 255),
            L("August", 665, 300, 64), L("31,", 743, 300, 29), L("1903.", 788, 299, 51));
        Assert.Equal(["Honorable Charles G. Washburn,", "Green Sea Turtle 25\tVegetable with Macaroni 10",
                      "August 31, 1903."], ordered);
    }

    [Fact]
    public void ReadingOrder_HeadingJustAboveARow_ComesFirst()
    {
        // A menu: a section heading, a row of two dishes right under it, then one in the middle.
        // A lone line beside the others is not a column.
        var ordered = OcrFixtures.Ordered(
            L("Green Sea Turtle 25", 71, 325.5, 184, 8.5), L("SOUPS", 440, 318, 76, 7),
            L("Consomme Financiere 10", 390, 336, 227, 8), L("Vegetable with Macaroni 10", 629, 325.5, 257, 10.5));
        Assert.Equal(["SOUPS", "Green Sea Turtle 25\tVegetable with Macaroni 10", "Consomme Financiere 10"], ordered);
    }

    [Fact]
    public void ReadingOrder_JoinedRow_TakesBothBoxesAndTheLowestConfidence()
    {
        var a = OcrFixtures.Line("Honorable", 165, 101, 100, 20, 0.9f);
        var b = OcrFixtures.Line("Washburn,", 280, 100, 210, 22, 0.6f);
        var row = Assert.Single(OcrText.ReadingOrder([b, a], 1000, 1000));
        Assert.Equal("Honorable Washburn,", row.Text);
        Assert.Equal(0.6f, row.Confidence);
        Assert.Equal(0.165, row.BoundingBox.X, 9);
        Assert.Equal(0.49, row.BoundingBox.MaxX, 9);
        Assert.Equal(1 - 0.122, row.BoundingBox.MinY, 9);
        Assert.Equal(1 - 0.100, row.BoundingBox.MaxY, 9);
    }

    [Fact]
    public void ReadingOrder_SlightlyOverlappingLines_StayApart()
    {
        // A slanted page: each line's box reaches into the next one, so there is no gap between
        // them, but they share too little height to be one row.
        var ordered = OcrFixtures.Ordered(
            L("third line", 50, 150, 800, 30), L("first line", 50, 100, 800, 30), L("second line", 50, 125, 800, 30));
        Assert.Equal(["first line", "second line", "third line"], ordered);
    }

    [Fact]
    public void ReadingOrder_DoesNotDependOnTheEnginesOrder()
    {
        var lines = new[]
        {
            L("title", 300, 50, 400, 30), L("a1", 50, 120, 380), L("b1", 560, 120, 380),
            L("a2", 50, 150, 380), L("b2", 560, 150, 380), L("price", 800, 260, 60), L("dish", 50, 261, 200),
        };
        var expected = OcrFixtures.Ordered(lines);
        Assert.Equal(["title", "a1", "a2", "b1", "b2", "dish\tprice"], expected);
        Assert.Equal(expected, OcrFixtures.Ordered(lines.Reverse().ToArray()));
        Assert.Equal(expected, OcrFixtures.Ordered([.. lines.Skip(3), .. lines.Take(3)]));
    }

    [Fact]
    public void ReadingOrder_CleansTheText_AndDropsEmptyLines()
    {
        var ordered = OcrFixtures.Ordered(
            L("  two  words\u0007here ", 50, 100, 300), L("   ", 50, 140, 300), L("", 50, 180, 300),
            L("line\nbreak", 50, 220, 300), new OcrLine("no size", new RectD(0.5, 0.5, 0, 0), 1));
        Assert.Equal(["two words here", "line break"], ordered);
        Assert.Empty(OcrText.ReadingOrder([], 1000, 1000));
    }

    [Fact]
    public void Paragraphs_ClearlyWiderGap_StartsAParagraph()
    {
        var page = OcrFixtures.Page(
            L("First paragraph, line one", 50, 100, 800), L("line two of it.", 50, 126, 300),
            L("Second paragraph starts", 50, 172, 800), L("and ends.", 50, 198, 200));
        var paragraphs = OcrText.Paragraphs(page);
        Assert.Equal(["First paragraph, line one line two of it.", "Second paragraph starts and ends."],
                     paragraphs.Select(p => p.Text));
    }

    [Fact]
    public void Paragraphs_DoubleSpacedLetter_SplitsAtIndentsOnly()
    {
        // Every line the same distance apart; paragraphs start indented (like a typed letter).
        var page = OcrFixtures.Page(
            L("My dear Sir:-", 165, 100, 140, 13),
            L("I am enclosing herewith copy of letter I am forward-", 280, 130, 575, 13),
            L("ing to his Honor the Mayor of Worcester, which will be self", 169, 160, 650, 13),
            L("explanatory when I tell you.", 168, 190, 400, 13),
            L("The purpose of this note is to ask you to receive my", 280, 220, 575, 13),
            L("Secretary, Mr. E. Howe.", 170, 250, 300, 13));
        var paragraphs = OcrText.Paragraphs(page);
        Assert.Equal(["My dear Sir:-",
                      "I am enclosing herewith copy of letter I am forwarding to his Honor the Mayor of Worcester, which will be self explanatory when I tell you.",
                      "The purpose of this note is to ask you to receive my Secretary, Mr. E. Howe."],
                     paragraphs.Select(p => p.Text));
    }

    [Fact]
    public void Paragraphs_NextColumn_AndALeftEdgeFarAway_StartParagraphs()
    {
        var ordered = new[]
        {
            L("left column one", 50, 100, 380), L("left column two", 50, 124, 380),
            L("right column one", 560, 100, 380), L("right column two", 560, 124, 380),
            L("far right", 850, 148, 100),
        };
        var paragraphs = OcrText.Paragraphs(ordered, 1000, 1000);
        Assert.Equal(["left column one left column two", "right column one right column two", "far right"],
                     paragraphs.Select(p => p.Text));
        Assert.Empty(OcrText.Paragraphs([], 1000, 1000));
    }

    [Fact]
    public void Paragraphs_CentredLines_StayTogether_AStaircaseAddressDoesNot()
    {
        var page = OcrFixtures.Page(
            L("THE AMERICAN NATIONAL RED CROSS.", 300, 40, 400, 13),
            L("FOR THE RELIEF OF SUFFERING BY WAR", 280, 58, 440, 9),
            L("OFFICE OF THE PRESIDENT,", 420, 72, 160, 9),
            L("Honorable Charles G. Washburn,", 165, 140, 330, 13),
            L("44 Elm St.,", 277, 175, 118, 13),
            L("Worcester, Mass.", 388, 210, 129, 13),
            L("My dear Sir:-", 166, 245, 143, 13),
            L("I am enclosing herewith copy of letter I am forward-", 279, 280, 576, 13),
            L("ing to his Honor the Mayor of Worcester.", 169, 315, 500, 13));
        Assert.Equal(["THE AMERICAN NATIONAL RED CROSS. FOR THE RELIEF OF SUFFERING BY WAR OFFICE OF THE PRESIDENT,",
                      "Honorable Charles G. Washburn,", "44 Elm St.,", "Worcester, Mass.", "My dear Sir:-",
                      "I am enclosing herewith copy of letter I am forwarding to his Honor the Mayor of Worcester."],
                     OcrText.Paragraphs(page).Select(p => p.Text));
    }

    [Fact]
    public void ParagraphText_AWrappedLineJoinsTheNext_AShortLineKeepsItsBreak()
    {
        Assert.Equal("Mr. Phillip Moen; Mr. Geo. Whitney; Henry A. Marsh.",
                     OcrText.ParagraphText([L("Mr. Phillip Moen; Mr. Geo.", 170, 100, 685), L("Whitney; Henry A. Marsh.", 170, 130, 300)]));
        Assert.Equal("Dear John,\nthis line runs right across the page",
                     OcrText.ParagraphText([L("Dear John,", 50, 100, 150), L("this line runs right across the page", 50, 130, 800)]));
        Assert.Equal("Soup\t4.50\nBread\t1.00",
                     OcrText.ParagraphText([L("Soup\t4.50", 50, 100, 800), L("Bread\t1.00", 50, 130, 800)]));
        Assert.Equal("", OcrText.ParagraphText([]));
    }

    [Fact]
    public void JoinLines_JoinsWordsBrokenOverTwoLines()
    {
        Assert.Equal("I am forwarding it", OcrText.JoinLines(["I am forward-", "ing it"]));
        Assert.Equal("well- Known", OcrText.JoinLines(["well-", "Known"]));
        Assert.Equal("1903- 1904", OcrText.JoinLines(["1903-", "1904"]));
        Assert.Equal("a - b", OcrText.JoinLines(["a -", "b"]));
        Assert.Equal("one two", OcrText.JoinLines(["  one ", "", " two"]));
        Assert.Equal("", OcrText.JoinLines([]));
    }

    [Fact]
    public void PlainText_LinesParagraphsAndPages()
    {
        var first = OcrFixtures.Page(
            L("Title", 400, 50, 200, 30),
            L("First paragraph, line one", 50, 120, 800), L("line two.", 50, 146, 300),
            L("Dish 25", 50, 220, 150), L("Price list", 700, 220, 150));
        var empty = OcrFixtures.Page();
        var last = OcrFixtures.Page(L("The end.", 50, 100, 200));
        Assert.Equal("Title\n\nFirst paragraph, line one\nline two.\n\nDish 25\tPrice list", OcrText.PageText(first));
        Assert.Equal("", OcrText.PageText(empty));
        Assert.Equal("Title\n\nFirst paragraph, line one\nline two.\n\nDish 25\tPrice list\n\n\n\n\n\nThe end.\n",
                     OcrText.PlainText([first, empty, last]));
        Assert.Equal("", OcrText.PlainText([empty, empty]));
        Assert.Equal("", OcrText.PlainText([]));
    }

    [Fact]
    public void OcrPage_SizeInPointsFromPixelsAndDpi()
    {
        var page = OcrPage.Of([], 2550, 3300, 300);
        Assert.Equal((612.0, 792.0), (page.WidthPoints, page.HeightPoints));
        Assert.Equal((2550 * 72.0, 72.0), (OcrPage.Of([], 2550, 1, 0).WidthPoints, OcrPage.Of([], 2550, 1, 0).HeightPoints));
    }
}
