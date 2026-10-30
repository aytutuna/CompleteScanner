using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;
using LazyScan.Core;

namespace LazyScan.App.Services;

/// <summary>
/// A photo read for import: its pixels as stored, the turn its orientation tag asks for, its file's
/// name, and which page of the file it is (a TIFF may hold several; other files hold one).
/// </summary>
public sealed record PhotoFile(RgbaImage Stored, PhotoOrientation Orientation, string FileName, int Page = 1, int PageCount = 1)
{
    /// <summary>The name the user sees: the file's name, with the page when the file holds several (<see cref="PhotoImport.PageName"/>).</summary>
    public string DisplayName => PhotoImport.PageName(FileName, Page, PageCount);
}

/// <summary>A photo file that could not be read; <see cref="Exception.Message"/> says why, for the user.</summary>
public sealed class PhotoUnreadableException(string message, Exception? inner = null) : IOException(message, inner);

/// <summary>
/// Reads photos of documents for import (<see cref="PhotoImport"/>) with Windows' own decoders
/// (WIC): JPEG, PNG, TIFF, BMP, and HEIC and WebP where their Microsoft Store extensions are
/// installed. The file is read once into memory, shared with any app that has it open, and never
/// written, moved or locked. A TIFF file may hold several pages (a fax, a scan): each is read as a
/// photo of its own (<see cref="PageCount"/> says how many, <see cref="Decode"/> reads each); other
/// files give their main picture. The orientation tag is read, not applied: <see cref="PhotoImport.Oriented"/>
/// turns the pixels. The Mac's twin is in App/AppState+Import.swift (ImageIO).
/// </summary>
public static class PhotoFileReader
{
    /// <summary>
    /// Page <paramref name="page"/> (from 1) of the photo file at <paramref name="path"/>: <see cref="ReadBytes"/>,
    /// then <see cref="Decode"/>. Throws <see cref="PhotoUnreadableException"/> as they do.
    /// </summary>
    public static PhotoFile Read(string path, int page = 1) => Decode(ReadBytes(path), path, page);

    /// <summary>
    /// The bytes of the file at <paramref name="path"/>, read once and shared with any app that has it
    /// open. Throws <see cref="PhotoUnreadableException"/> with a message for the user when the file is
    /// gone or cannot be read.
    /// </summary>
    public static byte[] ReadBytes(string path)
    {
        string name = Path.GetFileName(path);
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var copy = new MemoryStream();
            stream.CopyTo(copy);
            return copy.ToArray();
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            throw new PhotoUnreadableException(PhotoImport.UnreadableMessage(name, PhotoImport.MissingDetail), e);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new PhotoUnreadableException(PhotoImport.UnreadableMessage(name, e.Message), e);
        }
        catch (OutOfMemoryException e)
        {
            throw new PhotoUnreadableException(PhotoImport.UnreadableMessage(name, PhotoImport.TooLargeDetail), e);
        }
    }

    /// <summary>
    /// How many pages the photo file <paramref name="bytes"/> holds: a TIFF's frames, 1 for other files
    /// and for files that cannot be read (<see cref="Decode"/> says why). Only the file's header is
    /// read, so a page that cannot be decoded does not hide the pages after it.
    /// </summary>
    public static int PageCount(byte[] bytes)
    {
        try
        {
            var decoder = BitmapDecoder.Create(new MemoryStream(bytes, writable: false), BitmapCreateOptions.None, BitmapCacheOption.None);
            return PagesIn(decoder);
        }
        catch (Exception e) when (e is NotSupportedException or FileFormatException or COMException or ArgumentException
                                      or InvalidOperationException or OverflowException or IOException or OutOfMemoryException)
        {
            return 1;
        }
    }

    private static int PagesIn(BitmapDecoder decoder) => decoder is TiffBitmapDecoder ? Math.Max(1, decoder.Frames.Count) : 1;

    /// <summary>
    /// Page <paramref name="page"/> (from 1) of the photo file <paramref name="bytes"/> read from
    /// <paramref name="path"/>; its <see cref="PhotoFile.PageCount"/> says how many pages the file holds.
    /// Throws <see cref="PhotoUnreadableException"/> with a message for the user when it cannot be read:
    /// not a picture, damaged, no such page, too large (more than <see cref="PhotoImport.MaxPhotoPixels"/>,
    /// or more than this PC's memory holds), or a HEIC photo while this PC has no HEIF decoder
    /// (<see cref="PhotoImport.HeifUnavailableMessage"/>).
    /// </summary>
    public static PhotoFile Decode(byte[] bytes, string path, int page = 1)
    {
        string name = Path.GetFileName(path);
        string shown = name;
        try
        {
            // Nothing is decoded until the pixels are copied (no cache): the size is read from the
            // file's header first, so a photo too large is turned down before its pixels take memory.
            var decoder = BitmapDecoder.Create(new MemoryStream(bytes, writable: false), BitmapCreateOptions.None, BitmapCacheOption.None);
            int pageCount = PagesIn(decoder);
            shown = PhotoImport.PageName(name, page, pageCount);
            if (page < 1 || page > pageCount)
            {
                throw new PhotoUnreadableException(PhotoImport.UnreadableMessage(shown, PhotoImport.UnreadableDetail));
            }
            var frame = decoder.Frames[page - 1];
            if ((long)frame.PixelWidth * frame.PixelHeight > PhotoImport.MaxPhotoPixels)
            {
                throw new PhotoUnreadableException(PhotoImport.UnreadableMessage(shown, PhotoImport.TooLargeDetail));
            }
            var orientation = PhotoOrientation.FromExif(OrientationTag(frame));
            return new PhotoFile(WpfImageCodec.FromBitmapSource(frame), orientation, name, page, pageCount);
        }
        catch (PhotoUnreadableException)
        {
            throw;
        }
        catch (OutOfMemoryException e)
        {
            // Also InsufficientMemoryException: a picture whose pixels do not fit in memory (or a
            // damaged header that claims so) is turned down on its own; the other photos go on.
            throw new PhotoUnreadableException(PhotoImport.UnreadableMessage(shown, PhotoImport.TooLargeDetail), e);
        }
        catch (Exception e) when (e is NotSupportedException or FileFormatException or COMException or ArgumentException
                                      or InvalidOperationException or OverflowException or IOException)
        {
            // A HEIC photo needs the HEIF extension (and, for most iPhone photos, the HEVC one): without
            // it WIC finds no decoder, or one that cannot decode the picture.
            if (PhotoImport.IsHeif(path)) throw new PhotoUnreadableException(PhotoImport.HeifUnavailableMessage(name), e);
            throw new PhotoUnreadableException(PhotoImport.UnreadableMessage(shown, PhotoImport.UnreadableDetail), e);
        }
    }

    /// <summary>The orientation tag (274) of the frame, 1 when it has none or it cannot be read.</summary>
    internal static int OrientationTag(BitmapFrame frame)
    {
        if (frame.Metadata is not BitmapMetadata metadata) return 1;
        // The policy name covers JPEG, TIFF and HEIF; the paths are the tag's place in JPEG and TIFF files.
        foreach (string query in new[] { "System.Photo.Orientation", "/app1/ifd/{ushort=274}", "/ifd/{ushort=274}" })
        {
            try
            {
                if (metadata.GetQuery(query) is { } value) return Convert.ToInt32(value, System.Globalization.CultureInfo.InvariantCulture);
            }
            catch (Exception e) when (e is NotSupportedException or ArgumentException or InvalidOperationException
                                          or COMException or FormatException or InvalidCastException or OverflowException)
            {
                // This file type has no such place: try the next.
            }
        }
        return 1;
    }
}
