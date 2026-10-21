using Xunit;

namespace CompleteScanner.App.Tests;

/// <summary>
/// Tests that wait on real time across threads and processes (the 32-bit TWAIN helper) run in this
/// collection, one at a time and after the tests that run in parallel. Beside those, the image
/// tests can keep a small CI runner's cores busy for longer than these tests' timeouts, so a
/// helper that was just started answers too late.
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class WallClockCollection
{
    public const string Name = "Wall clock";
}
