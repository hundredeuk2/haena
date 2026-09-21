# Distribution tests

Checks that validate a **published HAE.NA release artifact** — the file you actually download.

These tests are deliberately source-independent. They do not read, import, build, or require the
product source. They need only `bash`, the macOS command-line tools that ship with the system, and
an anonymous network connection. Anyone who can download the release can run them and reach the
same verdict the maintainer reaches, which is the point: a claim on the release page that nobody
outside can check is not much of a claim.

> These tests say nothing about meeting quality, model output, or whether the app is good. They
> check that the download is intact, is what it says it is, is signed the way it says it is, carries
> nobody's data, and did not disturb the previous release.

## Running them

```bash
cd dist-tests
./run-all.sh
```

With no arguments the suite targets the current release (defaults live in `lib/common.sh`). For a
different or future release, pass it in — nothing needs editing:

```bash
./run-all.sh \
  --tag v0.2.8-preview.1 \
  --version 0.2.8 --build 13 \
  --sha256 <the checksum from that release's notes> \
  --bytes  <that release's byte size> \
  --prior-tag v0.2.7-preview.1 \
  --prior-asset HAE.NA-0.2.7-12-unsigned.app.zip \
  --prior-sha256 <the 0.2.7 build 12 checksum>
```

Every option also has an environment variable (`HAENA_TAG`, `HAENA_VERSION`, `HAENA_SHA256`, …);
run any script with `--help` for the full list. Each script is standalone — run one on its own and
it downloads what it needs.

`run-all.sh` runs every check, downloads the asset once into a shared cache, reports which checks
failed, and exits non-zero if any did. Individual scripts exit non-zero and print what failed.

Downloads are cached in `$TMPDIR/haena-dist-tests` (override with `--workdir`). Nothing is written
inside the repository, and no path under a user's home directory is hardcoded anywhere.

## Requirements

macOS, `bash`, and tools that come with the system: `curl`, `shasum`, `ditto`, `lipo`, `codesign`,
`spctl`, `strings`, `file`, `/usr/libexec/PlistBuddy`. No Xcode project, no XcodeGen, no toolchain,
no GitHub account, and **no token** — the downloads are anonymous on purpose.

## What each check proves

| Script | What it proves | What a failure would mean |
| --- | --- | --- |
| `01-checksum-integrity.sh` | The bytes a stranger downloads are exactly the bytes the release documents. Recomputes SHA-256 from the anonymous download and requires it to equal both the published `.sha256` file and the checksum written in the release notes; also checks the byte size. | The artifact was replaced, truncated, silently rebuilt, or the release is not actually anonymously downloadable. |
| `02-bundle-shape.sh` | The archive is a usable macOS app. It expands to exactly one `HAE.NA.app`, with `Contents/Info.plist`, `Contents/MacOS/`, and an executable Mach-O binary at `Contents/MacOS/HAENA` that `CFBundleExecutable` actually names. | A downloader would get something they cannot open. |
| `03-version-identity.sh` | The app inside the archive is the version the release claims. `CFBundleShortVersionString` and `CFBundleVersion` match the expected version and build, and the asset file name agrees with them. | A release was cut from a stale build, or the file name and the binary disagree. |
| `04-architecture.sh` | The download really is universal. `lipo` reports both `x86_64` and `arm64`. | A single-architecture build shipped while still being described as universal, silently excluding half the testers. |
| `05-signing-honesty.sh` | The artifact is signed exactly the way it is **labelled**: a valid ad-hoc signature, no Developer ID authority, no Team Identifier, and Gatekeeper does not accept it for execution. | The labelling is wrong in one direction or the other — an ad-hoc build described as signed, or a signed/notarized build still shipped under "unsigned" instructions. Either makes the release page dishonest. |
| `06-distribution-hygiene.sh` | The bundle contains only the application. No persisted user-data files (`projects.json`, `profile.json`, `agent-*.json`, `beta-metrics.json`, `continuity-transitions.json`, `.env*`), no audio or video, nothing matching an API-key pattern, and no `/Users/…` or `/home/…` path from the build machine — scanned across every shipped file with `strings`, so a string compiled into the binary cannot hide. | A privacy incident, not a bug. This is checked on the downloaded artifact rather than on the build machine, so nobody has to take the build script's word for it. |
| `07-prior-release-preserved.sh` | Publishing a new release did not disturb the old one. The previous release's asset is still anonymously downloadable and still matches the checksum it published. | An already-published preview was overwritten, deleted, or its tag moved — breaking the promise that a tester can always re-download and re-verify the exact build they tried. |

## What these tests are not

- **Not a product test.** They never launch the app, record a meeting, call a model, or judge
  extraction quality.
- **Not the product's test suite.** The source-coupled unit and UI suites under `HAENATests/` and
  `HAENAUITests/` in this repository belong to the preserved 0.2.5 source baseline. The tests for
  0.2.6+ product behaviour live with the private core source and are not published here.
- **Not a security audit.** `05-signing-honesty.sh` checks that the signing *description* is true.
  An ad-hoc signature is not a trust anchor, and the release says so.

---

## 한국어 요약

이 디렉터리는 **공개된 릴리스 파일 자체**를 검증합니다. 제품 소스를 읽거나 빌드하지 않으므로,
다운로드할 수 있는 사람이면 누구나 같은 검사를 실행하고 같은 결론에 도달할 수 있습니다.

```bash
cd dist-tests && ./run-all.sh
```

확인하는 것은 체크섬 일치(익명 다운로드 · 공개 `.sha256` · 릴리스 노트 3자 일치), 앱 번들 구조,
버전·빌드 번호 일치, universal 아키텍처, **표기된 그대로의 서명 상태**(ad-hoc이며 Developer ID
서명·공증 없음), 번들에 사용자 데이터·오디오·API 키·빌드 머신 절대 경로가 없음, 그리고 **이전
릴리스가 그대로 보존**되어 있음입니다.

회의 품질이나 모델 결과를 검증하지는 않습니다. `HAENATests/`·`HAENAUITests/`는 보존된 0.2.5 소스
baseline의 테스트이며, 0.2.6 이후 제품 테스트는 비공개 core 저장소에 있고 공개하지 않습니다.
