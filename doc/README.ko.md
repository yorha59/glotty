<div align="center">
  <img src="../Glotty/Assets.xcassets/AppIcon.appiconset/icon-256@2x.png" width="128" alt="Glotty 아이콘">
  <h1>Glotty</h1>
  <p>
    선택한 텍스트를 <b>번역</b>·<b>설명</b>·<b>다듬기</b>·<b>대화</b>·<b>읽어주기</b> ——
    <br>읽고 쓰는 바로 그 자리에서.
  </p>
  <p>
    <img src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white" alt="macOS 15+">
    <img src="https://img.shields.io/badge/License-GPLv3-3b82f6.svg" alt="License: GPL v3">
    <img src="https://github.com/yorha59/glotty/actions/workflows/build.yml/badge.svg" alt="Build">
  </p>
  <p>
    <a href="../README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="README.ja.md">日本語</a> ·
    <b>한국어</b>
  </p>
</div>

**Glotty**는 외국어로 읽고 쓰기 위한 macOS 메뉴 막대 앱입니다. 아무 앱에서나 텍스트를 선택하거나 ——
내장 리더에서 책을 열어 —— 곧바로 번역하고, 쉬운 설명을 얻고, 자신이 쓴 초안을 더 자연스러운 표현으로
다듬고, 그에 대해 대화하고, 소리 내어 읽게 할 수 있습니다. 별도의 번역 창 대신 그 자리에서 바로 쓰는
빠른 언어 튜터를 원하는 학습자를 위해 만들어졌습니다. 앱 전환도, 복사·붙여넣기도 필요 없습니다.

> 개인 프로젝트이며 GPL 라이선스로 있는 그대로 공개합니다. 다듬어지지 않은 부분이 있을 수 있습니다.

## ✨ 주요 기능

- 🌐 **번역** —— Apple의 온디바이스 번역 + macOS 시스템 사전, 선택적으로 LLM 뜻풀이.
- 💡 **설명** —— 모국어로 쉬운 설명: 뉘앙스·용법·맥락.
- ✏️ **다듬기** —— 자신의 초안을 더 자연스러운 대상 언어 표현으로 고쳐 씀.
- 💬 **대화** —— 단어·문장·자신의 글에 대해 튜터에게 이어서 질문.
- 🔊 **읽어주기** —— macOS 기본 음성 또는 ElevenLabs로 텍스트 음성 변환.
- 📖 **리더** —— 내장 EPUB / PDF 리더: 단어를 탭해 찾아보고, 기억하고 싶은 어휘를 표시(밑줄 유지). `.epub` / `.pdf`의 "다음으로 열기" 처리기로도 등록됩니다.
- 🧠 **메모리** —— 대화에서 오래 쓸모 있는 용어·선호·배경 정보를 선택적으로 학습해 이후 답변을 개인화.
- 🔑 **자신의 LLM 사용** —— 키는 macOS **키체인**에 저장되며 앱 파일에는 기록되지 않습니다.
- 🌍 UI **다국어** 지원.

## 📸 스크린샷

|  번역  |  설명  |
| :--: | :--: |
| ![번역](../appstore-screenshots/01-translate.png) | ![설명](../appstore-screenshots/02-explain.png) |
|  **다듬기**  |  **대화**  |
| ![다듬기](../appstore-screenshots/03-polish.png) | ![대화](../appstore-screenshots/04-chat.png) |

## ⌨️ 실행 방법

두 방법 모두 모든 앱에서 동작합니다:

- **리더 키 단축키** —— 리더 키(기본 `Fn`)를 누른 채 문자를 탭: `T` 번역, `E` 설명, `P` 다듬기, `C` 대화, `V` 읽어주기, `R` 맞춤법 교정. 누르고 있는 동안 선택지 메뉴가 표시됩니다.
- **호버 메뉴** —— 선택 영역에 포인터를 올리면 같은 동작을 담은 간단한 막대가 나타납니다.

<div align="center">
  <img src="../appstore-screenshots/05-hud.png" width="380" alt="리더 키 메뉴">
</div>

## 🧩 제공자

호스팅 LLM 키를 가져오거나 완전히 온디바이스로 실행:

- **호스팅** —— OpenAI, DeepSeek 및 기타 OpenAI 호환 엔드포인트.
- **온디바이스** —— Apple Intelligence(Foundation Models), 그리고 네트워크가 전혀 필요 없는 조회를 위한 Apple 번역 프레임워크와 시스템 사전.

## 🛠 빌드 및 실행

요구 사항: **macOS 15+**, **Xcode 16+**, [XcodeGen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`) —— `.xcodeproj`는 생성물이며 저장소에 포함되지 않습니다.

```sh
xcodegen generate     # project.yml로부터 Glotty.xcodeproj 생성
open Glotty.xcodeproj  # 그런 다음 Xcode에서 실행
```

또는 명령줄에서 미서명 빌드:

```sh
xcodegen generate
xcodebuild -project Glotty.xcodeproj -scheme Glotty -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

**서명** 빌드는 자신의 Apple 개발자 ID를 설정하세요 —— `project.yml`의 `DEVELOPMENT_TEAM`은 비어 있습니다. 자신의 것을 설정(그리고 `CODE_SIGN_*` 조정)하거나 `xcodebuild` 명령줄에서 재정의하세요.

## ⚙️ 설정 및 권한

- **설정 → 언어 모델**에서 LLM 제공자와 API 키를 추가(키체인에 저장). 선택적 ElevenLabs 음성 키는 **설정 → 음성**에 있습니다.
- Glotty는 메뉴 막대 백그라운드 앱입니다(Dock 아이콘 없음). 다른 앱에서 선택 영역을 읽으려면 **손쉬운 사용(Accessibility)**, 리더 키 단축키에는 **입력 모니터링**, 능동 알림에는 **알림** 권한이 필요합니다 —— 프롬프트가 뜰 때 또는 앱 내 **권한** 패널에서 허용하세요.

## 🌍 지역화

UI 문자열은 `Glotty/Resources/Localizable.xcstrings`에 있습니다. `scripts/extract-strings.sh`가 번역 대상 리터럴을 소스에서 추출하고, `scripts/translate-catalog.py`가 자신의 LLM 키로 카탈로그를 각 언어로 채웁니다.

## 📄 라이선스

[GPL-3.0](../LICENSE).
