# 기여 안내

작은 변경을 환영합니다. 아래는 이 저장소가 실제로 지키고 있는 규칙입니다.

## 개발 환경

| 항목 | 버전 |
| --- | --- |
| macOS | 14.0 이상 |
| Xcode | Swift 6 툴체인 포함 |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | `brew install xcodegen` |

외부 패키지 의존성은 없습니다. Apple 프레임워크만 씁니다.

## XcodeGen 규칙

**`HAENA.xcodeproj`를 직접 편집하지 마세요.** `project.yml`에서 생성됩니다.
`Info.plist`와 entitlements도 `project.yml`의 `info.properties` / `entitlements.properties`에서
생성되므로, 그 파일들을 손으로 고치면 다음 생성 때 사라집니다.

파일을 추가하거나 빌드 설정을 바꿨다면:

```bash
xcodegen generate
```

생성 결과(`project.pbxproj`)는 커밋에 포함합니다.

## 빌드와 테스트

```bash
xcodebuild -project HAENA.xcodeproj -scheme HAENA -configuration Debug build
```

```bash
xcodebuild -project HAENA.xcodeproj -scheme HAENA -configuration Debug -only-testing:HAENATests -skip-testing:HAENATests/OpenAITranscriptionLiveTests -skip-testing:HAENATests/OpenAIWorkStateExtractionLiveTests test
```

```bash
xcodebuild -project HAENA.xcodeproj -scheme HAENA -configuration Release clean build
```

### Swift 6 경고 0건

`main`은 **소스 경고 0건**을 유지합니다. 경고를 남기거나 concurrency 검사를 약화시키는 변경은
받지 않습니다. `@unchecked Sendable`은 이유를 주석으로 설명할 수 있을 때만 씁니다.

### 실제 OpenAI 호출은 opt-in

기본 테스트 실행은 **네트워크를 쓰지 않습니다.**

`OpenAITranscriptionLiveTests`와 `OpenAIWorkStateExtractionLiveTests`만 실제 API를 호출하며,
저장소 밖의 로컬 키 파일이 있을 때만 동작합니다. `xcodebuild`가 셸 환경변수를 앱 호스트 테스트
프로세스로 전달하지 않기 때문에 파일 존재 여부를 opt-in 신호로 씁니다.

**주의: 그 키 파일이 있으면 전체 테스트를 돌릴 때마다 실제 과금 호출이 발생합니다.** 위 명령처럼
`-skip-testing`으로 제외하고 돌리세요.

## 커밋하면 안 되는 것

- **API 키**, 토큰, 비밀번호 — 어떤 형태로도
- **회의 오디오와 실제 전사 원문**
- `projects.json`, `profile.json`, `agent-jobs.json`, `agent-ledger.json` 등 사용자 데이터
- OpenAI API 응답 원문
- 빌드 산출물, `DerivedData/`, `.xcresult`, `xcuserdata/`
- 사용자 홈 디렉터리 절대 경로

테스트에 키가 필요하면 명백히 가짜인 값을 쓰세요(예: `sk-test-…`). 실제 키와 구분되지 않는 값은
쓰지 마세요.

## 변경 범위

**작게 유지해주세요.** 이 저장소는 한 번에 하나의 수직 슬라이스를 완성하는 방식으로 만들어졌습니다.

- 기능 변경과 무관한 리팩터링을 섞지 마세요
- 저장 스키마 변경은 하위 호환과 근거를 함께 제시해주세요
- 판정 규칙(무엇이 "미검토 제안"인지, 무엇이 "내 업무"인지)은 각각 한 곳에만 존재합니다.
  새 술어를 만들기 전에 기존 정책을 재사용할 수 있는지 확인해주세요

## PR 전 확인 목록

- [ ] `xcodegen generate`를 실행했고 `project.pbxproj` 변경을 포함했다
- [ ] Debug·Release 빌드가 성공한다
- [ ] 전체 유닛 테스트가 통과한다(live test 제외)
- [ ] Swift 6 소스 경고가 0건이다
- [ ] 기존 테스트를 삭제하거나 skip하지 않았다
- [ ] 키·오디오·사용자 데이터가 diff에 없다
- [ ] 새 동작에 대한 테스트를 추가했다
- [ ] 사용자에게 보이는 문구 변경이 있다면 관련 문서도 갱신했다
