# 서드파티 고지

HAE.NA 자체는 **Apache License 2.0**으로 배포됩니다 (`Copyright 2026 HAE.NA contributors`).
전문은 [LICENSE](LICENSE)에 있습니다. 이 문서는 그 라이선스가 **적용되지 않는 것들**을 구분해
기록합니다.

## 요약: 번들된 서드파티 코드·에셋이 없습니다

HAE.NA는 이 저장소의 소스와 Apple이 제공하는 시스템 프레임워크만으로 빌드됩니다.
현재 시점에서 **재배포되는 서드파티 저작물이 없으므로 배포본에 포함해야 할 고지 의무도
없습니다.**

이 문서는 그 사실을 확인해 기록해둔 것이며, 의존성이 생기면 여기에 추가합니다.

## 앱 런타임 서드파티 의존성

**없음.** Swift Package Manager, CocoaPods, Carthage 의존성이 하나도 없습니다
(`Package.swift`, `Podfile`, `Cartfile` 모두 존재하지 않습니다).

배포되는 `.app` 안에는 이 저장소의 코드와 Apple 시스템 프레임워크에 대한 링크 외에 아무것도
포함되지 않습니다.

사용하는 것은 macOS에 포함된 Apple 프레임워크뿐입니다.

| 프레임워크 | 용도 |
| --- | --- |
| SwiftUI | 화면 |
| AppKit | 저장 패널, 클립보드, 종료 처리 |
| Foundation | 기본 타입, JSON, 네트워크 |
| Combine | 타이머 |
| AVFoundation | 마이크 녹음, 오디오 재생 |
| Security | Keychain |
| UniformTypeIdentifiers | 파일 선택 시 오디오 형식 |
| XCTest | 테스트(배포본에 포함되지 않음) |

이들은 Apple의 SDK 라이선스로 제공되며 별도 고지 대상이 아닙니다.

## 에셋

번들된 이미지·아이콘·폰트·사운드가 **없습니다.**
`Assets.xcassets`에는 색상 정의와 빈 앱 아이콘 슬롯만 있고 실제 이미지 파일은 없습니다.
화면의 기호는 Apple SF Symbols를 사용하며, SF Symbols는 Apple의 사용 조건이 적용되고 앱 번들에
재배포되지 않습니다.

## 개발 도구

| 도구 | 라이선스 | 비고 |
| --- | --- | --- |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | **MIT** | **빌드 시에만** 사용하는 도구입니다. `project.yml`에서 Xcode 프로젝트 파일을 생성할 뿐이며, **XcodeGen의 코드는 앱 번들에 포함되지도 재배포되지도 않습니다.** 따라서 배포본에 MIT 고지를 동봉할 의무가 발생하지 않습니다 |
| Xcode / Swift 툴체인 | Apple | 개발 도구. 배포본에 포함되지 않습니다 |

## OpenAI API와 모델 — **이 프로젝트 라이선스의 적용 대상이 아닙니다**

HAE.NA는 사용자의 키로 OpenAI API를 **호출만** 합니다. OpenAI의 코드·가중치·모델을 포함하거나
재배포하지 않으며, 이 저장소 어디에도 OpenAI의 저작물이 들어 있지 않습니다.

- **HAE.NA 코드에 적용되는 Apache-2.0은 OpenAI API나 모델에 적용되지 않습니다.**
- **API 사용에는 OpenAI의 이용약관·사용 정책·데이터 처리 정책이 별도로 적용됩니다.** 사용자는
  자신의 계정과 키에 대해 그 약관을 직접 따릅니다.
- API 응답으로 생성된 결과물의 권리·이용 조건 역시 OpenAI 약관을 따르며, Apache-2.0이 그 부분을
  규율하지 않습니다.

호출하는 엔드포인트와 전송되는 데이터는 [PRIVACY.md](PRIVACY.md)에 정리했습니다.

## 프로젝트 라이선스

**Apache License 2.0** — `Copyright 2026 HAE.NA contributors`. 전문은 [LICENSE](LICENSE)에
있습니다.
