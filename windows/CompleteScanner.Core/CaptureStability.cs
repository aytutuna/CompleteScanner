namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/CaptureStability.swift.

/// <summary>Where the camera's automatic shutter stands (<see cref="CaptureStability"/>).</summary>
public enum CaptureState
{
    /// <summary>No page is seen clearly enough.</summary>
    NoPage,
    /// <summary>A page is seen but moves.</summary>
    Moving,
    /// <summary>The page holds still; the shutter fires when it has for long enough.</summary>
    Steadying,
    /// <summary>The page was taken; waiting for it to go or move before the next.</summary>
    Captured,
}

/// <summary>One video frame's detection, as the stability logic reads it.</summary>
/// <param name="Quad">The page found in the frame, in the frame's pixels; null when none.</param>
/// <param name="Confidence">The detection's confidence, 0...1.</param>
/// <param name="TimestampMs">When the frame was taken, in milliseconds on any steady clock.</param>
/// <param name="FrameWidth">The frame's size in pixels (movement is measured against its diagonal).</param>
/// <param name="FrameHeight"></param>
public readonly record struct CaptureObservation(Quad? Quad, double Confidence, double TimestampMs, int FrameWidth, int FrameHeight);

/// <summary>What the shutter should do after a frame.</summary>
/// <param name="State">The state after the frame.</param>
/// <param name="ShouldCapture">Take the photo now (true on exactly one frame per steady page).</param>
/// <param name="Progress">How far the page is through the steady time, 0...1 (for a ring in the view).</param>
public readonly record struct CaptureDecision(CaptureState State, bool ShouldCapture, double Progress);

/// <summary>The thresholds of <see cref="CaptureStability"/>; the defaults are its constants.</summary>
public sealed record CaptureStabilityOptions
{
    /// <summary>The page must hold still this long before the shutter fires.</summary>
    public double SteadyMs { get; init; } = CaptureStability.SteadyMs;
    /// <summary>To start holding still, no corner moved more than this share of the frame's diagonal since the last frame.</summary>
    public double EnterMovement { get; init; } = CaptureStability.EnterMovement;
    /// <summary>While holding still, no corner strays more than this share from where it was when holding started.</summary>
    public double StayMovement { get; init; } = CaptureStability.StayMovement;
    /// <summary>To start holding still the detection must be at least this confident…</summary>
    public double EnterConfidence { get; init; } = CaptureStability.EnterConfidence;
    /// <summary>…and to stay, at least this.</summary>
    public double StayConfidence { get; init; } = CaptureStability.StayConfidence;
    /// <summary>A page missing from the frames for up to this long is still the same page.</summary>
    public double MaxGapMs { get; init; } = CaptureStability.MaxGapMs;
    /// <summary>After a capture, the next page counts as new once a corner moved this share of the diagonal from the captured page…</summary>
    public double NewPageMovement { get; init; } = CaptureStability.NewPageMovement;

    public static CaptureStabilityOptions Default { get; } = new();
}

/// <summary>
/// Decides when the camera may take the page by itself: the page must be seen with confidence
/// for <see cref="SteadyMs"/> with its corners holding still. Hysteresis keeps the decision from
/// flickering: holding still starts when no corner moved more than <see cref="EnterMovement"/>
/// of the diagonal since the previous frame with confidence at least
/// <see cref="EnterConfidence"/>, and lasts while no corner strays more than
/// <see cref="StayMovement"/> from where it was then and the confidence stays at least
/// <see cref="StayConfidence"/>; a page missing for up to <see cref="MaxGapMs"/> is waited for,
/// and the time it was missing does not count as holding still. Once taken, the same page is not
/// taken again: the shutter re-arms when frames without a page span more than
/// <see cref="MaxGapMs"/> (the page has gone) or a corner moved <see cref="NewPageMovement"/> from
/// where it was taken, or when <see cref="Reset"/> is called; a pause between frames alone does
/// not re-arm it. Corners are compared whichever of them a quad names first (<see cref="Movement"/>),
/// so a page turned to where <see cref="Quad.FromCorners"/> names its corners from another edge
/// does not seem to move. Pure logic: the camera feeds it one <see cref="CaptureObservation"/> per
/// analysed frame, in time order.
/// </summary>
public sealed class CaptureStability
{
    public const double SteadyMs = 600;
    public const double EnterMovement = 0.01;
    public const double StayMovement = 0.025;
    public const double EnterConfidence = 0.6;
    public const double StayConfidence = 0.45;
    public const double MaxGapMs = 250;
    public const double NewPageMovement = 0.15;

    private readonly CaptureStabilityOptions _options;
    private Quad? _previous;
    private Quad? _anchor;
    private Quad? _captured;
    private double _steadySince;
    private double _lastSeen = double.NegativeInfinity;
    private bool _missing;

    public CaptureStability(CaptureStabilityOptions? options = null)
    {
        _options = options ?? CaptureStabilityOptions.Default;
    }

    /// <summary>The state after the last frame.</summary>
    public CaptureState State { get; private set; } = CaptureState.NoPage;

    /// <summary>Forget everything (a new document, the user took a photo by hand): the next steady page is taken.</summary>
    public void Reset()
    {
        State = CaptureState.NoPage;
        _previous = null;
        _anchor = null;
        _captured = null;
        _lastSeen = double.NegativeInfinity;
        _missing = false;
    }

    /// <summary>The decision after one more frame.</summary>
    public CaptureDecision Update(CaptureObservation frame)
    {
        var o = _options;
        double diagonal = Math.Sqrt((double)frame.FrameWidth * frame.FrameWidth + (double)frame.FrameHeight * frame.FrameHeight);
        double t = frame.TimestampMs;

        if (frame.Quad is not { } quad)
        {
            if (t - _lastSeen <= o.MaxGapMs)
            {
                // Waiting for the page to come back; the steady time stands still meanwhile.
                _missing = true;
                return new CaptureDecision(State, false, State == CaptureState.Steadying ? Progress(_lastSeen) : 0);
            }
            _previous = null;
            _anchor = null;
            _captured = null;
            _missing = false;
            State = CaptureState.NoPage;
            return new CaptureDecision(State, false, 0);
        }

        bool returning = t - _lastSeen > o.MaxGapMs;
        // Back after frames without it: the time it was missing is not time held still.
        if (_missing && !returning) _steadySince += t - _lastSeen;
        _missing = false;
        _lastSeen = t;
        var previous = _previous;
        _previous = quad;

        if (State == CaptureState.Captured)
        {
            // The page taken stays taken, however long since the last frame, until it moves away.
            if (_captured is { } taken && Movement(quad, taken) < o.NewPageMovement * diagonal)
            {
                return new CaptureDecision(State, false, 1);
            }
            _captured = null;
            State = CaptureState.Moving;
        }
        if (returning)
        {
            _anchor = null;
            State = frame.Confidence >= o.StayConfidence ? CaptureState.Moving : CaptureState.NoPage;
            return new CaptureDecision(State, false, 0);
        }

        if (State == CaptureState.Steadying && _anchor is { } anchor)
        {
            bool stays = frame.Confidence >= o.StayConfidence && Movement(quad, anchor) <= o.StayMovement * diagonal;
            if (stays)
            {
                if (t - _steadySince >= o.SteadyMs)
                {
                    State = CaptureState.Captured;
                    _captured = quad;
                    _anchor = null;
                    return new CaptureDecision(State, true, 1);
                }
                return new CaptureDecision(State, false, Progress(t));
            }
            _anchor = null;
            State = frame.Confidence >= o.StayConfidence ? CaptureState.Moving : CaptureState.NoPage;
            return new CaptureDecision(State, false, 0);
        }

        if (frame.Confidence < o.EnterConfidence)
        {
            State = frame.Confidence >= o.StayConfidence ? CaptureState.Moving : CaptureState.NoPage;
            return new CaptureDecision(State, false, 0);
        }
        if (previous is { } last && Movement(quad, last) <= o.EnterMovement * diagonal)
        {
            State = CaptureState.Steadying;
            _anchor = last;
            _steadySince = t;
            return new CaptureDecision(State, false, 0);
        }
        State = CaptureState.Moving;
        return new CaptureDecision(State, false, 0);
    }

    private double Progress(double t) => Math.Clamp((t - _steadySince) / _options.SteadyMs, 0, 1);

    /// <summary>
    /// How far the page moved from <paramref name="b"/> to <paramref name="a"/>: the largest distance
    /// between their corners, paired from whichever corner of <paramref name="b"/> fits best (the
    /// least over the four ways round), so a quad whose corners are named from another edge is the same.
    /// </summary>
    public static double Movement(Quad a, Quad b)
    {
        double best = double.MaxValue;
        for (int shift = 0; shift < 4; shift++)
        {
            double worst = 0;
            for (int i = 0; i < 4; i++) worst = Math.Max(worst, a[i].DistanceTo(b[i + shift]));
            best = Math.Min(best, worst);
        }
        return best;
    }
}
