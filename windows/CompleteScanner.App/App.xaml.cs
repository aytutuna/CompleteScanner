using System.Windows;

namespace CompleteScanner.App;

public partial class App : Application
{
    protected override void OnExit(ExitEventArgs e)
    {
        // Flush any debounced settings write on quit so a change made just before exit
        // is not lost (mirrors the macOS app's willTerminate hook).
        (MainWindow as MainWindow)?.ViewModel.FlushSettings();
        base.OnExit(e);
    }
}
