using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using Haena.TextPilot.Core;

namespace Haena.TextPilot.Wpf;

public sealed class MainWindow : Window
{
    private readonly PilotService service;
    private readonly ContentControl content = new();
    private readonly TextBlock message = Text("");
    private readonly TextBox title = new() { MinWidth = 300, Margin = new Thickness(0, 6, 0, 12) };
    private readonly TextBox transcript = new()
    {
        AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 190,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 6, 0, 12)
    };
    private readonly ComboBox fixture = new() { MinWidth = 270, Margin = new Thickness(0, 6, 0, 12) };
    private readonly StackPanel navigation = new() { Orientation = Orientation.Horizontal };
    private Guid captureId = Guid.NewGuid();
    private bool busy;

    public MainWindow(PilotService service)
    {
        this.service = service;
        Title = "HAE.NA Windows Text Pilot — Synthetic only";
        Width = 920; Height = 760; MinWidth = 560; MinHeight = 460;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        fixture.Items.Add("합성 fixture 선택 안 함");
        fixture.Items.Add(SyntheticFixture.Id);
        fixture.SelectedIndex = 0;
        AutomationProperties.SetAutomationId(fixture, "fixture-selector");
        AutomationProperties.SetName(fixture, "명시적 합성 fixture 선택");
        AutomationProperties.SetAutomationId(title, "meeting-title");
        AutomationProperties.SetName(title, "회의 제목");
        AutomationProperties.SetAutomationId(transcript, "transcript-input");
        AutomationProperties.SetName(transcript, "합성 원문");
        var layout = new DockPanel { Margin = new Thickness(20) };
        var header = new StackPanel();
        header.Children.Add(Text("합성 전용 · 실제 AI 호출 없음 · 담당자/기한 추론 없음", true));
        navigation.Children.Add(Button("1 붙여넣기", "navigate-paste", (_, _) => ShowPaste()));
        navigation.Children.Add(Button("2 결과 검토", "navigate-review", async (_, _) => await Run(ShowReview)));
        navigation.Children.Add(Button("3 Brief", "navigate-brief", async (_, _) => await Run(ShowBrief)));
        header.Children.Add(navigation);
        message.Foreground = Brushes.DarkRed;
        message.Margin = new Thickness(0, 10, 0, 10);
        AutomationProperties.SetAutomationId(message, "pilot-status");
        header.Children.Add(message);
        DockPanel.SetDock(header, Dock.Top);
        layout.Children.Add(header);
        layout.Children.Add(content);
        Content = layout;
        ShowPaste();
    }

    private void ShowPaste()
    {
        if (busy) return;
        // These controls are retained across navigation; failed save never clears the draft.
        content.Content = null;
        if (title.Parent is Panel old) old.Children.Clear();
        var page = new StackPanel();
        page.Children.Add(Text("붙여넣기", true));
        page.Children.Add(Text("fixture를 직접 선택하고 불러오세요. 임의 본문 또는 수정된 원문에는 분석 결과를 만들지 않습니다."));
        page.Children.Add(fixture);
        page.Children.Add(Button("선택한 fixture 불러오기 / 새 합성 회의", "load-fixture", (_, _) =>
        {
            if (fixture.SelectedIndex != 1) { message.Text = "합성 fixture를 먼저 선택하세요."; return; }
            title.Text = SyntheticFixture.Title; transcript.Text = SyntheticFixture.Transcript;
            captureId = Guid.NewGuid(); message.Text = "합성 fixture를 불러왔습니다. 아직 저장·승인하지 않았습니다.";
        }));
        page.Children.Add(Text("회의 제목")); page.Children.Add(title);
        page.Children.Add(Text("원문 (정확한 fixture만 지원)")); page.Children.Add(transcript);
        page.Children.Add(Button("회의와 pending 후보 저장 → 검토", "save-candidates", async (_, _) =>
        {
            var request = new CaptureRequest(captureId, fixture.SelectedIndex == 1 ? SyntheticFixture.Id : null, title.Text, transcript.Text);
            await Run(async () =>
            {
                await Task.Run(() => service.Capture(request));
                await ShowReview();
                message.Text = "저장 완료. 각 항목을 검토하기 전에는 승인되지 않습니다.";
            });
        }));
        content.Content = Scroll(page);
    }

    private async Task ShowReview()
    {
        var document = await Task.Run(service.Read);
        var page = new StackPanel();
        page.Children.Add(Text("결과 검토 — 개별 승인 / 제외", true));
        if (document.Outputs.IsEmpty) page.Children.Add(Text("저장된 후보가 없습니다. 붙여넣기 화면에서 합성 fixture를 저장하세요."));
        foreach (var output in document.Outputs.OrderBy(item => item.Kind).ThenBy(item => item.Id))
        {
            var card = Card(output, document);
            if (output.Verdict == ReviewVerdict.Pending)
            {
                var actions = new StackPanel { Orientation = Orientation.Horizontal };
                actions.Children.Add(Button("승인", $"approve-{output.Id:D}", async (_, _) => await Review(output.Id, ReviewVerdict.Approved)));
                actions.Children.Add(Button("제외", $"exclude-{output.Id:D}", async (_, _) => await Review(output.Id, ReviewVerdict.Excluded)));
                card.Children.Add(actions);
            }
            page.Children.Add(card);
        }
        content.Content = Scroll(page);
    }

    private async Task Review(Guid id, ReviewVerdict verdict) => await Run(async () =>
    {
        await Task.Run(() => service.Review(id, verdict));
        await ShowReview();
        message.Text = "이 항목의 판정을 저장했습니다. 다른 항목은 변경하지 않았습니다.";
    });

    private async Task ShowBrief()
    {
        var brief = await Task.Run(service.Brief);
        var document = await Task.Run(service.Read);
        var page = new StackPanel();
        page.Children.Add(Text("다음 회의 준비 / Brief", true));
        void Section(string name, IEnumerable<PilotOutput> outputs)
        {
            page.Children.Add(Text(name, true));
            var list = outputs.ToArray();
            if (list.Length == 0) page.Children.Add(Text("없음"));
            foreach (var item in list) page.Children.Add(Card(item, document));
        }
        Section("승인된 Decision", brief.Decisions);
        Section("승인된 Action Item", brief.ActionItems);
        Section("승인된 미해결 Open Question", brief.OpenQuestions);
        Section("승인된 Next Agenda", brief.NextAgenda);
        Section("미검토 후보 — 승인된 상태 아님", brief.Pending);
        page.Children.Add(Text($"제외된 항목 {brief.ExcludedCount}개 — 결과 검토에서 확인할 수 있습니다."));
        page.Children.Add(Text("진행 상태 변경·transition apply·ambiguity 해결은 이 pilot에서 지원하지 않습니다."));
        content.Content = Scroll(page);
    }

    private static StackPanel Card(PilotOutput output, PilotDocument document)
    {
        var card = new StackPanel { Margin = new Thickness(0, 8, 0, 12) };
        card.Children.Add(Text($"{output.Kind} · {output.Verdict}", true));
        card.Children.Add(Text(output.Text));
        if (output.Kind == OutputKind.ActionItem) card.Children.Add(Text("담당자 미지정 · 기한 미지정 (이 pilot은 편집/추론하지 않음)"));
        var meeting = document.Meetings.Single(item => item.Id == output.MeetingId);
        var source = new StackPanel();
        source.Children.Add(Text($"회의: {meeting.Title}"));
        source.Children.Add(Text($"Segment: {output.Evidence.SegmentId:D}"));
        source.Children.Add(Text($"근거: {output.Evidence.Quote}"));
        source.Children.Add(Text(meeting.Transcript));
        card.Children.Add(new Expander { Header = "근거와 전체 합성 원문", Content = source });
        return card;
    }

    private async Task Run(Func<Task> action)
    {
        if (busy) return;
        busy = true; navigation.IsEnabled = false; content.IsEnabled = false; message.Text = "처리 중…";
        try { await action(); }
        catch (PilotException error) { message.Text = Explain(error.Code); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { message.Text = "저장소에 접근하지 못했습니다. 입력과 기존 판정은 자동 초기화하지 않습니다."; }
        finally { busy = false; navigation.IsEnabled = true; content.IsEnabled = true; }
        if (message.Text == "처리 중…") message.Text = "저장 상태를 읽었습니다.";
    }

    private static string Explain(PilotError code) => code switch
    {
        PilotError.FixtureRequired => "합성 fixture를 명시적으로 선택하세요.",
        PilotError.UnknownFixture or PilotError.FixtureTextMismatch => "선택한 fixture와 원문이 다릅니다. 임의 본문을 분석하지 않습니다. 입력은 유지됩니다.",
        PilotError.TitleRequired => "회의 제목을 1~200자로 입력하세요.",
        PilotError.CaptureConflict => "이미 저장된 입력과 다릅니다. 새 fixture 회의를 명시적으로 시작하세요.",
        PilotError.StoreBusy => "다른 pilot 프로세스가 저장 중입니다. 자동 재시도하지 않았습니다.",
        PilotError.TerminalVerdictConflict => "이미 확정된 판정을 이 pilot에서 덮어쓸 수 없습니다.",
        PilotError.InvalidStore or PilotError.UnsupportedSchema or PilotError.UnsafeStoragePath => "저장 형식 또는 경로를 확인할 수 없습니다. 원본은 자동 초기화하지 않습니다.",
        _ => "작업을 완료하지 못했습니다. 이전 저장 상태와 입력을 확인하세요."
    };

    private static TextBlock Text(string value, bool heading = false) => new()
    {
        Text = value, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 3),
        FontSize = heading ? 17 : 14, FontWeight = heading ? FontWeights.SemiBold : FontWeights.Normal
    };
    private static Button Button(string label, string id, RoutedEventHandler handler)
    {
        var button = new Button { Content = label, Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 4, 8, 4) };
        AutomationProperties.SetAutomationId(button, id); button.Click += handler; return button;
    }
    private static ScrollViewer Scroll(UIElement child) => new() { Content = child, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
}
