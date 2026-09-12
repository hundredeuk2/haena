using System.IO;
using System.Windows;
using Haena.TextPilot.Core;

namespace Haena.TextPilot.Wpf;

internal static class App
{
    [STAThread]
    public static void Main()
    {
        var application = new Application();
        try
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrEmpty(local)) throw new PilotException(PilotError.UnsafeStoragePath);
            // A dedicated pilot namespace, never the Mac store or a user-selected import file.
            var repository = new JsonPilotRepository(Path.Combine(local, "HAENA.WindowsTextPilot"));
            application.Run(new MainWindow(new PilotService(repository)));
        }
        catch (Exception error) when (error is PilotException or IOException or UnauthorizedAccessException)
        {
            MessageBox.Show("Pilot 저장소를 열지 못했습니다. 원본 파일은 자동 초기화하지 않습니다.", "HAE.NA Text Pilot");
        }
    }
}
