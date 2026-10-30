using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/CaptureStabilityTests.swift: the same scripted frame sequences.

public class CaptureStabilityTests
{
    private const int FrameWidth = 1000, FrameHeight = 750; // diagonal 1250: 1 % = 12.5 px
    private const double FrameMs = 33;

    private static readonly Quad Page = new(new PointD(200, 100), new PointD(780, 130), new PointD(800, 650), new PointD(180, 640));

    private static Quad Shifted(Quad q, double dx, double dy) => new(
        new PointD(q.TopLeft.X + dx, q.TopLeft.Y + dy), new PointD(q.TopRight.X + dx, q.TopRight.Y + dy),
        new PointD(q.BottomRight.X + dx, q.BottomRight.Y + dy), new PointD(q.BottomLeft.X + dx, q.BottomLeft.Y + dy));

    private static CaptureObservation Frame(int index, Quad? quad, double confidence = 0.9) =>
        new(quad, confidence, index * FrameMs, FrameWidth, FrameHeight);

    /// <summary>Feeds frames from <paramref name="start"/> on; returns the indices of frames that fired.</summary>
    private static List<int> Run(CaptureStability stability, int start, IEnumerable<(Quad? Quad, double Confidence)> frames, List<CaptureDecision>? log = null)
    {
        var fired = new List<int>();
        int i = start;
        foreach (var (quad, confidence) in frames)
        {
            var decision = stability.Update(Frame(i, quad, confidence));
            log?.Add(decision);
            if (decision.ShouldCapture) fired.Add(i);
            i++;
        }
        return fired;
    }

    /// <summary>The page held with a tremor of ±1 px (0.1 % of the diagonal), <paramref name="count"/> frames.</summary>
    private static IEnumerable<(Quad?, double)> Held(Quad q, int count, double confidence = 0.9)
    {
        for (int i = 0; i < count; i++) yield return (Shifted(q, i % 2 == 0 ? 1 : -1, i % 3 - 1), confidence);
    }

    [Fact]
    public void FiresOnceWhenThePageHoldsStillLongEnough()
    {
        var stability = new CaptureStability();
        var log = new List<CaptureDecision>();
        var fired = Run(stability, 0, Held(Page, 60), log);
        // Steadying starts on frame 1 (33 ms); 600 ms later is frame 20 (660 ms).
        Assert.Equal(new[] { 20 }, fired);
        Assert.Equal(CaptureState.Captured, stability.State);
        Assert.Equal(CaptureState.Moving, log[0].State);
        Assert.Equal(CaptureState.Steadying, log[1].State);
        Assert.True(log[10].Progress > 0.45 && log[10].Progress < 0.6, $"progress {log[10].Progress}");
        for (int i = 2; i < 20; i++) Assert.True(log[i].Progress >= log[i - 1].Progress);
    }

    [Fact]
    public void NeverFiresWhileThePageMoves()
    {
        var stability = new CaptureStability();
        // 20 px per frame (1.6 % of the diagonal) for 3 s.
        var frames = Enumerable.Range(0, 90).Select(i => ((Quad?)Shifted(Page, 20 * (i % 10), 0), 0.9));
        Assert.Empty(Run(stability, 0, frames));
        Assert.Equal(CaptureState.Moving, stability.State);
    }

    [Fact]
    public void NeverFiresWhenTheDetectionIsUnsure()
    {
        var stability = new CaptureStability();
        Assert.Empty(Run(stability, 0, Held(Page, 60, 0.55)));
        Assert.Equal(CaptureState.Moving, stability.State);
        Assert.Empty(Run(stability, 60, Held(Page, 60, 0.3)));
        Assert.Equal(CaptureState.NoPage, stability.State);
    }

    [Fact]
    public void AConfidenceDipAboveTheStayLevelKeepsSteadying()
    {
        var stability = new CaptureStability();
        var frames = Held(Page, 8).Concat(Held(Page, 8, 0.5)).Concat(Held(Page, 30));
        Assert.Equal(new[] { 20 }, Run(stability, 0, frames));
    }

    [Fact]
    public void AConfidenceDropBelowTheStayLevelStartsOver()
    {
        var stability = new CaptureStability();
        var frames = Held(Page, 8).Concat(Held(Page, 1, 0.4)).Concat(Held(Page, 40));
        // Frame 8 drops out of steadying; frame 9 holds still against it: steady from 9, fires at frame 28.
        Assert.Equal(new[] { 28 }, Run(stability, 0, frames));
    }

    [Fact]
    public void SmallDriftIsToleratedButAJumpStartsOver()
    {
        var drift = new CaptureStability();
        // Drifting 1 px per frame: after 20 frames the page is 20 px (1.6 %) from where it was, within the 2.5 % to stay.
        var slow = Enumerable.Range(0, 40).Select(i => ((Quad?)Shifted(Page, i, 0), 0.9));
        Assert.Equal(new[] { 20 }, Run(drift, 0, slow));

        var jump = new CaptureStability();
        // A jump of 35 px (2.8 %) from where holding started on frame 10 starts over: steady from 11, fires at frame 30.
        var frames = Held(Page, 10).Concat(Held(Shifted(Page, 35, 0), 40));
        Assert.Equal(new[] { 30 }, Run(jump, 0, frames));
    }

    [Fact]
    public void AShortDropoutIsBridgedAndALongOneStartsOver()
    {
        var bridged = new CaptureStability();
        var gap = Held(Page, 8).Concat(Enumerable.Repeat(((Quad?)null, 0.0), 5)).Concat(Held(Page, 30));
        // Five frames missing (165 ms) are waited for, but the time from frame 7 to 13 does not
        // count: steady from 1 to 7 (198 ms) and from 13 on, 600 ms are reached at frame 26.
        Assert.Equal(new[] { 26 }, Run(bridged, 0, gap));

        var lost = new CaptureStability();
        var longGap = Held(Page, 8).Concat(Enumerable.Repeat(((Quad?)null, 0.0), 10)).Concat(Held(Page, 40));
        // Ten frames missing (330 ms): the page is new again from frame 18; steady from 19, fires at 38.
        Assert.Equal(new[] { 38 }, Run(lost, 0, longGap));
    }

    [Fact]
    public void TheTimeThePageIsMissingDoesNotCountAsHoldingStill()
    {
        var stability = new CaptureStability();
        var log = new List<CaptureDecision>();
        // Steady from frame 1 (33 ms), last seen at frame 13 (429 ms), a hand over it until frame 20
        // (660 ms, 231 ms later): 396 ms were held still, 204 more are needed after it comes back.
        var frames = Held(Page, 14).Concat(Enumerable.Repeat(((Quad?)null, 0.0), 6)).Concat(Held(Page, 30));
        Assert.Equal(new[] { 27 }, Run(stability, 0, frames, log));
        for (int i = 14; i < 20; i++)
        {
            Assert.Equal(CaptureState.Steadying, log[i].State);
            Assert.Equal(log[13].Progress, log[i].Progress);
        }
        Assert.True(log[20].Progress <= log[13].Progress, $"progress {log[20].Progress} after the gap, {log[13].Progress} before");
    }

    [Fact]
    public void ThePageIsTheSameWhicheverCornerItsQuadNamesFirst()
    {
        // The same outline named from its top edge and from its right edge, frame by frame.
        var renamed = new Quad(Page.TopRight, Page.BottomRight, Page.BottomLeft, Page.TopLeft);
        Assert.True(Page.MaxCornerDistance(renamed) > 500);
        Assert.Equal(0, CaptureStability.Movement(Page, renamed));
        var stability = new CaptureStability();
        var frames = Held(Page, 120).Select((f, i) => i % 2 == 0 ? f : ((Quad?)new Quad(f.Item1!.Value.TopRight,
            f.Item1!.Value.BottomRight, f.Item1!.Value.BottomLeft, f.Item1!.Value.TopLeft), f.Item2));
        Assert.Equal(new[] { 20 }, Run(stability, 0, frames));
        Assert.Equal(CaptureState.Captured, stability.State);
    }

    [Fact]
    public void ASheetTurnedWhereItsCornersAreRenamedIsStillHeldStill()
    {
        // An A4 sheet (420 × 594 px) turned 54.6° and 54.8°: on either side of the angle where its
        // two upper edges' midpoints are equally high, so FromCorners starts from different corners.
        static Quad Turned(double degrees)
        {
            double a = degrees * Math.PI / 180, c = Math.Cos(a), s = Math.Sin(a);
            var corners = new List<PointD>();
            foreach (var (u, v) in new[] { (-210.0, -297.0), (210.0, -297.0), (210.0, 297.0), (-210.0, 297.0) })
            {
                corners.Add(new PointD(500 + u * c - v * s, 375 + u * s + v * c));
            }
            return Quad.FromCorners(corners);
        }
        var a = Turned(54.6);
        var b = Turned(54.8);
        Assert.True(a.MaxCornerDistance(b) > 200, $"the names did not change: {a} {b}");
        Assert.True(CaptureStability.Movement(a, b) < 3, $"movement {CaptureStability.Movement(a, b)}");
        var stability = new CaptureStability();
        var frames = Enumerable.Range(0, 61).Select(i => ((Quad?)(i % 2 == 0 ? a : b), 0.9));
        Assert.Equal(new[] { 20 }, Run(stability, 0, frames));
    }

    [Fact]
    public void APauseBetweenFramesDoesNotTakeTheSamePageAgain()
    {
        // A 300 ms pause in the frames right after the shutter fired (the photo being taken), the page
        // still there: it stays taken. Laid 200 px aside afterwards, the next page is taken.
        var stability = new CaptureStability();
        var fired = new List<int>();
        var frames = Held(Page, 61).Concat(Held(Shifted(Page, 200, 0), 40)).ToList();
        for (int i = 0; i < frames.Count; i++)
        {
            double t = i * FrameMs + (i > 20 ? 300 : 0);
            var decision = stability.Update(new CaptureObservation(frames[i].Item1, frames[i].Item2, t, FrameWidth, FrameHeight));
            if (decision.ShouldCapture) fired.Add(i);
        }
        Assert.Equal(new[] { 20, 81 }, fired);
    }

    [Fact]
    public void TheSamePageIsNotTakenTwice()
    {
        var stability = new CaptureStability();
        Assert.Equal(new[] { 20 }, Run(stability, 0, Held(Page, 120)));
        Assert.Equal(CaptureState.Captured, stability.State);
    }

    [Fact]
    public void TheNextPageIsTakenAfterThePageLeavesOrMoves()
    {
        var removed = new CaptureStability();
        var frames = Held(Page, 30).Concat(Enumerable.Repeat(((Quad?)null, 0.0), 10)).Concat(Held(Page, 40));
        // Captured at 20; gone from 30 to 39; back at 40, steady from 41, fires at 60.
        Assert.Equal(new[] { 20, 60 }, Run(removed, 0, frames));

        var moved = new CaptureStability();
        // The next page laid 200 px (16 %) aside: re-armed at 30, steady from 31, fires at 50.
        var next = Held(Page, 30).Concat(Held(Shifted(Page, 200, 0), 40));
        Assert.Equal(new[] { 20, 50 }, Run(moved, 0, next));
    }

    [Fact]
    public void ResetArmsTheShutterAgain()
    {
        var stability = new CaptureStability();
        Assert.Equal(new[] { 20 }, Run(stability, 0, Held(Page, 30)));
        stability.Reset();
        Assert.Equal(CaptureState.NoPage, stability.State);
        // After a reset the next frame is a page seen again: steady from 31, fires at 50.
        Assert.Equal(new[] { 50 }, Run(stability, 30, Held(Page, 30)));
    }

    /// <summary>Feeds the frames from <paramref name="start"/> on with these readings; returns the indices that fired.</summary>
    private static List<int> RunWithReadings(CaptureStability stability, int start, IEnumerable<(Quad?, double)> frames,
                                             double? sharpness, double? brightness, List<CaptureDecision>? log = null)
    {
        var fired = new List<int>();
        int i = start;
        foreach (var (quad, confidence) in frames)
        {
            var decision = stability.Update(Frame(i, quad, confidence) with { Sharpness = sharpness, Brightness = brightness });
            log?.Add(decision);
            if (decision.ShouldCapture) fired.Add(i);
            i++;
        }
        return fired;
    }

    [Fact]
    public void AHeldPageWaitsForASharpFrame()
    {
        var stability = new CaptureStability();
        var log = new List<CaptureDecision>();
        // Blurred (the camera still focusing) for 40 frames: held still long enough from frame 20, never taken.
        Assert.Empty(RunWithReadings(stability, 0, Held(Page, 40), 10, 180, log));
        for (int i = 20; i < 40; i++)
        {
            Assert.Equal(CaptureState.Steadying, log[i].State);
            Assert.Equal(1, log[i].Progress);
            Assert.Equal(CaptureQuality.Blurry, log[i].Quality);
        }
        // The first sharp frame is taken, and only once.
        Assert.Equal(new[] { 40 }, RunWithReadings(stability, 40, Held(Page, 30), 400, 180, log));
        Assert.Equal(CaptureQuality.Good, log[40].Quality);
        Assert.Equal(CaptureState.Captured, stability.State);
    }

    [Fact]
    public void AHeldPageWaitsForLight()
    {
        var stability = new CaptureStability();
        var log = new List<CaptureDecision>();
        Assert.Empty(RunWithReadings(stability, 0, Held(Page, 30), 400, 20, log));
        Assert.Equal(CaptureQuality.Dark, log[29].Quality);
        Assert.Equal(CaptureState.Steadying, log[29].State);
        Assert.Equal(new[] { 30 }, RunWithReadings(stability, 30, Held(Page, 10), 400, 120));
        // Moving frames are judged too, so the screen can say why before the page holds still.
        var moving = new CaptureStability();
        var decision = moving.Update(Frame(0, Page) with { Sharpness = 400, Brightness = 20 });
        Assert.Equal(CaptureQuality.Dark, decision.Quality);
        Assert.Equal(CaptureState.Moving, decision.State);
    }

    [Fact]
    public void TheReadingsAreJudgedDarkFirst()
    {
        Assert.Equal(40, CaptureStability.MinSharpness);
        Assert.Equal(50, CaptureStability.MinBrightness);
        Assert.Equal(CaptureQuality.Dark, CaptureStability.Judge(10, 20));
        Assert.Equal(CaptureQuality.Blurry, CaptureStability.Judge(10, 120));
        Assert.Equal(CaptureQuality.Good, CaptureStability.Judge(40, 50));
        Assert.Equal(CaptureQuality.Blurry, CaptureStability.Judge(39.99, 50));
        Assert.Equal(CaptureQuality.Dark, CaptureStability.Judge(400, 49.99));
        Assert.Equal(CaptureQuality.Good, CaptureStability.Judge(null, null));
        Assert.Equal(CaptureQuality.Good, CaptureStability.Judge(null, 120));
        var strict = new CaptureStabilityOptions { MinSharpness = 500, MinBrightness = 10 };
        Assert.Equal(CaptureQuality.Blurry, CaptureStability.Judge(400, 20, strict));
        // Frames without readings are taken as before.
        Assert.Equal(new[] { 20 }, RunWithReadings(new CaptureStability(), 0, Held(Page, 30), null, null));
    }

    [Fact]
    public void APhotoTakenByHandCountsAsTaken()
    {
        var stability = new CaptureStability();
        // Nothing seen yet: nothing to mark.
        stability.MarkCaptured();
        Assert.Equal(CaptureState.NoPage, stability.State);
        // Held still for ten frames, then the shutter pressed by hand: the same page is not taken again…
        Assert.Empty(Run(stability, 0, Held(Page, 10)));
        stability.MarkCaptured();
        Assert.Equal(CaptureState.Captured, stability.State);
        Assert.Empty(Run(stability, 10, Held(Page, 60)));
        // …the next page laid 200 px aside is: re-armed at 70, steady from 71, fires at 90.
        Assert.Equal(new[] { 90 }, Run(stability, 70, Held(Shifted(Page, 200, 0), 40)));
    }

    [Fact]
    public void APauseIsNeitherTimeMissingNorTimeHeldStill()
    {
        // Taken at frame 20; the camera stops (the corner editor) after frame 29 and starts again at frame 200.
        var stability = new CaptureStability();
        Assert.Equal(new[] { 20 }, Run(stability, 0, Held(Page, 30)));
        stability.Resume(200 * FrameMs);
        // The first frame back misses the page (the exposure still settling): the page taken stays taken…
        Assert.Equal(CaptureState.Captured, stability.Update(Frame(200, null)).State);
        // …and the same page held still again is not taken again.
        Assert.Empty(Run(stability, 201, Held(Page, 60)));
        Assert.Equal(CaptureState.Captured, stability.State);

        // Without Resume the pause counts as the page gone, and the same page is taken twice.
        var unresumed = new CaptureStability();
        Assert.Equal(new[] { 20 }, Run(unresumed, 0, Held(Page, 30)));
        Assert.Equal(CaptureState.NoPage, unresumed.Update(Frame(200, null)).State);
        Assert.Equal(new[] { 221 }, Run(unresumed, 201, Held(Page, 60)));

        // A page that went meanwhile is gone once frames without it span MaxGapMs, as ever.
        var gone = new CaptureStability();
        Run(gone, 0, Held(Page, 30));
        gone.Resume(200 * FrameMs);
        var log = new List<CaptureDecision>();
        Run(gone, 200, Enumerable.Repeat(((Quad?)null, 0.0), 9), log);
        Assert.Equal(CaptureState.Captured, log[7].State);
        Assert.Equal(CaptureState.NoPage, log[8].State);

        // A page holding still when the camera stopped goes on from where it was: steady from 1, 264 ms held
        // by frame 9, so 600 ms are reached at frame 311, not at once.
        var steady = new CaptureStability();
        Assert.Empty(Run(steady, 0, Held(Page, 10)));
        steady.Resume(300 * FrameMs);
        Assert.Equal(new[] { 311 }, Run(steady, 300, Held(Page, 20)));

        // Nothing to resume before any frame.
        var fresh = new CaptureStability();
        fresh.Resume(1000);
        Assert.Equal(new[] { 20 }, Run(fresh, 0, Held(Page, 30)));
    }
}
