using Xunit;

namespace CompleteScanner.Core.Tests;

/// <summary>
/// Tests that wait on real time across threads (loopback servers, timeouts, long polls, helper
/// processes) run in this collection, one at a time and after the tests that run in parallel. Beside
/// those, the image code's Parallel.For work can keep the thread pool busy for longer than these
/// tests' timeouts on a small CI runner, so a continuation they wait for runs too late.
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class WallClockCollection
{
    public const string Name = "Wall clock";
}
