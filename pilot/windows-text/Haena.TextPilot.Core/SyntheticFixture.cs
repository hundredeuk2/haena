using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;

namespace Haena.TextPilot.Core;

public static class SyntheticFixture
{
    public const string Id = "text-pilot-synthetic-v1";
    public const string Title = "Synthetic planning meeting";
    public const string Transcript = "We decided to use the blue draft.\nPrepare a comparison table.\nWhich review date works?\nDecide the review date at the next meeting.";
    public static readonly ImmutableArray<(OutputKind Kind, string Text)> Items =
    [
        (OutputKind.Decision, "We decided to use the blue draft."),
        (OutputKind.ActionItem, "Prepare a comparison table."),
        (OutputKind.OpenQuestion, "Which review date works?"),
        (OutputKind.NextAgenda, "Decide the review date at the next meeting.")
    ];

    public static void Validate(CaptureRequest request)
    {
        if (request.FixtureId is null) throw new PilotException(PilotError.FixtureRequired);
        if (request.FixtureId != Id) throw new PilotException(PilotError.UnknownFixture);
        // No text classification: only this explicitly selected, exact synthetic input is supported.
        if (!string.Equals(request.Transcript, Transcript, StringComparison.Ordinal))
            throw new PilotException(PilotError.FixtureTextMismatch);
        if (string.IsNullOrWhiteSpace(request.Title) || request.Title.Length > 200)
            throw new PilotException(PilotError.TitleRequired);
        if (request.CaptureId == Guid.Empty) throw new PilotException(PilotError.InvalidRequest);
    }

    internal static Guid Identity(Guid captureId, string component)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes($"haena.text-pilot.v1|{captureId:D}|{component}"));
        // Pilot-local ID, not the Mac transition UUID algorithm or a provider-selected domain ID.
        return new Guid(bytes.AsSpan(0, 16), bigEndian: true);
    }

    internal static ImmutableArray<PilotOutput> Outputs(PilotMeeting meeting) => Items.Select(item =>
        new PilotOutput(Identity(meeting.Id, item.Kind.ToString()), meeting.Id, item.Kind, item.Text,
            new PilotEvidence(meeting.Id, meeting.SegmentId, item.Text), ReviewVerdict.Pending, null))
        .ToImmutableArray();
}
