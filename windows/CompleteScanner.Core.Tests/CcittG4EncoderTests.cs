using System.Security.Cryptography;
using CompleteScanner.Core;
using UglyToad.PdfPig;
using Xunit;

namespace CompleteScanner.Core.Tests;

// The G4 encoder and the bilevel packing. The Mac's port (with the port of the C# PDF writer) must
// give the same bytes: the known answers below are written from the bit strings of ITU-T T.4 and
// T.6, not from the encoder's own tables, and the golden values are checked against two separate
// decoders: PdfPig's CCITT filter here, and WIC (which also encodes the same bytes itself) in
// CompleteScanner.App.Tests/BilevelOutputTests.cs.

public class CcittG4EncoderTests
{
    private const string Eofb = "000000000001" + "000000000001";

    /// <summary>The bit strings in order, then zero bits up to a byte boundary.</summary>
    internal static byte[] Bits(params string[] parts)
    {
        string all = string.Concat(parts);
        var bytes = new byte[(all.Length + 7) / 8];
        for (int i = 0; i < all.Length; i++)
        {
            if (all[i] == '1') bytes[i / 8] |= (byte)(0x80 >> (i % 8));
            else Assert.Equal('0', all[i]);
        }
        return bytes;
    }

    /// <summary>Packed rows (<see cref="Bilevel"/> layout) from rows of '1' (black) and '0' (white).</summary>
    internal static byte[] Rows(params string[] rows)
    {
        int width = rows[0].Length;
        return Packed(width, rows.Length, (x, y) => rows[y][x] == '1');
    }

    internal static byte[] Packed(int width, int height, Func<int, int, bool> black)
    {
        int stride = Bilevel.Stride(width);
        var packed = new byte[stride * height];
        packed.AsSpan().Fill(0xFF);
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                if (black(x, y)) packed[y * stride + (x >> 3)] &= (byte)~(0x80 >> (x & 7));
            }
        }
        return packed;
    }

    /// <summary>An image of black (true) and white pixels.</summary>
    internal static RgbaImage Image(int width, int height, Func<int, int, bool> black) =>
        Bilevel.Unpack(Packed(width, height, black), width, height);

    /// <summary>
    /// The G4 data decoded by PdfPig's CCITT filter (a separate decoder, test-only): the data is
    /// put in a one-page PDF as a /CCITTFaxDecode image and read back as packed rows.
    /// </summary>
    internal static byte[] DecodeWithPdfPig(byte[] g4, int width, int height)
    {
        byte[] pdf = PdfBuilder.Make([new PdfPageInput(new PdfCcittImage(g4, width, height), width, height, 300, null)]);
        using var document = PdfDocument.Open(pdf);
        var image = document.GetPage(1).GetImages().Single();
        Assert.True(image.TryGetBytesAsMemory(out var bytes));
        return bytes.ToArray();
    }

    /// <summary>Encodes, decodes with PdfPig and expects every pixel back.</summary>
    private static byte[] AssertRoundTrip(byte[] packed, int width, int height)
    {
        byte[] g4 = CcittG4Encoder.Encode(packed, width, height);
        byte[] decoded = DecodeWithPdfPig(g4, width, height);
        Assert.Equal(packed.Length, decoded.Length);
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                if (Bilevel.IsBlack(packed, width, x, y) != Bilevel.IsBlack(decoded, width, x, y))
                {
                    Assert.Fail($"{width} × {height}: pixel ({x}, {y}) differs after decoding");
                }
            }
        }
        return g4;
    }

    private static string Sha256(byte[] data) => Convert.ToHexString(SHA256.HashData(data));

    // MARK: - Code tables

    [Fact]
    public void CodeTables_CoverEveryRun_AndArePrefixFreePerColor()
    {
        Assert.Equal(64, CcittG4Encoder.WhiteTerminating.Length);
        Assert.Equal(64, CcittG4Encoder.BlackTerminating.Length);
        Assert.Equal(27, CcittG4Encoder.WhiteMakeUp.Length);
        Assert.Equal(27, CcittG4Encoder.BlackMakeUp.Length);
        Assert.Equal(13, CcittG4Encoder.ExtendedMakeUp.Length);
        Assert.Equal(7, CcittG4Encoder.Vertical.Length);

        static string Text((int Code, int Length) c) => Convert.ToString(c.Code, 2).PadLeft(c.Length, '0');
        static void AssertPrefixFree(IEnumerable<string> codes, string what)
        {
            var list = codes.ToList();
            for (int i = 0; i < list.Count; i++)
            {
                for (int j = 0; j < list.Count; j++)
                {
                    if (i != j) Assert.False(list[j].StartsWith(list[i], StringComparison.Ordinal), $"{what}: {list[i]} is a prefix of {list[j]}");
                }
            }
        }
        var eol = new[] { "000000000001" };
        AssertPrefixFree(CcittG4Encoder.WhiteTerminating.Concat(CcittG4Encoder.WhiteMakeUp).Concat(CcittG4Encoder.ExtendedMakeUp)
                             .Select(Text).Concat(eol), "white");
        AssertPrefixFree(CcittG4Encoder.BlackTerminating.Concat(CcittG4Encoder.BlackMakeUp).Concat(CcittG4Encoder.ExtendedMakeUp)
                             .Select(Text).Concat(eol), "black");
        AssertPrefixFree(CcittG4Encoder.Vertical.Select(Text)
                             .Concat([Text((CcittG4Encoder.PassCode, CcittG4Encoder.PassLength)),
                                      Text((CcittG4Encoder.HorizontalCode, CcittG4Encoder.HorizontalLength))])
                             .Concat(eol), "modes");

        // A few entries checked against T.4 by hand.
        Assert.Equal("00110101", Text(CcittG4Encoder.WhiteTerminating[0]));
        Assert.Equal("0000110111", Text(CcittG4Encoder.BlackTerminating[0]));
        Assert.Equal("00110100", Text(CcittG4Encoder.WhiteTerminating[63]));
        Assert.Equal("000001100111", Text(CcittG4Encoder.BlackTerminating[63]));
        Assert.Equal("010011011", Text(CcittG4Encoder.WhiteMakeUp[26]));      // 1728
        Assert.Equal("0000001100101", Text(CcittG4Encoder.BlackMakeUp[26]));  // 1728
        Assert.Equal("00000001000", Text(CcittG4Encoder.ExtendedMakeUp[0]));   // 1792
        Assert.Equal("000000011111", Text(CcittG4Encoder.ExtendedMakeUp[12])); // 2560
    }

    // MARK: - Known answers

    [Fact]
    public void AllWhite_IsOneV0PerRow_ThenEofb()
    {
        byte[] g4 = CcittG4Encoder.Encode(Packed(1728, 10, (_, _) => false), 1728, 10);
        Assert.Equal(Bits("1111111111", Eofb), g4);
        Assert.Equal(new byte[] { 0xFF, 0xC0, 0x04, 0x00, 0x40 }, g4);
        Assert.Equal(g4, CcittG4Encoder.Encode(RgbaImage.Filled(1728, 10, 255, 255, 255)));
    }

    [Fact]
    public void AllBlack_IsOneHorizontalRow_ThenTwoV0PerRow()
    {
        byte[] g4 = CcittG4Encoder.Encode(Packed(1728, 10, (_, _) => true), 1728, 10);
        // Row 1 against the white row above: horizontal, white 0, black 1728 (make-up 1728 + 0).
        // Every later row: V0 under the black run's start, V0 at the end.
        Assert.Equal(Bits("001", "00110101", "0000001100101", "0000110111",
                          string.Concat(Enumerable.Repeat("11", 9)), Eofb), g4);
        Assert.Equal(10, g4.Length);
        Assert.Equal(g4, CcittG4Encoder.Encode(RgbaImage.Filled(1728, 10, 0, 0, 0)));
    }

    [Fact]
    public void ModeCodes_PassHorizontalAndEveryVerticalOffset()
    {
        byte[] packed = Rows(
            "00011000",  // H: white 3, black 2; V0
            "00011000",  // V0 V0 V0
            "00110000",  // VL1 VL1 V0
            "00000000",  // pass, V0
            "00000011",  // VL2 (b1 is the row's end), V0
            "00000001",  // VR1, V0
            "01111111",  // H: white 1, black 7
            "11111000",  // VL1, VL3, V0
            "00001110",  // H: white 4, black 3; V0
            "00000011",  // VR2, VR1
            "11111111",  // H: white 0, black 8
            "11100000",  // V0, H starting black: black 3, white 5
            "00011111"); // VR3, V0
        byte[] g4 = CcittG4Encoder.Encode(packed, 8, 13);
        Assert.Equal(Bits(
            "001", "1000", "11", "1",
            "1", "1", "1",
            "010", "010", "1",
            "0001", "1",
            "000010", "1",
            "011", "1",
            "001", "000111", "00011",
            "010", "0000010", "1",
            "001", "1011", "10", "1",
            "000011", "011",
            "001", "00110101", "000101",
            "1", "001", "10", "1100",
            "0000011", "1",
            Eofb), g4);
        AssertRoundTrip(packed, 8, 13);
    }

    [Fact]
    public void LongRuns_RepeatTheLargestExtendedMakeUpCode()
    {
        // White 5200 = 2560 + 2560 + 64 + 16; black 2800 = 2560 + 192 + 48.
        byte[] g4 = CcittG4Encoder.Encode(Packed(8000, 1, (x, _) => x >= 5200), 8000, 1);
        Assert.Equal(Bits("001",
                          "000000011111", "000000011111", "11011", "101010",
                          "000000011111", "000011001001", "000001100100",
                          Eofb), g4);

        // 2624 is the first run with two make-up codes (2560 + 64 + 0); 2623 is 2560 + 63.
        g4 = CcittG4Encoder.Encode(Packed(5247, 1, (x, _) => x >= 2624), 5247, 1);
        Assert.Equal(Bits("001",
                          "000000011111", "11011", "00110101",
                          "000000011111", "000001100111",
                          Eofb), g4);
    }

    [Fact]
    public void NoRows_IsJustEofb()
    {
        Assert.Equal(new byte[] { 0x00, 0x10, 0x01 }, CcittG4Encoder.Encode([], 100, 0));
    }

    [Fact]
    public void SinglePixels_AndOnePixelLines()
    {
        // A black pixel: VL1 (a1 = 0, one left of b1 at the row's end), then V0.
        Assert.Equal(Bits("010", "1", Eofb), CcittG4Encoder.Encode(Rows("1"), 1, 1));
        Assert.Equal(Bits("1", Eofb), CcittG4Encoder.Encode(Rows("0"), 1, 1));
        // A one-pixel-wide column and a one-pixel-tall row, both with a pattern.
        AssertRoundTrip(Packed(1, 17, (_, y) => y % 3 != 1), 1, 17);
        AssertRoundTrip(Packed(997, 1, (x, _) => x % 5 < 2 || x > 900), 997, 1);
    }

    [Fact]
    public void Arguments_AreChecked()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => CcittG4Encoder.Encode(new byte[4], 0, 1));
        Assert.Throws<ArgumentOutOfRangeException>(() => CcittG4Encoder.Encode(new byte[4], 8, -1));
        Assert.Throws<ArgumentException>(() => CcittG4Encoder.Encode(new byte[3], 9, 2)); // needs 4 bytes
    }

    // MARK: - Round trips through a separate decoder

    [Fact]
    public void RoundTrip_EveryRunLengthOfBothColors()
    {
        // Rows separated by white rows, so each is coded in horizontal mode: white L then black,
        // and black L then white, for L = 1 ... 2700 (every terminating, make-up and extended
        // make-up code of both colors, and the white 0 run).
        const int width = 2710, longest = 2700;
        int height = longest * 4;
        byte[] packed = Packed(width, height, (x, y) =>
        {
            int run = y / 4 + 1;
            return (y % 4) switch
            {
                1 => x >= run,
                3 => x < run,
                _ => false,
            };
        });
        AssertRoundTrip(packed, width, height);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(7)]
    [InlineData(8)]
    [InlineData(9)]
    [InlineData(15)]
    [InlineData(17)]
    [InlineData(1727)]
    [InlineData(1729)]
    public void RoundTrip_OddWidths(int width)
    {
        var rng = new TestPages.Rng((uint)(0xB1E0 + width));
        // Noise, a checkerboard and runs that end on the last pixel.
        int height = 24;
        byte[] packed = Packed(width, height, (x, y) => y switch
        {
            < 8 => rng.Below(3) == 0,
            < 16 => ((x + y) & 1) == 0,
            _ => x >= width - (y - 15),
        });
        AssertRoundTrip(packed, width, height);
    }

    [Fact]
    public void RoundTrip_VeryWideRows()
    {
        var rng = new TestPages.Rng(0x5EED0001);
        byte[] packed = Packed(20000, 12, (x, y) => y switch
        {
            0 => true,
            1 => x >= 3 && x < 15000,
            2 => x % 2629 == 0,
            3 => x >= 10000,
            4 => x < 2624 || (x >= 5184 && x < 5247),
            5 => rng.Below(50) == 0,
            _ => (x / 97 + y) % 3 == 0,
        });
        AssertRoundTrip(packed, 20000, 12);
    }

    // MARK: - Golden bytes (the Swift port must give the same)

    [Fact]
    public void Golden_Checkerboard_Noise_TextPage()
    {
        byte[] checker = AssertRoundTrip(Packed(37, 23, (x, y) => ((x + y) & 1) == 0), 37, 23);
        Assert.Equal(335, checker.Length);
        Assert.Equal("E8A046161C50C7D37EA4A44DC4A9F1DCE909940D388C27C8CCECCBE798DC43EC", Sha256(checker));

        var rng = new TestPages.Rng(0xC0FFEE01);
        byte[] noise = AssertRoundTrip(Packed(517, 211, (_, _) => rng.Below(2) == 0), 517, 211);
        Assert.Equal(28704, noise.Length);
        Assert.Equal("4255D22C831C890F8DAFAC2B936E2CAB95D2AB5FAAD06CC844C04E5AB8D215C0", Sha256(noise));

        // The blank-page tests' text page (850 × 1100 at 100 dpi) made black & white.
        var text = TestPages.TextPage().ToRgba();
        byte[] page = CcittG4Encoder.Encode(text);
        var packed = Bilevel.Pack(text);
        Assert.Equal(packed, DecodeWithPdfPig(page, text.Width, text.Height));
        Assert.Equal(17666, page.Length);
        Assert.Equal("DD8EC2973FEA77FBB02C0DBD9A9BC69C9771852D2AD18B70AEF0387D94EC4DFE", Sha256(page));
    }

    // MARK: - Bilevel

    [Fact]
    public void Bilevel_ThresholdsLumaAt128()
    {
        // Gray 127 is black, 128 white; pure red (luma 76) black, pure green (150) white;
        // (255, 0, 136): luma 76 + 0 + 16 = 92 black.
        var pixels = new byte[]
        {
            127, 127, 127, 255,  128, 128, 128, 255,  255, 0, 0, 255,  0, 255, 0, 255,  255, 0, 136, 255,
        };
        var image = new RgbaImage(5, 1, pixels);
        byte[] packed = Bilevel.Pack(image);
        Assert.Equal(new byte[] { 0b0101_0111 }, packed); // black, white, black, white, black, then padding
        Assert.Equal(new[] { true, false, true, false, true }, Enumerable.Range(0, 5).Select(x => Bilevel.IsBlack(packed, 5, x, 0)));
        Assert.Equal(1, Bilevel.Stride(1));
        Assert.Equal(1, Bilevel.Stride(8));
        Assert.Equal(2, Bilevel.Stride(9));
    }

    [Fact]
    public void Bilevel_PackAndUnpack_RoundTrip_WithWhitePadding()
    {
        var rng = new TestPages.Rng(0xB11EBE1);
        byte[] packed = Packed(13, 5, (_, _) => rng.Below(2) == 0);
        var image = Bilevel.Unpack(packed, 13, 5);
        Assert.Equal(packed, Bilevel.Pack(image));
        Assert.All(Enumerable.Range(0, 5), y => Assert.Equal(0b0000_0111, packed[y * 2 + 1] & 0b0000_0111));
        Assert.All(Enumerable.Range(0, image.Pixels.Length / 4),
                   p => Assert.True(image.Pixels[p * 4] is 0 or 255 && image.Pixels[p * 4 + 3] == 255));
    }

    [Fact]
    public void Encode_OfAnImage_IsTheEncodingOfItsPackedBits()
    {
        var page = ImagePipeline.Apply(new AdjustmentSettings(), TestPages.TextPage().ToRgba(), ColorMode.BlackWhite);
        Assert.Equal(CcittG4Encoder.Encode(Bilevel.Pack(page), page.Width, page.Height), CcittG4Encoder.Encode(page));
        var g4 = PdfCcittImage.Encode(page);
        Assert.Equal((page.Width, page.Height), (g4.Width, g4.Height));
        Assert.Equal(CcittG4Encoder.Encode(page), g4.Data);
    }
}
