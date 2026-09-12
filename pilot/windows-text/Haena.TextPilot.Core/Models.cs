using System.Collections.Immutable;

namespace Haena.TextPilot.Core;

// A deliberately separate pilot wire format. Never open or overwrite a Mac ProjectStoreFile.
public enum OutputKind { Decision, ActionItem, OpenQuestion, NextAgenda }
public enum ReviewVerdict { Pending, Approved, Excluded }
public enum PilotError
{
    FixtureRequired, UnknownFixture, FixtureTextMismatch, TitleRequired, InvalidRequest,
    CaptureConflict, UnknownOutput, TerminalVerdictConflict, InvalidVerdict,
    UnsupportedSchema, InvalidStore, StorageUnavailable, StoreBusy, UnsafeStoragePath
}
public sealed class PilotException(PilotError code) : Exception(code.ToString())
{
    public PilotError Code { get; } = code;
}

public sealed record PilotMeeting(Guid Id, Guid SegmentId, string Title, string Transcript, string FixtureId);
public sealed record PilotEvidence(Guid MeetingId, Guid SegmentId, string Quote);
public sealed record PilotOutput(Guid Id, Guid MeetingId, OutputKind Kind, string Text,
    PilotEvidence Evidence, ReviewVerdict Verdict, DateTimeOffset? ReviewedAt);
public sealed record PilotDocument(string Schema, ImmutableArray<PilotMeeting> Meetings,
    ImmutableArray<PilotOutput> Outputs)
{
    public const string CurrentSchema = "haena-windows-text-pilot-v1";
    public static PilotDocument Empty => new(CurrentSchema, [], []);
}
public sealed record CaptureRequest(Guid CaptureId, string? FixtureId, string Title, string Transcript);
public sealed record PilotBrief(ImmutableArray<PilotOutput> Decisions,
    ImmutableArray<PilotOutput> ActionItems, ImmutableArray<PilotOutput> OpenQuestions,
    ImmutableArray<PilotOutput> NextAgenda, ImmutableArray<PilotOutput> Pending,
    int ExcludedCount);

public interface IPilotRepository
{
    PilotDocument Read();
    PilotDocument Update(Func<PilotDocument, PilotDocument> mutation);
}
