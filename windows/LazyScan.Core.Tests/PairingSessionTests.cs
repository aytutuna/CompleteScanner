using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/PairingSessionTests.swift (same clock steps, same answers).

public class PairingSessionTests
{
    private static readonly DateTimeOffset Opened = new(2026, 10, 20, 8, 30, 0, TimeSpan.Zero);

    private static PairingSession Session() => new(Opened, CompanionVectors.Token);

    [Fact]
    public void Token_IsTheGivenBytesOrRandom()
    {
        Assert.Equal(CompanionVectors.TokenText, Session().Token);
        var a = new PairingSession(Opened);
        var b = new PairingSession(Opened);
        Assert.NotEqual(a.Token, b.Token);
        Assert.Equal(16, CompanionProtocol.DecodeBase64Url(a.Token)!.Length);
        Assert.Throws<ArgumentException>(() => new PairingSession(Opened, new byte[15]));
    }

    [Fact]
    public void RightToken_IsAcceptedOnce()
    {
        var session = Session();
        Assert.Equal(PairingSessionState.Open, session.StateAt(Opened));
        Assert.Equal(PairingRedeemResult.Accepted, session.Redeem(CompanionVectors.TokenText, Opened.AddMinutes(1)));
        Assert.Equal(PairingSessionState.Used, session.StateAt(Opened.AddMinutes(1)));
        Assert.Equal(PairingRedeemResult.AlreadyUsed, session.Redeem(CompanionVectors.TokenText, Opened.AddMinutes(2)));
        Assert.Equal(PairingRedeemResult.AlreadyUsed, session.Redeem("wrong", Opened.AddMinutes(2)));
        Assert.Equal(TimeSpan.Zero, session.Remaining(Opened.AddMinutes(2)));
    }

    [Fact]
    public void Token_ExpiresAfterFiveMinutes()
    {
        var session = Session();
        Assert.Equal(TimeSpan.FromMinutes(5), session.Remaining(Opened));
        Assert.Equal(TimeSpan.FromSeconds(1), session.Remaining(Opened.AddMinutes(5).AddSeconds(-1)));
        Assert.Equal(PairingSessionState.Expired, session.StateAt(Opened.AddMinutes(5)));
        Assert.Equal(PairingRedeemResult.Expired, session.Redeem(CompanionVectors.TokenText, Opened.AddMinutes(5)));
        Assert.Equal(PairingRedeemResult.Expired, session.Redeem(CompanionVectors.TokenText, Opened.AddMinutes(1)));
        Assert.Equal(PairingRedeemResult.Accepted,
                     Session().Redeem(CompanionVectors.TokenText, Opened.AddMinutes(5).AddMilliseconds(-1)));
    }

    [Fact]
    public void WrongTokens_CloseTheSessionAfterFive()
    {
        var session = Session();
        string almost = CompanionVectors.TokenText[..^1] + "x";
        for (int i = 1; i < PairingSession.MaxFailedAttempts; i++)
        {
            Assert.Equal(PairingRedeemResult.WrongToken, session.Redeem(almost, Opened));
            Assert.Equal(i, session.FailedAttempts);
            Assert.Equal(PairingSessionState.Open, session.StateAt(Opened));
        }
        Assert.Equal(PairingRedeemResult.WrongToken, session.Redeem(null, Opened));
        Assert.Equal(PairingSessionState.Closed, session.StateAt(Opened));
        Assert.Equal(PairingRedeemResult.Closed, session.Redeem(CompanionVectors.TokenText, Opened));
    }

    [Fact]
    public void MalformedTokens_CountAsWrong()
    {
        var session = Session();
        Assert.Equal(PairingRedeemResult.WrongToken, session.Redeem("", Opened));
        Assert.Equal(PairingRedeemResult.WrongToken, session.Redeem("AAECAwQFBgcICQoLDA0ODw==", Opened));
        Assert.Equal(PairingRedeemResult.WrongToken, session.Redeem(CompanionVectors.TokenText + "AA", Opened));
        Assert.Equal(3, session.FailedAttempts);
        Assert.Equal(PairingRedeemResult.Accepted, session.Redeem(CompanionVectors.TokenText, Opened));
    }

    [Fact]
    public void Close_RefusesTheToken()
    {
        var session = Session();
        session.Close();
        Assert.Equal(PairingSessionState.Closed, session.StateAt(Opened));
        Assert.Equal(PairingRedeemResult.Closed, session.Redeem(CompanionVectors.TokenText, Opened));
        var used = Session();
        used.Redeem(CompanionVectors.TokenText, Opened);
        used.Close();
        Assert.Equal(PairingSessionState.Used, used.StateAt(Opened));
    }
}
