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


## ✨ 주요 기능

- 🌐 **번역** —— Apple의 온디바이스 번역 + macOS 시스템 사전, 선택적으로 LLM 뜻풀이.
- 💡 **설명** —— 모국어로 쉬운 설명: 뉘앙스·용법·맥락.
- ✏️ **다듬기** —— 자신의 초안을 더 자연스러운 대상 언어 표현으로 고쳐 씀.
- 💬 **대화** —— 단어·문장·자신의 글에 대해 튜터에게 이어서 질문.
- 🔊 **읽어주기** —— macOS 기본 음성 또는 ElevenLabs로 텍스트 음성 변환.
- 🧠 **메모리** —— 대화에서 오래 쓸모 있는 용어·선호·배경 정보를 선택적으로 학습해 이후 답변을 개인화.
- 🔗 **맥락 이해** —— 단계 사이에서 맥락을 유지: 다듬기가 후속 질문 대화로 이어지고, 번역은 당신에 대해 기억한 정보를 활용합니다.
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

|  리더 키  |  호버 메뉴  |
| :--: | :--: |
| ![리더 키 메뉴](../appstore-screenshots/05-hud.png) | ![호버 메뉴](../appstore-screenshots/06-hover.png) |

## 🧠 맥락을 이해

Glotty는 단계 사이에서 맥락을 이어갑니다 — 다듬기가 대화로 이어지고, 번역은 당신에 대해 배운 것을 반영합니다.

|  맥락 기반 후속 질문  |  메모리 기반 번역  |
| :--: | :--: |
| ![다듬고 나서 이유를 묻기](../appstore-screenshots/07-polish-chat.png) | ![당신을 기억해 맥락에 맞게 번역](../appstore-screenshots/08-memory-translate.png) |

## 🧩 제공자

호스팅 모델 키를 가져오거나 온디바이스로 실행 —— **설정 → 언어 모델**에서 구성:

- **OpenAI 호환** —— OpenAI 또는 OpenAI 호환 엔드포인트(base URL + 키 설정)
- **DeepSeek**
- **Kimi For Coding**(Moonshot)
- **MiniMax**
- **Apple Intelligence** —— 온디바이스(Foundation Models), 키·네트워크 불필요
- **커스텀** —— 그 외 OpenAI 호환 제공자 추가

번역은 Apple 번역 프레임워크 + macOS 사전으로 완전 오프라인 실행도 가능. LLM 불필요.

## 📄 라이선스

[GPL-3.0](../LICENSE).
