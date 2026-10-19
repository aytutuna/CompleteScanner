using System.Windows;

namespace CompleteScanner.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // Apply the saved appearance before the first window is created.
        ThemeService.Initialize();
        base.OnStartup(e);
    }
}
