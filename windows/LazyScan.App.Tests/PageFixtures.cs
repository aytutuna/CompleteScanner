using System.IO;
using System.Text.Json;
using LazyScan.App.Services;
using LazyScan.Core;
using Xunit;

namespace LazyScan.App.Tests;

// Twin of Tests/CompleteScannerModelTests/PageFixtures.swift: both suites read the SmartDoc frames in
// Tests/Fixtures/Pages (copied next to this assembly by the project file) and their corners.json.

/// <summary>A photo among the page fixtures and its page's corners in its pixels, named by position (<see cref="Quad.FromCorners"/>).</summary>
internal sealed record PagePhoto(string File, int Width, int Height, Quad Truth);

internal static class PageFixtures
{
    public static string Folder => Path.Combine(AppContext.BaseDirectory, "Fixtures", "Pages");

    /// <summary>The photos listed in corners.json, in its order.</summary>
    public static IReadOnlyList<PagePhoto> All()
    {
        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(Folder, "corners.json")));
        var photos = new List<PagePhoto>();
        foreach (var entry in json.RootElement.EnumerateArray())
        {
            var corners = new[] { "topLeft", "topRight", "bottomRight", "bottomLeft" }
                .Select(name => entry.GetProperty(name))
                .Select(p => new PointD(p[0].GetDouble(), p[1].GetDouble()))
                .ToArray();
            photos.Add(new PagePhoto(entry.GetProperty("file").GetString()!, entry.GetProperty("width").GetInt32(),
                                     entry.GetProperty("height").GetInt32(), Quad.FromCorners(corners)));
        }
        return photos;
    }

    /// <summary>The photo's pixels, read as the app reads an imported photo.</summary>
    public static RgbaImage Read(PagePhoto photo) => PhotoFileReader.Read(Path.Combine(Folder, photo.File)).Stored;
}

public class PageFixturesTests
{
    [Fact]
    public void EveryPagePhotoReadsAtItsSizeWithItsPageInIt()
    {
        var photos = PageFixtures.All();
        Assert.Equal(6, photos.Count);
        foreach (var photo in photos)
        {
            var image = PageFixtures.Read(photo);
            Assert.Equal((photo.Width, photo.Height), (image.Width, image.Height));
            Assert.True(photo.Truth.IsConvex, photo.File);
            Assert.True(photo.Truth.IsInside(image.Width, image.Height), photo.File);
        }
    }
}
