using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Tests for ResolutionList, the pure-function port of ICScannerBackend.resolutionList(for:)
// (the Swift suite has no counterpart: the Swift function is private to the backend).

public class ResolutionListTests
{
    [Fact]
    public void PreferredListIsUsedVerbatim()
    {
        // Even values above the native resolution: the driver's preferred list IS the truth.
        var list = ResolutionList.Build(preferred: [300, 150, 1200, 150],
                                        supported: ResolutionList.ExpandRange(50, 4800, 1),
                                        nativeResolution: 600);
        Assert.Equal([150, 300, 1200], list);
    }

    [Fact]
    public void EmptyPreferredFallsBackToSupported()
    {
        var list = ResolutionList.Build(preferred: [], supported: [600, 300, 150], nativeResolution: 0);
        Assert.Equal([150, 300, 600], list);
    }

    [Fact]
    public void SmallDiscreteSetIsUsedAsIs()
    {
        var list = ResolutionList.Build(null, [75, 2400, 150, 300, 600, 1200, 300], 0);
        Assert.Equal([75, 150, 300, 600, 1200, 2400], list);
    }

    [Fact]
    public void ValuesAboveNativeAreDropped()
    {
        var list = ResolutionList.Build(null, [75, 150, 300, 600, 1200, 2400, 4800], 1200);
        Assert.Equal([75, 150, 300, 600, 1200], list);
    }

    [Fact]
    public void NativeIsAddedOnlyWhenSupported()
    {
        Assert.Equal([100, 300], ResolutionList.Build(null, [100, 300, 600], 400));
        // A thinned range keeps the native resolution even though it is not on the ladder.
        var list = ResolutionList.Build(null, ResolutionList.ExpandRange(50, 4800, 1), 1000);
        Assert.Equal([50, 72, 75, 100, 150, 200, 240, 300, 400, 600, 800, 1000], list);
    }

    [Fact]
    public void LargeRangeIsThinnedToLadderPlusMinAndMax()
    {
        var list = ResolutionList.Build(null, ResolutionList.ExpandRange(60, 2000, 1), 0);
        Assert.Equal([60, 72, 75, 100, 150, 200, 240, 300, 400, 600, 800, 1200, 1600, 2000], list);
    }

    [Fact]
    public void LadderValuesMustActuallyBeSupported()
    {
        // Step 25: 72 and 240 are not reachable, so they are not offered.
        var list = ResolutionList.Build(null, ResolutionList.ExpandRange(50, 4800, 25), 0);
        Assert.Equal([50, 75, 100, 150, 200, 300, 400, 600, 800, 1200, 1600, 2400, 3200, 4800], list);
    }

    [Fact]
    public void SixtyFourValuesAreDiscreteSixtyFiveAreARange()
    {
        var sixtyFour = Enumerable.Range(1, 64).Select(i => i * 10).ToList();
        Assert.Equal(sixtyFour, ResolutionList.Build(null, sixtyFour, 0));

        var sixtyFive = Enumerable.Range(1, 65).Select(i => i * 10).ToList();
        Assert.Equal([10, 50, 100, 150, 200, 240, 300, 400, 600, 650],
                     ResolutionList.Build(null, sixtyFive, 0));
    }

    [Fact]
    public void NothingSupportedYieldsEmptyList()
    {
        Assert.Empty(ResolutionList.Build(null, [], 600));
        Assert.Empty(ResolutionList.Build([], [], 0));
    }

    [Fact]
    public void ExpandRangeHonorsStep()
    {
        Assert.Equal([75, 150, 225, 300], ResolutionList.ExpandRange(75, 300, 75));
        Assert.Equal([75, 150, 225], ResolutionList.ExpandRange(75, 299, 75));
        Assert.Equal([1, 2, 3], ResolutionList.ExpandRange(1, 3, 0)); // non-positive step = 1
        Assert.Empty(ResolutionList.ExpandRange(300, 75, 1));
    }

    [Fact]
    public void HostileHugeRangeIsBoundedAndThinned()
    {
        // A device claiming 1...int.MaxValue in steps of 1 must not enumerate 2^31 values.
        var started = System.Diagnostics.Stopwatch.StartNew();
        Assert.Equal(ResolutionList.MaxRangeDpi, ResolutionList.ExpandRange(1, int.MaxValue, 1).Count());
        Assert.Equal(ResolutionList.MaxRangeDpi, ResolutionList.ExpandRange(int.MinValue, int.MaxValue, 1).Count());
        var list = ResolutionList.Build(null, ResolutionList.ExpandRange(50, int.MaxValue, 1), 0);
        Assert.Equal([50, .. ResolutionList.StandardLadder.Where(dpi => dpi > 50), ResolutionList.MaxRangeDpi], list);
        Assert.True(started.Elapsed < TimeSpan.FromSeconds(10), $"took {started.Elapsed}");
        // A known optical resolution still caps it as usual.
        Assert.Equal([50, 72, 75, 100, 150, 200, 240, 300, 400, 600, 800, 1200],
                     ResolutionList.Build(null, ResolutionList.ExpandRange(50, int.MaxValue, 1), 1200));
        // A huge step stays on its lattice without overflowing.
        Assert.Equal([100], ResolutionList.ExpandRange(100, int.MaxValue, int.MaxValue));
    }

    [Fact]
    public void NonPositiveResolutionsAreDropped()
    {
        Assert.Equal([5, 10], ResolutionList.ExpandRange(-5, 10, 5)); // stays on the -5 + 5n lattice
        Assert.Equal([1, 2], ResolutionList.ExpandRange(0, 2, 1));
        Assert.Equal([3, 7], ResolutionList.ExpandRange(-9, 8, 4));
        Assert.Empty(ResolutionList.ExpandRange(-10, 0, 1));
        Assert.Equal([150, 300], ResolutionList.Build(null, [0, -300, 150, 300], 0));
        Assert.Equal([300], ResolutionList.Build([-1, 0, 300], [75, 150], 0));
        // A preferred list with nothing usable falls back to the supported values.
        Assert.Equal([75, 150], ResolutionList.Build([0, -75], [75, 150, -1], 0));
        Assert.Empty(ResolutionList.Build(null, [0, -1], 0));
    }

    // MARK: - FromBounds (the Windows Scan connection reports only min, max and optical)

    [Fact]
    public void FromBoundsIsTheLadderBetweenTheBoundsCappedAtOptical()
    {
        Assert.Equal([50, 72, 75, 100, 150, 200, 240, 300, 400, 600, 800, 1200], ResolutionList.FromBounds(50, 4800, 1200));
        // Bounds off the ladder are offered too.
        Assert.Equal([60, 72, 75, 100, 150, 200, 240, 300, 400, 600, 700], ResolutionList.FromBounds(60, 700, 0));
        // An optical resolution between the bounds but off the ladder is a real value.
        Assert.Equal([100, 150, 200, 240, 300, 400, 500], ResolutionList.FromBounds(100, 1200, 500));
        // An optical resolution outside the bounds caps nothing it cannot reach.
        Assert.Equal([100, 150, 200, 240, 300], ResolutionList.FromBounds(100, 300, 600));
    }

    [Fact]
    public void FromBoundsOfASingleValueOrSwappedBounds()
    {
        Assert.Equal([300], ResolutionList.FromBounds(300, 300, 300));
        Assert.Equal([150, 200, 240, 300], ResolutionList.FromBounds(300, 150, 0));
    }

    [Fact]
    public void FromBoundsWithUnknownValues()
    {
        // No minimum: the ladder from its lowest value.
        Assert.Equal([50, 72, 75, 100, 150, 200], ResolutionList.FromBounds(0, 200, 0));
        Assert.Equal([50, 72, 75, 100, 150, 200], ResolutionList.FromBounds(-10, 200, -1));
        Assert.Equal([10], ResolutionList.FromBounds(-10, 50, 10));
        Assert.Empty(ResolutionList.FromBounds(0, 0, 0));
        Assert.Empty(ResolutionList.FromBounds(-300, -100, 0));
        // No maximum (its read failed) is unknown, not a cap at the minimum.
        Assert.Empty(ResolutionList.FromBounds(50, 0, 0));
        Assert.Empty(ResolutionList.FromBounds(300, -1, 600));
    }
}
