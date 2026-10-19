using System.Globalization;
using System.Windows.Data;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>One-line description of a preset for the sidebar, e.g. "300 dpi · Color · PDF".</summary>
public sealed class PresetSummaryConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is Preset { Settings: var s }
            ? $"{s.Resolution} dpi · {s.ColorMode.Label()} · {s.Format.Label()}"
            : "";

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
