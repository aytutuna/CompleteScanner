using System.Text;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/ZipStoreReaderTests.swift: the same cases, the same
// hand-built archives (RawZip), the same error kinds and messages.

public class ZipStoreReaderTests
{
    [Fact]
    public void ReadsWhatZipStoreWrites()
    {
        byte[] big = Enumerable.Range(0, 70_000).Select(i => (byte)(i * 7)).ToArray();
        byte[] zip = ZipStore.Make(
        [
            new ZipStoreEntry("[Content_Types].xml", "<x/>"u8.ToArray()),
            new ZipStoreEntry("dir/empty.bin", []),
            new ZipStoreEntry("dir/big.bin", big),
            new ZipStoreEntry("naïve.txt", "é"u8.ToArray()),
        ]);
        using var reader = ZipStoreReader.Open(zip);
        Assert.Equal(["[Content_Types].xml", "dir/empty.bin", "dir/big.bin", "naïve.txt"], reader.Entries.Select(e => e.Name));
        Assert.Equal([4L, 0L, 70_000L, 2L], reader.Entries.Select(e => e.Size));
        Assert.Equal(big, reader.Read(reader.Find("dir/big.bin")!));
        Assert.Empty(reader.Read(reader.Find("dir/empty.bin")!));
        Assert.Equal("é", Encoding.UTF8.GetString(reader.Read(reader.Find("naïve.txt")!)));
        Assert.Equal(ZipStore.Crc32(big), reader.Find("dir/big.bin")!.Crc32);
        Assert.Equal(30 + 19, reader.Entries[0].DataOffset);
    }

    [Fact]
    public void ReadsAnEmptyArchive()
    {
        using var reader = ZipStoreReader.Open(ZipStore.Make([]));
        Assert.Empty(reader.Entries);
    }

    [Fact]
    public void ReadAll_ReturnsEveryEntry()
    {
        var entries = ZipStoreReader.ReadAll(ZipStore.Make([new("a.txt", "hi"u8.ToArray()), new("b/c.txt", "yo"u8.ToArray())]));
        Assert.Equal(["a.txt", "b/c.txt"], entries.Select(e => e.Name));
        Assert.Equal("yo"u8.ToArray(), entries[1].Data);
    }

    [Fact]
    public void ReadsStoredArchivesFromOtherTools()
    {
        // As Info-ZIP's "zip -0" writes them: Unix attributes, timestamp extras that differ
        // between the local header and the directory, a folder entry and an archive comment.
        byte[] zip = RawZip.Build(
        [
            new RawEntry("pages/", []) { MadeBy = 0x031E, External = (0x41EDu << 16) | 0x10, LocalExtra = RawZip.Extra(0x5455, 9), CentralExtra = RawZip.Extra(0x5455, 5) },
            new RawEntry("pages/a.txt", "hello"u8.ToArray()) { MadeBy = 0x031E, External = 0x81A4u << 16, LocalExtra = RawZip.Extra(0x5455, 9), CentralExtra = RawZip.Extra(0x5455, 5) },
            new RawEntry("b.txt", "bye"u8.ToArray()) { MadeBy = 0x003F, External = 0x20, CentralExtra = RawZip.Extra(0x000A, 32) },
        ],
        new RawEnd { Comment = "made by hand"u8.ToArray() });
        using var reader = ZipStoreReader.Open(zip);
        Assert.Equal(["pages/a.txt", "b.txt"], reader.Entries.Select(e => e.Name));
        Assert.Equal("hello"u8.ToArray(), reader.Read(reader.Find("pages/a.txt")!));
        Assert.Equal("bye"u8.ToArray(), reader.Read(reader.Find("b.txt")!));
    }

    // Windows only (Foundation has no zip writer): archives System.IO.Compression writes, stored
    // ones read and deflated ones refused.
    [Fact]
    public void ReadsStoredZipArchiveOutput_RefusesDeflated()
    {
        static byte[] Write(System.IO.Compression.CompressionLevel level)
        {
            using var memory = new MemoryStream();
            using (var archive = new System.IO.Compression.ZipArchive(memory, System.IO.Compression.ZipArchiveMode.Create, leaveOpen: true))
            {
                foreach (var (name, text) in new[] { ("a.txt", "hello hello hello hello"), ("dir/b.txt", "world") })
                {
                    using var stream = archive.CreateEntry(name, level).Open();
                    stream.Write(Encoding.UTF8.GetBytes(text));
                }
            }
            return memory.ToArray();
        }

        using (var reader = ZipStoreReader.Open(Write(System.IO.Compression.CompressionLevel.NoCompression)))
        {
            Assert.Equal(["a.txt", "dir/b.txt"], reader.Entries.Select(e => e.Name));
            Assert.Equal("world"u8.ToArray(), reader.Read(reader.Find("dir/b.txt")!));
        }
        AssertRefused(ZipReadErrorKind.UnsupportedMethod, Write(System.IO.Compression.CompressionLevel.Optimal));
    }

    [Fact]
    public void Find_IsExact()
    {
        using var reader = ZipStoreReader.Open(ZipStore.Make([new("Pages/A.jpg", [1])]));
        Assert.NotNull(reader.Find("Pages/A.jpg"));
        Assert.Null(reader.Find("pages/a.jpg"));
        Assert.Null(reader.Find("A.jpg"));
        // Ordinal: the same name in another Unicode form is another name.
        using var composed = ZipStoreReader.Open(ZipStore.Make([new("caf\u00E9.txt", [1])]));
        Assert.NotNull(composed.Find("caf\u00E9.txt"));
        Assert.Null(composed.Find("cafe\u0301.txt"));
    }

    [Fact]
    public void CopyTo_StreamsTheEntry()
    {
        byte[] big = Enumerable.Range(0, 200_000).Select(i => (byte)(i * 31)).ToArray();
        using var reader = ZipStoreReader.Open(ZipStore.Make([new("big.bin", big)]));
        using var output = new MemoryStream();
        reader.CopyTo(reader.Entries[0], output);
        Assert.Equal(big, output.ToArray());
    }

    [Fact]
    public void OpenFile_ReadsFromDisk()
    {
        string path = Path.Combine(Path.GetTempPath(), $"zipstorereader-{Guid.NewGuid():N}.zip");
        File.WriteAllBytes(path, ZipStore.Make([new("a.txt", "hi"u8.ToArray()), new("b.txt", "there"u8.ToArray())]));
        try
        {
            using var reader = ZipStoreReader.OpenFile(path);
            Assert.Equal("there"u8.ToArray(), reader.Read(reader.Find("b.txt")!));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void RefusesCompressedEntries()
    {
        AssertRefused(ZipReadErrorKind.UnsupportedMethod, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { Method = 8 }]));
        AssertRefused(ZipReadErrorKind.UnsupportedMethod, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { Method = 12 }]));
    }

    [Fact]
    public void RefusesEncryptedEntries()
    {
        AssertRefused(ZipReadErrorKind.Encrypted, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { Flags = 0x0001 }]));
        AssertRefused(ZipReadErrorKind.Encrypted, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { Flags = 0x0041 }]));
        AssertRefused(ZipReadErrorKind.Encrypted, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { Method = 99 }]));
        AssertRefused(ZipReadErrorKind.Encrypted, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { CentralExtra = RawZip.Extra(0x9901, 7) }]));
        AssertRefused(ZipReadErrorKind.Encrypted, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { LocalExtra = RawZip.Extra(0x9901, 7) }]));
    }

    [Fact]
    public void RefusesDataDescriptors()
    {
        AssertRefused(ZipReadErrorKind.DataDescriptor, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { Flags = 0x0008 }]));
    }

    [Fact]
    public void RefusesZip64()
    {
        AssertRefused(ZipReadErrorKind.Zip64, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { CentralExtra = RawZip.Extra(0x0001, 16) }]));
        AssertRefused(ZipReadErrorKind.Zip64, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { LocalExtra = RawZip.Extra(0x0001, 16) }]));
        AssertRefused(ZipReadErrorKind.Zip64, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { Compressed = 0xFFFFFFFF, Size = 0xFFFFFFFF }]));
        AssertRefused(ZipReadErrorKind.Zip64, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { CentralOffset = 0xFFFFFFFF }]));
        AssertRefused(ZipReadErrorKind.Zip64, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray())], new RawEnd { Zip64Locator = true }));
        AssertRefused(ZipReadErrorKind.Zip64, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray())], new RawEnd { Count = 0xFFFF, OnDisk = 0xFFFF }));
        AssertRefused(ZipReadErrorKind.Zip64, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray())], new RawEnd { DirectoryOffset = 0xFFFFFFFF }));
    }

    [Fact]
    public void RefusesUnsafeNames()
    {
        string[] names =
        [
            "../a.txt", "a/../b.txt", "a/..", "..", "/etc/passwd", "C:/x.txt", "C:x.txt", "a\\b.txt", "a\0b.txt",
            "a//b.txt", "./a.txt", "a/./b.txt", "con.", "a /b.txt", "a.txt ", "\u0001x", "x\u007F", "file.txt:stream",
            new string('a', 256), "",
        ];
        foreach (string name in names)
        {
            AssertRefused(ZipReadErrorKind.UnsafeName, RawZip.Build([new RawEntry(Encoding.UTF8.GetBytes(name), "hi"u8.ToArray())]));
        }
        // Not UTF-8: a lone continuation byte, a truncated sequence, an overlong "/".
        foreach (byte[] name in new[] { new byte[] { 0x61, 0x80 }, [0xC3, 0x28], [0x61, 0xC0, 0xAF, 0x62] })
        {
            AssertRefused(ZipReadErrorKind.UnsafeName, RawZip.Build([new RawEntry(name, "hi"u8.ToArray())]));
        }
        foreach (string name in SeparatorNextToAMark)
        {
            AssertRefused(ZipReadErrorKind.UnsafeName, RawZip.Build([new RawEntry(Encoding.UTF8.GetBytes(name), "hi"u8.ToArray())]));
        }
    }

    /// <summary>
    /// Unsafe names whose "/" is followed by a combining mark (U+0301) or a joiner (U+200D), or
    /// preceded by a prepended mark (U+0600): one grapheme with the "/", still a separator.
    /// </summary>
    private static readonly string[] SeparatorNextToAMark =
    [
        "../\u0301x", "/\u0301a", "/\u0301etc/passwd", "a//\u0301b", "./\u0301a", "../\u200Dx", "\u0600/../x",
    ];

    [Fact]
    public void IsSafeName_Cases()
    {
        Assert.True(ZipStoreReader.IsSafeName("manifest.json"));
        Assert.True(ZipStoreReader.IsSafeName("pages/0001.jpg"));
        Assert.True(ZipStoreReader.IsSafeName("pages/"));
        Assert.True(ZipStoreReader.IsSafeName("naïve dir/日本.txt"));
        Assert.True(ZipStoreReader.IsSafeName(".hidden"));
        Assert.True(ZipStoreReader.IsSafeName("a..b"));
        Assert.True(ZipStoreReader.IsSafeName(new string('a', 255)));
        Assert.False(ZipStoreReader.IsSafeName(new string('a', 256)));
        Assert.False(ZipStoreReader.IsSafeName(new string('é', 128)));
        Assert.False(ZipStoreReader.IsSafeName("pages//"));
        Assert.False(ZipStoreReader.IsSafeName("/"));
        Assert.False(ZipStoreReader.IsSafeName("a/b/../../c"));
        foreach (string name in SeparatorNextToAMark) Assert.False(ZipStoreReader.IsSafeName(name), name);
        Assert.True(ZipStoreReader.IsSafeName("a/\u0301b"));
        Assert.True(ZipStoreReader.IsSafeName("a\u0600/b"));
        Assert.True(ZipStoreReader.IsSafeName("a\u0600/"));
    }

    [Fact]
    public void FolderNames_EndWithTheSlashByte()
    {
        // "a" U+0600 "/": a folder, though its last grapheme is U+0600 and "/" together.
        string folder = "a\u0600/";
        using var reader = ZipStoreReader.Open(RawZip.Build([new RawEntry(folder, []), new RawEntry("b.txt", [1])]));
        Assert.Equal(["b.txt"], reader.Entries.Select(e => e.Name));
        AssertRefused(ZipReadErrorKind.DuplicateName, RawZip.Build([new RawEntry(folder[..^1], [1]), new RawEntry(folder, [])]));
    }

    [Fact]
    public void RefusesDuplicateNamesIgnoringCase()
    {
        AssertRefused(ZipReadErrorKind.DuplicateName, RawZip.Build([new RawEntry("a.jpg", [1]), new RawEntry("a.jpg", [2])]));
        AssertRefused(ZipReadErrorKind.DuplicateName, RawZip.Build([new RawEntry("pages/a.jpg", [1]), new RawEntry("PAGES/A.JPG", [2])]));
        // The same name composed and decomposed (as macOS file names often are).
        AssertRefused(ZipReadErrorKind.DuplicateName, RawZip.Build([new RawEntry("caf\u00E9.txt", [1]), new RawEntry("cafe\u0301.txt", [2])]));
        AssertRefused(ZipReadErrorKind.DuplicateName, RawZip.Build([new RawEntry("Pages/", []), new RawEntry("pages/", [])]));
        AssertRefused(ZipReadErrorKind.DuplicateName, RawZip.Build([new RawEntry("pages", [1]), new RawEntry("pages/", [])]));
    }

    [Fact]
    public void RefusesLinksAndSpecialFiles()
    {
        uint[] unixTypes = [0xA000, 0x2000, 0x6000, 0x1000, 0xC000];
        foreach (uint type in unixTypes)
        {
            AssertRefused(ZipReadErrorKind.SpecialFile,
                          RawZip.Build([new RawEntry("link", "target"u8.ToArray()) { MadeBy = 0x031E, External = (type | 0x1FF) << 16 }]));
        }
        // macOS's own host code, a symlink.
        AssertRefused(ZipReadErrorKind.SpecialFile,
                      RawZip.Build([new RawEntry("link", "target"u8.ToArray()) { MadeBy = 0x1314, External = 0xA1EDu << 16 }]));
        // A folder's type or attribute on a file, a file's type on a folder.
        AssertRefused(ZipReadErrorKind.SpecialFile, RawZip.Build([new RawEntry("a.txt", []) { MadeBy = 0x031E, External = 0x41EDu << 16 }]));
        AssertRefused(ZipReadErrorKind.SpecialFile, RawZip.Build([new RawEntry("a.txt", []) { External = 0x10 }]));
        AssertRefused(ZipReadErrorKind.SpecialFile, RawZip.Build([new RawEntry("dir/", []) { MadeBy = 0x031E, External = 0x81A4u << 16 }]));
        // Windows: a reparse point (a link) and a device.
        AssertRefused(ZipReadErrorKind.SpecialFile, RawZip.Build([new RawEntry("a.txt", [1]) { MadeBy = 0x0A3F, External = 0x420 }]));
        AssertRefused(ZipReadErrorKind.SpecialFile, RawZip.Build([new RawEntry("a.txt", [1]) { External = 0x40 }]));
    }

    [Fact]
    public void RefusesTooManyEntries()
    {
        var limits = ZipReadLimits.Standard with { MaxEntries = 2 };
        byte[] zip = ZipStore.Make([new("a", [1]), new("b", [2]), new("c", [3])]);
        var error = AssertRefused(ZipReadErrorKind.TooManyEntries, zip, limits);
        Assert.Equal("The archive holds more than 2 entries.", error.Message);
        using var reader = ZipStoreReader.Open(ZipStore.Make([new("a", [1]), new("b", [2])]), limits);
        Assert.Equal(2, reader.Entries.Count);
    }

    [Fact]
    public void RefusesEntriesPastTheSizeLimits()
    {
        var limits = ZipReadLimits.Standard with { MaxEntryBytes = 10, MaxTotalBytes = 15 };
        var one = AssertRefused(ZipReadErrorKind.TooLarge, ZipStore.Make([new("big.bin", new byte[11])]), limits);
        Assert.Equal("big.bin", one.EntryName);
        var all = AssertRefused(ZipReadErrorKind.TooLarge, ZipStore.Make([new("a.bin", new byte[10]), new("b.bin", new byte[10])]), limits);
        Assert.Null(all.EntryName);
        using var reader = ZipStoreReader.Open(ZipStore.Make([new("a.bin", new byte[10]), new("b.bin", new byte[5])]), limits);
        Assert.Equal(2, reader.Entries.Count);
        Assert.Equal("\"big.bin\" is larger than 256 MB.", ZipStoreReader.Message(ZipReadErrorKind.TooLarge, "big.bin"));
        Assert.Equal("The archive's contents are larger than 512 MB.", ZipStoreReader.Message(ZipReadErrorKind.TooLarge));
    }

    [Fact]
    public void RefusesBombSizes()
    {
        // A stored entry that claims to expand, and a local header that disagrees with the directory.
        AssertRefused(ZipReadErrorKind.SizeMismatch, RawZip.Build([new RawEntry("bomb.bin", new byte[10]) { Size = 10_000_000 }]));
        AssertRefused(ZipReadErrorKind.SizeMismatch, RawZip.Build([new RawEntry("bomb.bin", new byte[10]) { Compressed = 10_000_000, Size = 10_000_000 }]));
        AssertRefused(ZipReadErrorKind.SizeMismatch, RawZip.Build([new RawEntry("bomb.bin", new byte[10]) { LocalSize = 10_000_000, LocalCompressed = 10_000_000 }]));
        AssertRefused(ZipReadErrorKind.SizeMismatch, RawZip.Build([new RawEntry("dir/", [1, 2])]));
        // Two directory records sharing one entry's bytes (an overlapping bomb).
        byte[] zip = RawZip.Build([new RawEntry("a.bin", new byte[10]), new RawEntry("b.bin", new byte[10])], new RawEnd { SecondOffsetFromFirst = true });
        AssertRefused(ZipReadErrorKind.Corrupt, zip);
    }

    [Fact]
    public void RefusesLocalHeadersThatDisagree()
    {
        // The directory says stored, plain and this CRC; the local header says otherwise.
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { LocalFlags = 0x0008 }]));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { LocalFlags = 0x0001 }]));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { LocalFlags = 0x0800 }]));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { LocalMethod = 8 }]));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()) { LocalCrc = ZipStore.Crc32("hi"u8.ToArray()) + 1 }]));
        var error = AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1]), new RawEntry("b.txt", [2]) { LocalMethod = 8 }]));
        Assert.Equal("b.txt", error.EntryName);
    }

    [Fact]
    public void RefusesADirectoryPastItsLimit()
    {
        Assert.Equal(ZipStoreReader.MaxCentralDirectoryBytes, ZipReadLimits.Standard.MaxDirectoryBytes);
        Assert.Equal(64 * 1024 * 1024, ZipStoreReader.MaxCentralDirectoryBytes);
        var limits = ZipReadLimits.Standard with { MaxDirectoryBytes = 100 };
        // Each directory record here is 46 bytes and a 5-byte name: 153 bytes for three, 102 for two, 51 for one.
        var error = AssertRefused(ZipReadErrorKind.TooLarge, ZipStore.Make([new("a.txt", [1]), new("b.txt", [2]), new("c.txt", [3])]), limits);
        Assert.Null(error.EntryName);
        AssertRefused(ZipReadErrorKind.TooLarge, ZipStore.Make([new("a.txt", [1]), new("b.txt", [2])]), limits);
        using var reader = ZipStoreReader.Open(ZipStore.Make([new("a.txt", [1])]), limits);
        Assert.Single(reader.Entries);
        using var exact = ZipStoreReader.Open(ZipStore.Make([new("a.txt", [1]), new("b.txt", [2])]), limits with { MaxDirectoryBytes = 102 });
        Assert.Equal(2, exact.Entries.Count);
    }

    [Fact]
    public void RefusesACrcMismatchWhenReading()
    {
        byte[] zip = ZipStore.Make([new("a.txt", "hello"u8.ToArray())]);
        zip[30 + 5] ^= 0x01; // the first byte of the data
        using var reader = ZipStoreReader.Open(zip);
        var error = Assert.Throws<ZipReadException>(() => reader.Read(reader.Entries[0]));
        Assert.Equal(ZipReadErrorKind.CrcMismatch, error.Kind);
        Assert.Equal("\"a.txt\" is damaged: its checksum does not match its data.", error.Message);
        Assert.Throws<ZipReadException>(() => reader.CopyTo(reader.Entries[0], Stream.Null));
    }

    [Fact]
    public void RefusesTruncatedAndCorruptArchives()
    {
        byte[] zip = ZipStore.Make([new("a.txt", "hello"u8.ToArray()), new("b.txt", "world"u8.ToArray())]);
        AssertRefused(ZipReadErrorKind.Corrupt, []);
        AssertRefused(ZipReadErrorKind.Corrupt, "not a zip archive at all, just some text"u8.ToArray());
        AssertRefused(ZipReadErrorKind.Corrupt, zip[..^1]);
        AssertRefused(ZipReadErrorKind.Corrupt, zip[..(zip.Length / 2)]);
        AssertRefused(ZipReadErrorKind.Corrupt, zip[..^22]);
        // The directory's size or offset off by one, a record's signature broken.
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1])], new RawEnd { DirectorySizeDelta = -1 }));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1])], new RawEnd { DirectorySizeDelta = 1 }));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1])], new RawEnd { Count = 2, OnDisk = 2 }));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1])], new RawEnd { Count = 0, OnDisk = 0 }));
        byte[] broken = (byte[])zip.Clone();
        broken[30 + 5 + 5] = 0; // the second local header's signature
        AssertRefused(ZipReadErrorKind.Corrupt, broken);
        // A local header naming another file than its record, a second disk, bytes before the
        // first entry (a self-extractor) or after the last.
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1]) { LocalName = "b.txt"u8.ToArray() }]));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1])], new RawEnd { Disk = 1 }));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1])], new RawEnd { Prefix = "MZ"u8.ToArray() }));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1])], new RawEnd { Gap = 3 }));
        // An extra field whose blocks do not add up.
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1]) { CentralExtra = [0x55, 0x54, 0x09] }]));
        AssertRefused(ZipReadErrorKind.Corrupt, RawZip.Build([new RawEntry("a.txt", [1]) { LocalExtra = [0x55, 0x54, 0x09, 0x00, 0x01] }]));
    }

    [Fact]
    public void RawZip_MatchesZipStoreForPlainEntries()
    {
        byte[] expected = ZipStore.Make([new("a.txt", "hi"u8.ToArray()), new("naïve.txt", "é"u8.ToArray())]);
        byte[] raw = RawZip.Build([new RawEntry("a.txt", "hi"u8.ToArray()), new RawEntry("naïve.txt", "é"u8.ToArray()) { Flags = 0x0800 }]);
        Assert.Equal(expected, raw);
    }

    [Fact]
    public void Messages()
    {
        Assert.Equal("The archive is damaged or cut short.", ZipStoreReader.Message(ZipReadErrorKind.Corrupt));
        Assert.Equal("\"a.bin\" is compressed. Only archives of uncompressed (stored) entries can be read.",
                     ZipStoreReader.Message(ZipReadErrorKind.UnsupportedMethod, "a.bin"));
        Assert.Equal("\"a.bin\" is encrypted. Encrypted archives cannot be read.", ZipStoreReader.Message(ZipReadErrorKind.Encrypted, "a.bin"));
        Assert.Equal("The archive uses ZIP64 (for archives past 4 GB or 65,535 entries), which is not supported.",
                     ZipStoreReader.Message(ZipReadErrorKind.Zip64));
        Assert.Equal("\"a.bin\" keeps its sizes after its data (a data descriptor), which is not supported.",
                     ZipStoreReader.Message(ZipReadErrorKind.DataDescriptor, "a.bin"));
        Assert.Equal("The archive holds an entry with an unsafe name (\"../a\").", ZipStoreReader.Message(ZipReadErrorKind.UnsafeName, "../a"));
        Assert.Equal("The archive holds \"a.bin\" more than once.", ZipStoreReader.Message(ZipReadErrorKind.DuplicateName, "a.bin"));
        Assert.Equal("\"a\" is a link or a special file, not a plain file.", ZipStoreReader.Message(ZipReadErrorKind.SpecialFile, "a"));
        Assert.Equal("The archive holds more than 4096 entries.", ZipStoreReader.Message(ZipReadErrorKind.TooManyEntries));
        Assert.Equal("\"a.bin\" declares sizes that do not match its data.", ZipStoreReader.Message(ZipReadErrorKind.SizeMismatch, "a.bin"));
    }

    [Fact]
    public void Messages_ShowHostileNamesSafely()
    {
        // Controls, line separators and text-reordering marks become U+FFFD; past 80 scalars the name is cut.
        Assert.Equal("a\uFFFDb\uFFFDc\uFFFDd\uFFFDe\uFFFDf\uFFFDg\uFFFDh",
                     ZipStoreReader.DisplayName("a\u0000b\u001Fc\u007Fd\u0085e\u202Ef\u2028g\u2066h"));
        Assert.Equal("a\uFFFD\uFFFD\uFFFD\uFFFDb", ZipStoreReader.DisplayName("a\u200E\u200F\u061C\u2069b"));
        Assert.Equal("na\u00EFve \u65E5\u672C e\u0301 \u200D", ZipStoreReader.DisplayName("na\u00EFve \u65E5\u672C e\u0301 \u200D"));
        Assert.Equal(new string('a', 80), ZipStoreReader.DisplayName(new string('a', 80)));
        Assert.Equal(new string('a', 80) + "\u2026", ZipStoreReader.DisplayName(new string('a', 81)));
        // Scalars, not UTF-16 units: an astral character counts once.
        Assert.Equal(new string('a', 79) + "\uD83D\uDE00\u2026", ZipStoreReader.DisplayName(new string('a', 79) + "\uD83D\uDE00b"));
        Assert.Equal("", ZipStoreReader.DisplayName(""));

        string hostile = "x\n\nThis file needs an update. Go to evil.example and sign in.\n" + new string('a', 60_000);
        string shown = "x\uFFFD\uFFFDThis file needs an update. Go to evil.example and sign in.\uFFFD" + new string('a', 18) + "\u2026";
        Assert.Equal($"The archive holds an entry with an unsafe name (\"{shown}\").", ZipStoreReader.Message(ZipReadErrorKind.UnsafeName, hostile));
        var error = AssertRefused(ZipReadErrorKind.UnsafeName, RawZip.Build([new RawEntry(hostile, "hi"u8.ToArray())]));
        Assert.Equal($"The archive holds an entry with an unsafe name (\"{shown}\").", error.Message);
        Assert.Equal(hostile, error.EntryName);
        // A name that is safe as a path but reorders its text, refused for its method.
        error = AssertRefused(ZipReadErrorKind.UnsupportedMethod, RawZip.Build([new RawEntry("invoice\u202Efdp.exe", "hi"u8.ToArray()) { Method = 8 }]));
        Assert.Equal("\"invoice\uFFFDfdp.exe\" is compressed. Only archives of uncompressed (stored) entries can be read.", error.Message);
    }

    private static ZipReadException AssertRefused(ZipReadErrorKind kind, byte[] zip, ZipReadLimits? limits = null)
    {
        var error = Assert.Throws<ZipReadException>(() =>
        {
            using var reader = ZipStoreReader.Open(zip, limits);
            foreach (var entry in reader.Entries) reader.Read(entry);
        });
        Assert.Equal(kind, error.Kind);
        Assert.Equal(ZipStoreReader.Message(kind, error.EntryName, limits), error.Message);
        return error;
    }
}

/// <summary>One entry of a hand-built archive; every field the tests bend is settable.</summary>
internal sealed class RawEntry(byte[] name, byte[] data)
{
    public RawEntry(string name, byte[] data) : this(Encoding.UTF8.GetBytes(name), data) { }

    public byte[] Name { get; } = name;
    public byte[] Data { get; } = data;
    public ushort Flags { get; init; }
    public ushort Method { get; init; }
    public uint? Crc { get; init; }
    public ushort? LocalFlags { get; init; }
    public ushort? LocalMethod { get; init; }
    public uint? LocalCrc { get; init; }
    public uint? Compressed { get; init; }
    public uint? Size { get; init; }
    public ushort MadeBy { get; init; } = 20;
    public uint External { get; init; }
    public byte[] LocalExtra { get; init; } = [];
    public byte[] CentralExtra { get; init; } = [];
    public uint? LocalCompressed { get; init; }
    public uint? LocalSize { get; init; }
    public byte[]? LocalName { get; init; }
    public uint? CentralOffset { get; init; }
}

/// <summary>How a hand-built archive's end record and layout are bent.</summary>
internal sealed class RawEnd
{
    public byte[] Prefix { get; init; } = [];
    public int Gap { get; init; }
    public byte[] Comment { get; init; } = [];
    public bool Zip64Locator { get; init; }
    public ushort Disk { get; init; }
    public ushort? Count { get; init; }
    public ushort? OnDisk { get; init; }
    public int DirectorySizeDelta { get; init; }
    public uint? DirectoryOffset { get; init; }
    public bool SecondOffsetFromFirst { get; init; }
}

/// <summary>
/// Builds archives byte by byte the way ZipStore does (stored, 1980-01-01), with any field bent
/// for the malicious cases; the same builder is in ZipStoreReaderTests.swift.
/// </summary>
internal static class RawZip
{
    /// <summary>An extra-field block: its id, its size and that many zero bytes.</summary>
    public static byte[] Extra(ushort id, int size)
    {
        var block = new byte[4 + size];
        block[0] = (byte)id; block[1] = (byte)(id >> 8); block[2] = (byte)size; block[3] = (byte)(size >> 8);
        return block;
    }

    public static byte[] Build(IReadOnlyList<RawEntry> entries, RawEnd? end = null)
    {
        end ??= new RawEnd();
        var output = new List<byte>(end.Prefix);
        var central = new List<byte>();
        var offsets = new List<uint>();
        foreach (var entry in entries)
        {
            uint crc = entry.Crc ?? ZipStore.Crc32(entry.Data);
            uint size = entry.Size ?? (uint)entry.Data.Length;
            uint compressed = entry.Compressed ?? (uint)entry.Data.Length;
            uint offset = (uint)output.Count;
            offsets.Add(offset);
            byte[] localName = entry.LocalName ?? entry.Name;
            U32(output, 0x04034B50); U16(output, 10); U16(output, entry.LocalFlags ?? entry.Flags); U16(output, entry.LocalMethod ?? entry.Method);
            U16(output, 0); U16(output, 0x21); U32(output, entry.LocalCrc ?? crc);
            U32(output, entry.LocalCompressed ?? compressed); U32(output, entry.LocalSize ?? size);
            U16(output, localName.Length); U16(output, entry.LocalExtra.Length);
            output.AddRange(localName); output.AddRange(entry.LocalExtra); output.AddRange(entry.Data);

            uint centralOffset = entry.CentralOffset ?? (end.SecondOffsetFromFirst && offsets.Count == 2 ? offsets[0] : offset);
            U32(central, 0x02014B50); U16(central, entry.MadeBy); U16(central, 10); U16(central, entry.Flags);
            U16(central, entry.Method); U16(central, 0); U16(central, 0x21); U32(central, crc);
            U32(central, compressed); U32(central, size); U16(central, entry.Name.Length);
            U16(central, entry.CentralExtra.Length); U16(central, 0); U16(central, 0); U16(central, 0);
            U32(central, entry.External); U32(central, centralOffset);
            central.AddRange(entry.Name); central.AddRange(entry.CentralExtra);
        }
        output.AddRange(new byte[end.Gap]);
        uint directoryOffset = (uint)output.Count;
        output.AddRange(central);
        if (end.Zip64Locator)
        {
            U32(output, 0x07064B50); U32(output, 0); U32(output, 0); U32(output, 0); U32(output, 1);
        }
        U32(output, 0x06054B50); U16(output, end.Disk); U16(output, 0);
        U16(output, end.OnDisk ?? entries.Count); U16(output, end.Count ?? entries.Count);
        U32(output, (uint)(central.Count + end.DirectorySizeDelta)); U32(output, end.DirectoryOffset ?? directoryOffset);
        U16(output, end.Comment.Length); output.AddRange(end.Comment);
        return [.. output];
    }

    private static void U16(List<byte> b, int v) { b.Add((byte)v); b.Add((byte)(v >> 8)); }

    private static void U32(List<byte> b, uint v) { for (int i = 0; i < 4; i++) b.Add((byte)(v >> (8 * i))); }
}
