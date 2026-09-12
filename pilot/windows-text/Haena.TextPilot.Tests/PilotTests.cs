using System.Security.Cryptography;
using System.Text.Json;
using Haena.TextPilot.Core;
using Xunit;

namespace Haena.TextPilot.Tests;

public sealed class PilotTests : IDisposable
{
    private readonly string root = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "haena-pilot-test-" + Guid.NewGuid().ToString("N"));
    private static readonly DateTimeOffset Instant = new(2026, 9, 12, 12, 0, 0, TimeSpan.Zero);
    private static CaptureRequest Request(Guid? id = null) => new(id ?? Guid.NewGuid(), SyntheticFixture.Id, SyntheticFixture.Title, SyntheticFixture.Transcript);
    private JsonPilotRepository Repository() => new(root);
    private PilotService Service() => new(Repository(), () => Instant);
    private static void Refuses(PilotError error, Action action) => Assert.Equal(error, Assert.Throws<PilotException>(action).Code);
    private string Hash() => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Repository().FilePath)));
    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }

    [Fact]
    public void SyntheticCaptureIndividualReviewFreshRepositoryBriefJourney()
    {
        var request = Request();
        var meeting = Service().Capture(request);
        var pending = Service().Read();
        Assert.Equal(request.Transcript, Assert.Single(pending.Meetings).Transcript);
        Assert.Equal(4, pending.Outputs.Length);
        Assert.All(pending.Outputs, item => Assert.Equal(ReviewVerdict.Pending, item.Verdict));
        Assert.Empty(Service().Brief().Decisions);
        var decision = pending.Outputs.Single(item => item.Kind == OutputKind.Decision);
        var action = pending.Outputs.Single(item => item.Kind == OutputKind.ActionItem);
        Service().Review(decision.Id, ReviewVerdict.Approved);
        Service().Review(action.Id, ReviewVerdict.Excluded);

        var fresh = Service(); // Rebuilds both repository and service: no in-memory cache survives.
        var brief = fresh.Brief();
        Assert.Equal(decision.Id, Assert.Single(brief.Decisions).Id);
        Assert.Empty(brief.ActionItems);
        Assert.Empty(brief.NextAgenda);
        Assert.Equal(2, brief.Pending.Length);
        Assert.Equal(1, brief.ExcludedCount);
        Assert.Equal(meeting, Assert.Single(fresh.Read().Meetings));
        Assert.Equal(Instant, fresh.Read().Outputs.Single(item => item.Id == decision.Id).ReviewedAt);
    }

    [Theory]
    [InlineData(OutputKind.Decision)] [InlineData(OutputKind.ActionItem)]
    [InlineData(OutputKind.OpenQuestion)] [InlineData(OutputKind.NextAgenda)]
    public void EachKindRequiresItsOwnApproval(OutputKind kind)
    {
        Service().Capture(Request());
        var item = Service().Read().Outputs.Single(item => item.Kind == kind);
        Service().Review(item.Id, ReviewVerdict.Approved);
        var brief = Service().Brief();
        Assert.Single(brief.Decisions.Concat(brief.ActionItems).Concat(brief.OpenQuestions).Concat(brief.NextAgenda));
        Assert.Equal(3, brief.Pending.Length);
    }

    [Theory]
    [InlineData(null, PilotError.FixtureRequired)]
    [InlineData("unknown", PilotError.UnknownFixture)]
    public void UnselectedOrUnknownFixtureNeverAccessesRepository(string? fixture, PilotError expected)
    {
        var spy = new ForbiddenRepository();
        Refuses(expected, () => new PilotService(spy).Capture(Request() with { FixtureId = fixture }));
        Assert.Equal(0, spy.Accesses);
    }

    [Theory]
    [InlineData("arbitrary pasted text")]
    [InlineData("")]
    [InlineData("We decided to use the blue draft.")]
    public void DifferentTranscriptNeverReceivesFixedOutputs(string text)
    {
        var spy = new ForbiddenRepository();
        Refuses(PilotError.FixtureTextMismatch, () => new PilotService(spy).Capture(Request() with { Transcript = text }));
        Assert.Equal(0, spy.Accesses);
    }

    [Fact] public void EmptyTitleAndCaptureIdentityAreRejectedBeforeStorage()
    {
        var spy = new ForbiddenRepository();
        Refuses(PilotError.TitleRequired, () => new PilotService(spy).Capture(Request() with { Title = " " }));
        Refuses(PilotError.InvalidRequest, () => new PilotService(spy).Capture(Request(Guid.Empty)));
        Assert.Equal(0, spy.Accesses);
    }

    [Fact] public void RetryAndRepeatedVerdictPreserveBytesAndIds()
    {
        var request = Request();
        Service().Capture(request);
        var item = Service().Read().Outputs[0];
        Service().Review(item.Id, ReviewVerdict.Approved);
        var before = Hash();
        Service().Capture(request);
        Service().Review(item.Id, ReviewVerdict.Approved);
        _ = Service().Brief();
        Assert.Equal(before, Hash());
        Assert.Single(Service().Read().Meetings);
        Assert.Equal(4, Service().Read().Outputs.Length);
    }

    [Fact] public void ConflictingCaptureCannotOverwriteMeeting()
    {
        var request = Request(); Service().Capture(request); var before = Hash();
        Refuses(PilotError.CaptureConflict, () => Service().Capture(request with { Title = "changed" }));
        Assert.Equal(before, Hash());
    }

    [Fact] public void TerminalVerdictAndInvalidReviewAreFailClosed()
    {
        Service().Capture(Request()); var id = Service().Read().Outputs[0].Id;
        Service().Review(id, ReviewVerdict.Excluded); var before = Hash();
        Refuses(PilotError.TerminalVerdictConflict, () => Service().Review(id, ReviewVerdict.Approved));
        Refuses(PilotError.UnknownOutput, () => Service().Review(Guid.NewGuid(), ReviewVerdict.Approved));
        Refuses(PilotError.InvalidVerdict, () => Service().Review(id, ReviewVerdict.Pending));
        Assert.Equal(before, Hash());
    }

    [Fact] public void CandidateSaveFailureKeepsMeetingAndRetryCompletesWithoutDuplicate()
    {
        var request = Request(); var underlying = Repository();
        Refuses(PilotError.StorageUnavailable, () => new PilotService(new FailSecondWrite(underlying)).Capture(request));
        Assert.Single(Service().Read().Meetings); Assert.Empty(Service().Read().Outputs);
        Service().Capture(request);
        Assert.Single(Service().Read().Meetings); Assert.Equal(4, Service().Read().Outputs.Length);
    }

    [Fact] public void AtomicReplaceFailurePreservesPreviousBytesAndNoTemporaryFile()
    {
        Service().Capture(Request()); var before = Hash(); var id = Service().Read().Outputs[0].Id;
        var failing = new JsonPilotRepository(root, () => throw new IOException("synthetic private path"));
        var error = Assert.Throws<PilotException>(() => new PilotService(failing).Review(id, ReviewVerdict.Approved));
        Assert.Equal(PilotError.StorageUnavailable, error.Code); Assert.DoesNotContain("path", error.Message);
        Assert.Equal(before, Hash()); Assert.Empty(Directory.GetFiles(root, "*.tmp"));
    }

    [Fact] public void FirstWriteFailureDoesNotPublishMeeting()
    {
        var failing = new JsonPilotRepository(root, () => throw new IOException());
        Refuses(PilotError.StorageUnavailable, () => new PilotService(failing).Capture(Request()));
        Assert.Empty(Service().Read().Meetings); Assert.False(File.Exists(Repository().FilePath));
    }

    [Theory]
    [InlineData("{broken", PilotError.InvalidStore)]
    [InlineData("{\"schema\":\"future\",\"meetings\":[],\"outputs\":[]}", PilotError.UnsupportedSchema)]
    [InlineData("{\"schema\":\"haena-windows-text-pilot-v1\",\"meetings\":[],\"outputs\":[],\"unknown\":true}", PilotError.InvalidStore)]
    public void BadStoreIsNotOverwritten(string json, PilotError code)
    {
        Directory.CreateDirectory(root); File.WriteAllText(Repository().FilePath, json);
        Refuses(code, () => Service().Capture(Request()));
        Assert.Equal(json, File.ReadAllText(Repository().FilePath));
    }

    [Theory] [InlineData("evidence")] [InlineData("identity")] [InlineData("duplicate")] [InlineData("review")]
    public void InvalidReferenceOrStateIsRejected(string mutation)
    {
        Service().Capture(Request()); var document = Service().Read(); var item = document.Outputs[0];
        var changed = mutation switch
        {
            "evidence" => item with { Evidence = item.Evidence with { SegmentId = Guid.NewGuid() } },
            "identity" => item with { Id = Guid.NewGuid() },
            "review" => item with { Verdict = ReviewVerdict.Approved, ReviewedAt = null },
            _ => item
        };
        document = document with { Outputs = mutation == "duplicate" ? document.Outputs.Add(item) : document.Outputs.Replace(item, changed) };
        File.WriteAllBytes(Repository().FilePath, JsonSerializer.SerializeToUtf8Bytes(document, JsonPilotRepository.JsonOptions));
        Refuses(PilotError.InvalidStore, () => Service().Read());
    }

    [Fact] public void ActiveWriterRejectsSecondWriterWithoutOverwriting()
    {
        Service().Capture(Request()); var before = Hash();
        using var lease = new FileStream(Path.Combine(root, ".writer.lock"), FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        Refuses(PilotError.StoreBusy, () => Service().Capture(Request()));
        Assert.Equal(before, Hash());
    }

    [Fact] public void SymlinkStoreIsRejectedWithoutReadingTarget()
    {
        Directory.CreateDirectory(root);
        var target = Path.Combine(root, "untouched.txt"); File.WriteAllText(target, "do not read or mutate");
        File.CreateSymbolicLink(Path.Combine(root, "text-pilot.json"), target);
        Refuses(PilotError.UnsafeStoragePath, () => Repository());
        Assert.Equal("do not read or mutate", File.ReadAllText(target));
    }

    private sealed class ForbiddenRepository : IPilotRepository
    {
        public int Accesses { get; private set; }
        public PilotDocument Read() { Accesses++; throw new InvalidOperationException(); }
        public PilotDocument Update(Func<PilotDocument, PilotDocument> mutation) { Accesses++; throw new InvalidOperationException(); }
    }
    private sealed class FailSecondWrite(IPilotRepository inner) : IPilotRepository
    {
        private int writes;
        public PilotDocument Read() => inner.Read();
        public PilotDocument Update(Func<PilotDocument, PilotDocument> mutation) => ++writes == 2
            ? throw new PilotException(PilotError.StorageUnavailable) : inner.Update(mutation);
    }
}
