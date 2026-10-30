using System.Diagnostics;
using System.Net;

namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Escl/EsclRetry.swift: the same rules and tests on both platforms.

/// <summary>
/// How long to keep retrying an eSCL request the device answers with HTTP 503 (busy, or the
/// next page is not ready yet): the wait starts at <see cref="InitialDelay"/>, grows by
/// <see cref="Multiplier"/> up to <see cref="MaxDelay"/>, and retrying stops once another wait
/// would pass <see cref="GiveUpAfter"/> since the first attempt.
/// </summary>
public sealed record EsclRetryPolicy(TimeSpan InitialDelay, double Multiplier, TimeSpan MaxDelay, TimeSpan GiveUpAfter)
{
    public static EsclRetryPolicy Default { get; } =
        new(TimeSpan.FromSeconds(0.5), 1.5, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(60));

    /// <summary>
    /// The wait before retry number <paramref name="retry"/> (0-based). A Retry-After the
    /// device sent replaces the computed wait, kept within [InitialDelay, MaxDelay].
    /// </summary>
    public TimeSpan DelayBefore(int retry, TimeSpan? retryAfter = null)
    {
        if (retryAfter is { } asked)
        {
            return asked < InitialDelay ? InitialDelay : asked > MaxDelay ? MaxDelay : asked;
        }
        double seconds = InitialDelay.TotalSeconds * Math.Pow(Multiplier, Math.Max(0, retry));
        return seconds >= MaxDelay.TotalSeconds ? MaxDelay : TimeSpan.FromSeconds(seconds);
    }
}

public static class EsclRetry
{
    /// <summary>The only status that is retried: 503 Service Unavailable.</summary>
    public static bool IsRetryable(HttpStatusCode status) => status == HttpStatusCode.ServiceUnavailable;

    /// <summary>
    /// Send a request, repeating it while the device answers 503, per <paramref name="policy"/>
    /// (default <see cref="EsclRetryPolicy.Default"/>). Returns the first other response, or
    /// the last 503 once the policy gives up; responses that are retried are disposed.
    /// <paramref name="send"/> must create a fresh request each time. <paramref name="delay"/>
    /// and <paramref name="elapsed"/> (time since the first attempt) default to real time and
    /// exist so tests can run without waiting.
    /// </summary>
    public static async Task<HttpResponseMessage> SendAsync(
        Func<CancellationToken, Task<HttpResponseMessage>> send,
        CancellationToken cancellationToken = default,
        EsclRetryPolicy? policy = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null,
        Func<TimeSpan>? elapsed = null)
    {
        policy ??= EsclRetryPolicy.Default;
        delay ??= Task.Delay;
        if (elapsed is null)
        {
            var clock = Stopwatch.StartNew();
            elapsed = () => clock.Elapsed;
        }
        for (int retry = 0; ; retry++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var response = await send(cancellationToken).ConfigureAwait(false);
            if (!IsRetryable(response.StatusCode)) return response;
            var wait = policy.DelayBefore(retry, response.Headers.RetryAfter?.Delta);
            if (elapsed() + wait > policy.GiveUpAfter) return response;
            response.Dispose();
            await delay(wait, cancellationToken).ConfigureAwait(false);
        }
    }
}
