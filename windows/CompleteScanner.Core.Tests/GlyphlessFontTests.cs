using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// The text layer's font. No Swift twin yet: the Mac's PDF writer port (CONTRACTS.md, M19) brings
// one, which must produce the same bytes (the pinned lengths and SHA-256 below).

public class GlyphlessFontTests
{
    private static int U16(byte[] b, int at) => (b[at] << 8) | b[at + 1];
    private static uint U32(byte[] b, int at) => (uint)((b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]);

    /// <summary>The table directory of a TrueType font: tag → (offset, length, stored checksum).</summary>
    private static Dictionary<string, (int Offset, int Length, uint Checksum)> Tables(byte[] font)
    {
        var tables = new Dictionary<string, (int, int, uint)>();
        int count = U16(font, 4);
        for (int i = 0; i < count; i++)
        {
            int at = 12 + i * 16;
            tables[Encoding.ASCII.GetString(font, at, 4)] = ((int)U32(font, at + 8), (int)U32(font, at + 12), U32(font, at + 4));
        }
        return tables;
    }

    [Fact]
    public void Program_IsATrueTypeFontWithItsTablesInOrder()
    {
        byte[] font = GlyphlessFont.Program;
        Assert.Equal(0x00010000u, U32(font, 0));
        Assert.Equal(10, U16(font, 4));
        Assert.Equal((128, 3, 32), (U16(font, 6), U16(font, 8), U16(font, 10))); // searchRange, entrySelector, rangeShift
        var tags = Enumerable.Range(0, 10).Select(i => Encoding.ASCII.GetString(font, 12 + i * 16, 4)).ToList();
        Assert.Equal(["OS/2", "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post"], tags);
        foreach (var (tag, (offset, length, _)) in Tables(font))
        {
            Assert.Equal(0, offset % 4);
            Assert.True(offset + length <= font.Length, tag);
        }
        Assert.Equal(0, font.Length % 4);
    }

    [Fact]
    public void Program_ChecksumsAreRight()
    {
        byte[] font = GlyphlessFont.Program;
        var tables = Tables(font);
        foreach (var (tag, (offset, length, stored)) in tables)
        {
            var data = font.AsSpan(offset, length).ToArray();
            if (tag == "head") Array.Clear(data, 8, 4); // the head is summed without its checksum adjustment
            Assert.Equal(GlyphlessFont.Checksum(data), stored);
        }
        // The adjustment makes the whole file sum to the magic number.
        Assert.Equal(0xB1B0AFBAu, GlyphlessFont.Checksum(font));
        Assert.Equal(0x5F0F3CF5u, U32(font, tables["head"].Offset + 12));
    }

    [Fact]
    public void Program_HasTwoEmptyGlyphsHalfAnEmWide()
    {
        byte[] font = GlyphlessFont.Program;
        var t = Tables(font);
        int head = t["head"].Offset, hhea = t["hhea"].Offset, maxp = t["maxp"].Offset;
        Assert.Equal(1000, U16(font, head + 18));          // unitsPerEm
        Assert.Equal(0, U16(font, head + 50));             // short loca offsets
        Assert.Equal(2, U16(font, maxp + 4));              // numGlyphs
        Assert.Equal(0x00010000u, U32(font, maxp));        // TrueType maxp
        Assert.Equal(1000, U16(font, hhea + 4));           // ascender
        Assert.Equal(0, U16(font, hhea + 6));              // descender
        Assert.Equal(2, U16(font, hhea + 34));             // numberOfHMetrics
        var hmtx = t["hmtx"];
        Assert.Equal(8, hmtx.Length);
        Assert.Equal((500, 500), (U16(font, hmtx.Offset), U16(font, hmtx.Offset + 4)));
        var loca = t["loca"];
        Assert.Equal(6, loca.Length);
        Assert.All(Enumerable.Range(0, 3), i => Assert.Equal(0, U16(font, loca.Offset + i * 2))); // both glyphs empty
        Assert.Equal(0, U16(font, t["OS/2"].Offset + 8)); // fsType: embedding allowed
        // The name table names the font as the PDF does.
        var name = t["name"];
        string names = Encoding.BigEndianUnicode.GetString(font, name.Offset + U16(font, name.Offset + 4),
                                                           name.Length - U16(font, name.Offset + 4));
        Assert.Contains(GlyphlessFont.FontName, names);
    }

    [Fact]
    public void Program_BytesArePinned()
    {
        // The Mac's port of the writer must produce these exact bytes.
        byte[] font = GlyphlessFont.Program;
        Assert.Equal(636, font.Length);
        Assert.Equal("103B87CF98EE3A3E5FD752F3DB29975611605F785B36C879FAA61ABD439CC391", Convert.ToHexString(SHA256.HashData(font)));
        Assert.Equal(font, GlyphlessFont.Build());
    }

    [Fact]
    public void CidToGidMap_InflatesToGlyphOneForEveryCode()
    {
        byte[] compressed = GlyphlessFont.CidToGidMap;
        using var input = new ZLibStream(new MemoryStream(compressed), CompressionMode.Decompress);
        using var output = new MemoryStream();
        input.CopyTo(output);
        byte[] map = output.ToArray();
        Assert.Equal(GlyphlessFont.CodeCount * 2, map.Length);
        for (int i = 0; i < map.Length; i += 2) Assert.True(map[i] == 0 && map[i + 1] == 1, $"code {i / 2}");
        Assert.Equal(GlyphlessFont.CidToGidMapData(), map);
        // zlib header and the Adler-32 of the data at the end.
        Assert.Equal((0x78, 0x01), (compressed[0], compressed[1]));
        Assert.Equal(GlyphlessFont.Adler32(map), U32(compressed, compressed.Length - 4));
    }

    [Fact]
    public void CidToGidMap_BytesArePinned()
    {
        byte[] compressed = GlyphlessFont.CidToGidMap;
        Assert.Equal(837, compressed.Length);
        Assert.Equal("2B554AACC4A744E7F14EF4BE52FA515B70E9AE4A60402C38B1D404E8EC7AE17E", Convert.ToHexString(SHA256.HashData(compressed)));
    }

    [Fact]
    public void Adler32_KnownValues()
    {
        Assert.Equal(0x00000001u, GlyphlessFont.Adler32([]));
        Assert.Equal(0x11E60398u, GlyphlessFont.Adler32("Wikipedia"u8));
    }

    [Fact]
    public void ToUnicode_MapsEveryCodeOutsideTheSurrogatesToItself_InBlocksOfAtMost100()
    {
        string cmap = GlyphlessCodes.For([]).ToUnicodeCMap();
        Assert.Contains("1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n", cmap);
        Assert.Equal([100, 100, 48], Regex.Matches(cmap, @"(\d+) beginbfrange").Select(m => int.Parse(m.Groups[1].Value)));
        Assert.DoesNotContain("bfchar", cmap);
        var ranges = Regex.Matches(cmap, "<([0-9A-F]{4})> <([0-9A-F]{4})> <([0-9A-F]{4})>")
            .Select(m => (Convert.ToInt32(m.Groups[1].Value, 16), Convert.ToInt32(m.Groups[2].Value, 16),
                          Convert.ToInt32(m.Groups[3].Value, 16)))
            .ToList();
        var expected = Enumerable.Range(0, 256).Where(h => h is < 0xD8 or > 0xDF).Select(h => (h * 256, h * 256 + 255, h * 256));
        Assert.Equal(expected, ranges);
        Assert.True(Encoding.ASCII.GetByteCount(cmap) == cmap.Length, "ASCII only");
        Assert.EndsWith("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n", cmap);
    }

    [Fact]
    public void Codes_AreTheUtf16CodeUnitsInTheBmp()
    {
        var codes = GlyphlessCodes.For(["Hi", "çğıİöşü"]);
        Assert.Empty(codes.Supplementary);
        Assert.Equal("<00480069>", codes.HexString("Hi"));
        Assert.Equal("<>", codes.HexString(""));
        // Turkish: ç ğ ı İ ö ş ü.
        Assert.Equal("<00E7011F0131013000F6015F00FC>", codes.HexString("çğıİöşü"));
        Assert.Equal("<65E5672C8A9E>", codes.HexString("日本語"));
        Assert.Equal("<0645063106AD>", codes.HexString("مرڭ"));
    }

    [Fact]
    public void Codes_BeyondTheBmpGetSurrogateRangeCodes_InOrderOfFirstUse()
    {
        // U+1F4C4 (page facing up), U+2000B (a CJK Extension B ideograph), U+1D11E (G clef).
        var codes = GlyphlessCodes.For(["a \U0001F4C4 b", "\U0002000B\U0001F4C4", "", "\U0001D11E"]);
        Assert.Equal([0x1F4C4, 0x2000B, 0x1D11E], codes.Supplementary);
        Assert.Equal([0x61, 0x20, 0xD800, 0x20, 0x62], codes.Codes("a \U0001F4C4 b"));
        Assert.Equal("<D801D800D802>", codes.HexString("\U0002000B\U0001F4C4\U0001D11E"));
        // A character the codes were not built from, and lone surrogates, are written as U+FFFD.
        Assert.Equal([0xFFFD, 0xFFFD, 0x78, 0xFFFD], codes.Codes("\U0001F600\uD800x\uDC00"));
        string cmap = codes.ToUnicodeCMap();
        Assert.Contains("3 beginbfchar\n<D800> <D83DDCC4>\n<D801> <D840DC0B>\n<D802> <D834DD1E>\nendbfchar\n", cmap);
    }

    [Fact]
    public void Codes_BeyondTheBmp_StopAt2048()
    {
        string many = string.Concat(Enumerable.Range(0x20000, 2100).Select(char.ConvertFromUtf32));
        var codes = GlyphlessCodes.For([many]);
        Assert.Equal(GlyphlessCodes.SupplementaryCapacity, codes.Supplementary.Count);
        var written = codes.Codes(many);
        Assert.Equal(2100, written.Count);
        Assert.Equal(0xDFFF, written[2047]);
        Assert.All(written.Skip(2048), code => Assert.Equal(0xFFFD, code));
        string cmap = codes.ToUnicodeCMap();
        Assert.Equal([.. Enumerable.Repeat(100, 20), 48], Regex.Matches(cmap, @"(\d+) beginbfchar").Select(m => int.Parse(m.Groups[1].Value)));
    }

    [Fact]
    public void TextWidth_IsHalfTheSizePerCode()
    {
        Assert.Equal(25.0, GlyphlessFont.TextWidth(5, 10));
        Assert.Equal(0.0, GlyphlessFont.TextWidth(0, 10));
        var codes = GlyphlessCodes.For(["日本\U0002000B"]);
        Assert.Equal(18.0, GlyphlessFont.TextWidth(codes.Codes("日本\U0002000B").Count, 12)); // one code per character
    }
}
