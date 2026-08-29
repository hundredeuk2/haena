# Audio/STT Benchmark Runner & Scorer v0

## Scope

This development-only harness measures a normalized STT plus diarization result against source-
aligned reference segments. It does not tune a model, review gold, score Meeting Execution meaning,
or authorize any external upload. The offline fake provider validates the pipeline only; its numbers
are not STT quality results.

```text
authorized development metadata
→ one temporary WAV clip
→ normalized provider transcript
→ time-overlap speaker assignment
→ Audio/STT metrics
→ transcript-free case and aggregate reports
```

## Normalized prediction contract

`PredictedTranscript` contains only a provider identifier, model identifier, processing wall-clock
duration, clip duration, and `PredictedSegment` values. Each segment contains start seconds, end
seconds, a predicted speaker label, and text.

A prediction is rejected rather than silently repaired when a time is absent or non-finite, a time
is negative, `end <= start`, `end` exceeds the clip duration, the speaker label is empty after
trimming, or text is empty after trimming. A zero-duration clip is invalid. v0 does not clamp an
out-of-range provider timestamp because clamping would hide a provider-contract failure. Reference
and prediction inputs with simultaneous overlapping segments are reported as unsupported in v0;
the current source-aligned corpus has no overlap label, and overlap must not be scored incorrectly.

The normalized value, not the provider's raw response, is the only provider result allowed past the
adapter. API keys, request headers, absolute paths, and raw response bodies never enter a report.

## Frozen metric definitions

| Metric | v0 definition | Undefined / edge rule |
| --- | --- | --- |
| CER | Reference `text_normalized` and normalized prediction text are converted to Unicode NFC; all Unicode whitespace and punctuation-category scalars are removed. Levenshtein insertion + deletion + substitution distance is computed over Swift `Character` values and divided by the number of reference characters. | An empty normalized reference is not calculable (`empty_reference_text`), including when prediction is also empty. A non-empty reference with empty prediction is `1`. |
| Speaker count error | `distinct predicted speaker labels - distinct reference speaker labels`, a signed integer after input validation. | Positive means extra speakers; negative means missed speakers. |
| DER | A boundary sweep totals `miss + false alarm + speaker confusion`, divided by reference speaker time. The collar is `0.0 s`. Silence with prediction is false alarm; reference speech with no prediction is miss; simultaneous active labels that differ after optimal mapping are confusion. | Empty prediction with reference speech is `1`. Zero reference speaker time is not calculable. Any prediction/reference overlap rejects scoring with `overlapping_prediction_segments` / `overlapping_reference_segments` in v0. |
| Speaker attribution accuracy | Correctly mapped predicted-speaker time overlapping the corresponding reference speaker, divided by total reference speaker time. Missed reference speech therefore counts as incorrect. | Zero reference speaker time is not calculable; empty prediction with reference speech is `0`. |
| Target speaker B F1 | After optimal mapping: `TP` is time where reference B and its mapped predicted speaker overlap, `FP` is mapped-B prediction outside reference B, and `FN` is reference-B time not covered by mapped-B. `F1 = 2TP / (2TP + FP + FN)`. | A reference with no B is not calculable (`target_speaker_absent`). If B exists but has no predicted match, precision, recall, and F1 are `0`. |
| Speaker-attributed CER | After mapping, reference and prediction text are concatenated chronologically per reference speaker. Levenshtein numerators are summed across speaker streams. Text from unmatched predicted speakers contributes insertions. The denominator is the total normalized reference character count. | The same empty-reference rules as CER apply. Missed reference speakers contribute deletions. |
| Real-time factor | Provider processing wall-clock duration divided by audio clip duration. Timing begins immediately before provider invocation and ends after its normalized result or failure; it includes provider/network wait when an external adapter is explicitly authorized. | Non-positive or non-finite duration is invalid. Timeout and provider failures are counted separately and have no quality metric sample. |

Case aggregates exclude non-calculable samples and record the finite reason and sample count.
Mean and median are emitted for every metric with samples. p95 is emitted only for non-negative
error/latency distributions where a high tail is meaningful: CER, DER, speaker-attributed CER, and
RTF. It is not emitted for signed speaker-count error or higher-is-better accuracy/F1.

Every authorized development gold file must declare `metric_scope` as exactly these seven unique
values: `cer`, `speaker_count_error`, `der`, `speaker_attribution_accuracy`,
`target_speaker_b_f1`, `speaker_attributed_cer`, and `real_time_factor`. Missing, additional, or
duplicate values make the case malformed after development authorization. Sealed gold is not opened
to perform this check.

## Speaker-label matching

The scorer creates a matrix whose rows are predicted labels, columns are reference labels, and each
cell is the total temporal overlap of those two labels. It chooses a one-to-one assignment with the
maximum total overlap. Transcript text and label spelling are never matching inputs. Unmatched
predicted labels are extra speakers; unmatched reference labels are missed speakers.

Rows and columns are sorted lexicographically. If multiple assignments have the same maximum total,
the lexicographically smallest assignment vector wins, with unmatched ordered after real labels.
This makes ties deterministic across runs.

## Sealed holdout discovery boundary

Both benchmarks use a transcript-free `source-index.jsonl`. For audio it permits exactly these keys:

- `schema_version`
- `benchmark`
- `case_id`
- `split`
- `review_status`
- `case_path`

Unknown keys, non-ASCII or overlong case identifiers, any `review_status` other than the finite
`source_aligned_label` value, absolute paths, traversal, empty path components, and a `case_path`
that is not exactly `gold/<case_id>.json` are rejected. Discovery reads only this file. Symlinks are
resolved and checked against the authorized root only after development admission, immediately
before a case or source WAV is opened. A whole sealed split is denied
before even the index is read. An explicit sealed id may be resolved from the index, but refusal
contains no id and occurs before any case/gold/audio path is formed or opened. Output directories
must be created only after this admission step succeeds. Successful admission returns a non-publicly
constructible development capability; case/gold/WAV APIs accept that capability rather than a
caller-mutable split value.

The checked-in generator emits this index during an authorized full rebuild. A legacy local audio
dataset that has no `source-index.jsonl` is deliberately not repaired from `manifest.jsonl`, gold,
or audio: the harness refuses discovery until the index is regenerated from the authorized source
corpus. The metadata-only refresh mode also requires both existing indexes and completes no writes
when either is absent.

The deterministic split correction first creates the existing balanced split, forces the two known
exposed cases to development, and chooses the lexicographically first development case in the same
finite metadata stratum as the one-for-one replacement. Text, gold, source identity, source audio,
and content-derived statistics are not selection inputs. This preserves 16 development and 8 sealed
holdout cases and produces the same result on every generator run.

## WAV and disk policy

Execution is sequential in v0. For each authorized development case the runner validates PCM/WAV
format and source frame bounds, creates an opaque securely unique temporary directory, extracts only
the requested frame range, invokes the provider once, scores the normalized result in memory, and
atomically saves only transcript-free metrics/status. It then removes the temporary clip in `defer`
on both success and failure. Temporary names
contain no source title, meeting content, user identity, case transcript, or absolute source path.

The runner never materializes all 24 clips, so peak corpus-derived disk use is one requested PCM
frame range plus its WAV header and small reports. Startup cleanup is limited to direct, non-symlink
`run-` directories older than 24 hours under the harness-owned temporary namespace, with at most 32
removals per invocation; unrelated temporary files are never touched. A process crash may leave at
most the current case clip until that bounded cleanup runs.

## Runner, resume, and reports

One provider failure or timeout produces a finite failure outcome and execution continues with the
next case. Each case result is written through a same-directory temporary file and atomic rename.
Resume accepts a result only when its configuration hash equals the SHA-256 of canonical benchmark,
metric schema, provider/model identifiers, and run options; mismatched results are not reused.

Case reports may store:

- case id and authorized split
- provider/model identifiers and metric schema version
- success/failure status
- CER, signed speaker-count error, DER, attribution accuracy, target-B F1, SA-CER, and RTF
- one finite error category and safe diagnostic code
- timestamp

Aggregate reports may store target/success/failure/timeout counts, metric sample counts, mean,
median, eligible p95, non-calculable reason counts, configuration hash, and start/end timestamps.

Reports must not store transcript text, audio bytes, source/user names, API keys, authorization
headers, provider raw responses, absolute paths, or free-form error strings. Persisted failure
categories are finite (`source_missing`, `source_format_invalid`, `clip_extraction_failed`, `provider_failed`,
`provider_timeout`, `prediction_invalid`, `reference_invalid`, `scoring_failed`, and
`output_write_failed`); admission/index errors are refused before output exists. Diagnostic codes are
reviewed stable identifiers rather than exception descriptions.

## Release isolation and external-provider gate

Benchmark implementation, schemas, CLI entry point, tests, and local data belong only to the
development CLI/test targets. The `HAENA` application target excludes `HAENA/Benchmark`, so neither
Debug convenience nor Release packaging may add a product dependency on this harness. Release
verification inspects the Swift input file list, app bundle, linked binary strings, and architectures.

No external STT API is invoked by the default runner. An external adapter may be implemented, but a
live run requires a separate operator decision covering the named provider, network access, corpus
transfer permission, and cost. This task performs no such run.

## Known v0 limits

- Overlap speech and a non-zero DER collar are not implemented.
- The source-aligned labels are not newly human-reviewed in this task.
- Sequential execution favors bounded disk use over throughput.
- Fake-provider reports validate control flow, isolation, resume, and schema only.
- Audio/STT scores are not Meeting Execution semantic scores.
