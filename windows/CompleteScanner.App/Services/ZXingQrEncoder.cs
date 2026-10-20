using CompleteScanner.Core;
using ZXing;
using ZXing.QrCode;
using ZXing.QrCode.Internal;

namespace CompleteScanner.App.Services;

/// <summary>
/// Makes the QR code of a QR separator sheet (<see cref="QrSeparatorSheet"/>) with ZXing.Net: UTF-8
/// (marked as such in the code, so any reader decodes names in any script), error correction level
/// M, one bit per module and no quiet zone (the sheet draws its own). The Windows counterpart of the
/// Mac's <c>CoreImageQrEncoder</c>.
/// </summary>
public sealed class ZXingQrEncoder : IQrEncoder
{
    public QrModules? Encode(string text)
    {
        if (text.Length == 0) return null;
        try
        {
            var hints = new Dictionary<EncodeHintType, object>
            {
                [EncodeHintType.ERROR_CORRECTION] = ErrorCorrectionLevel.M,
                [EncodeHintType.CHARACTER_SET] = "UTF-8",
                [EncodeHintType.MARGIN] = 0,
            };
            var matrix = new QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, hints);
            if (matrix.Width != matrix.Height || matrix.Width == 0) return null;
            int size = matrix.Width;
            var dark = new bool[size * size];
            for (int y = 0; y < size; y++)
            {
                for (int x = 0; x < size; x++) dark[y * size + x] = matrix[x, y];
            }
            return new QrModules(size, dark);
        }
        catch (WriterException)
        {
            return null;
        }
    }
}
