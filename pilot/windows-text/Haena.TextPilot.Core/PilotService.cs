using System.Collections.Immutable;

namespace Haena.TextPilot.Core;

public sealed class PilotService(IPilotRepository repository, Func<DateTimeOffset>? clock = null)
{
    private readonly Func<DateTimeOffset> now = clock ?? (() => DateTimeOffset.UtcNow);

    public PilotDocument Read() => repository.Read();

    public PilotMeeting Capture(CaptureRequest request)
    {
        SyntheticFixture.Validate(request); // Before any storage access.
        var meeting = new PilotMeeting(request.CaptureId, SyntheticFixture.Identity(request.CaptureId, "segment"),
            request.Title.Trim(), request.Transcript, request.FixtureId!);
        // Meeting must reach storage before candidates. Failure in phase 2 must not roll it back.
        repository.Update(document =>
        {
            var existing = document.Meetings.SingleOrDefault(item => item.Id == meeting.Id);
            if (existing is not null && existing != meeting) throw new PilotException(PilotError.CaptureConflict);
            return existing is null ? document with { Meetings = document.Meetings.Add(meeting) } : document;
        });
        repository.Update(document =>
        {
            var outputs = document.Outputs;
            foreach (var proposed in SyntheticFixture.Outputs(meeting))
            {
                // Stable capture identity makes retry safe and preserves every existing verdict.
                if (!outputs.Any(item => item.Id == proposed.Id)) outputs = outputs.Add(proposed);
            }
            return document with { Outputs = outputs };
        });
        return meeting;
    }

    public void Review(Guid outputId, ReviewVerdict verdict)
    {
        if (verdict is not (ReviewVerdict.Approved or ReviewVerdict.Excluded))
            throw new PilotException(PilotError.InvalidVerdict);
        repository.Update(document =>
        {
            var item = document.Outputs.SingleOrDefault(output => output.Id == outputId)
                ?? throw new PilotException(PilotError.UnknownOutput);
            if (item.Verdict == verdict) return document;
            if (item.Verdict != ReviewVerdict.Pending) throw new PilotException(PilotError.TerminalVerdictConflict);
            return document with
            {
                Outputs = document.Outputs.Replace(item, item with { Verdict = verdict, ReviewedAt = now().ToUniversalTime() })
            };
        });
    }

    public PilotBrief Brief()
    {
        var outputs = repository.Read().Outputs.OrderBy(item => item.Kind).ThenBy(item => item.Id).ToImmutableArray();
        ImmutableArray<PilotOutput> Approved(OutputKind kind) => outputs
            .Where(item => item.Kind == kind && item.Verdict == ReviewVerdict.Approved).ToImmutableArray();
        return new(Approved(OutputKind.Decision), Approved(OutputKind.ActionItem), Approved(OutputKind.OpenQuestion),
            Approved(OutputKind.NextAgenda), outputs.Where(item => item.Verdict == ReviewVerdict.Pending).ToImmutableArray(),
            outputs.Count(item => item.Verdict == ReviewVerdict.Excluded));
    }
}
