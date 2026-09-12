using System.Text.Json;
using System.Text.Json.Serialization;

namespace Haena.TextPilot.Core;

public sealed class JsonPilotRepository : IPilotRepository
{
    private const long MaximumBytes = 1_048_576;
    private readonly string root;
    private readonly Action? beforeReplace;
    public string FilePath => Path.Combine(root, "text-pilot.json");
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter(allowIntegerValues: false) },
        WriteIndented = true
    };

    public JsonPilotRepository(string directory) : this(directory, null) { }
    internal JsonPilotRepository(string directory, Action? beforeReplace)
    {
        root = Path.GetFullPath(directory);
        this.beforeReplace = beforeReplace;
        CheckPath();
    }

    public PilotDocument Read()
    {
        try
        {
            CheckPath();
            if (!File.Exists(FilePath)) return PilotDocument.Empty;
            using var file = new FileStream(FilePath, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            if (file.Length > MaximumBytes) throw new PilotException(PilotError.InvalidStore);
            var document = JsonSerializer.Deserialize<PilotDocument>(file, JsonOptions)
                ?? throw new PilotException(PilotError.InvalidStore);
            Validate(document);
            return document;
        }
        catch (JsonException) { throw new PilotException(PilotError.InvalidStore); }
        catch (IOException) { throw new PilotException(PilotError.StorageUnavailable); }
        catch (UnauthorizedAccessException) { throw new PilotException(PilotError.StorageUnavailable); }
    }

    public PilotDocument Update(Func<PilotDocument, PilotDocument> mutation)
    {
        try
        {
            CheckPath();
            Directory.CreateDirectory(root);
            // A bounded single-writer contract across repository instances/processes: fail busy,
            // never read a stale cache and overwrite another writer's snapshot.
            using var lease = AcquireWriter();
            var prior = Read();
            var next = mutation(prior);
            Validate(next);
            var previousBytes = JsonSerializer.SerializeToUtf8Bytes(prior, JsonOptions);
            var bytes = JsonSerializer.SerializeToUtf8Bytes(next, JsonOptions);
            if (previousBytes.AsSpan().SequenceEqual(bytes)) return prior;
            if (bytes.Length > MaximumBytes) throw new PilotException(PilotError.InvalidStore);

            var temporary = Path.Combine(root, $".text-pilot-{Guid.NewGuid():N}.tmp");
            try
            {
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                    4096, FileOptions.WriteThrough))
                {
                    stream.Write(bytes);
                    stream.Flush(flushToDisk: true);
                }
                beforeReplace?.Invoke(); // Internal fault seam; not a production environment hook.
                File.Move(temporary, FilePath, overwrite: true);
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
            return next;
        }
        catch (IOException) { throw new PilotException(PilotError.StorageUnavailable); }
        catch (UnauthorizedAccessException) { throw new PilotException(PilotError.StorageUnavailable); }
    }

    private FileStream AcquireWriter()
    {
        try { return new FileStream(Path.Combine(root, ".writer.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { throw new PilotException(PilotError.StoreBusy); }
    }

    private void CheckPath()
    {
        for (DirectoryInfo? directory = new(root); directory is not null; directory = directory.Parent)
            if (directory.LinkTarget is not null || (directory.Exists && (directory.Attributes & FileAttributes.ReparsePoint) != 0))
                throw new PilotException(PilotError.UnsafeStoragePath);
        foreach (var name in new[] { "text-pilot.json", ".writer.lock" })
        {
            var file = new FileInfo(Path.Combine(root, name));
            if (file.LinkTarget is not null || (file.Exists && (file.Attributes & FileAttributes.ReparsePoint) != 0))
                throw new PilotException(PilotError.UnsafeStoragePath);
        }
    }

    internal static void Validate(PilotDocument document)
    {
        if (document.Schema != PilotDocument.CurrentSchema) throw new PilotException(PilotError.UnsupportedSchema);
        if (document.Meetings.IsDefault || document.Outputs.IsDefault || document.Meetings.Length > 100 || document.Outputs.Length > 400)
            throw new PilotException(PilotError.InvalidStore);
        var ids = new HashSet<Guid>();
        foreach (var meeting in document.Meetings)
        {
            if (meeting is null || meeting.Id == Guid.Empty || meeting.SegmentId == Guid.Empty ||
                !ids.Add(meeting.Id) || !ids.Add(meeting.SegmentId) || string.IsNullOrWhiteSpace(meeting.Title) ||
                meeting.Title.Length > 200 || meeting.FixtureId != SyntheticFixture.Id || meeting.Transcript != SyntheticFixture.Transcript ||
                meeting.SegmentId != SyntheticFixture.Identity(meeting.Id, "segment"))
                throw new PilotException(PilotError.InvalidStore);
        }
        foreach (var output in document.Outputs)
        {
            if (output is null || output.Id == Guid.Empty || !ids.Add(output.Id) || !Enum.IsDefined(output.Kind) ||
                !Enum.IsDefined(output.Verdict) || output.Evidence is null || string.IsNullOrWhiteSpace(output.Text))
                throw new PilotException(PilotError.InvalidStore);
            var meeting = document.Meetings.SingleOrDefault(item => item.Id == output.MeetingId);
            if (meeting is null || output.Evidence.MeetingId != meeting.Id || output.Evidence.SegmentId != meeting.SegmentId ||
                output.Id != SyntheticFixture.Identity(meeting.Id, output.Kind.ToString()) ||
                output.Text != SyntheticFixture.Items.Single(item => item.Kind == output.Kind).Text ||
                output.Evidence.Quote != output.Text || !meeting.Transcript.Contains(output.Evidence.Quote, StringComparison.Ordinal) ||
                (output.Verdict == ReviewVerdict.Pending) != (output.ReviewedAt is null) ||
                (output.ReviewedAt is { } date && date.Offset != TimeSpan.Zero))
                throw new PilotException(PilotError.InvalidStore);
        }
    }
}
