<div align="center">
  <img src="../Glotty/Assets.xcassets/AppIcon.appiconset/icon-256@2x.png" width="128" alt="Glotty 圖示">
  <h1>Glotty</h1>
  <p>
    <b>翻譯</b>、<b>解釋</b>、<b>潤色</b>、<b>對話</b>、<b>朗讀</b>任意文字 ——
    <br>就在你閱讀或寫作的地方。
  </p>
  <p>
    <img src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white" alt="macOS 15+">
    <img src="https://img.shields.io/badge/License-GPLv3-3b82f6.svg" alt="License: GPL v3">
    <img src="https://github.com/yorha59/glotty/actions/workflows/build.yml/badge.svg" alt="Build">
  </p>
  <p>
    <a href="../README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <b>繁體中文</b> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a>
  </p>
</div>

**Glotty** 是一款用於外語閱讀與寫作的 macOS 選單列 App。在*任意* App 中選取文字 ——
或在內建閱讀器中打開一本書 —— 即可翻譯它、獲得淺顯易懂的解釋、把你的草稿潤飾為道地表達、
就它展開對話，或朗讀出來。它為想要即時、就地的語言輔導（而非另開一個翻譯視窗）的學習者而生：
無需切換 App，無需複製貼上。


## ✨ 亮點

- 🌐 **翻譯** —— Apple 的裝置端翻譯 + macOS 系統辭典，並可選 LLM 釋義。
- 💡 **解釋** —— 用你的母語給出淺顯解釋：語感、用法與語境。
- ✏️ **潤色** —— 把你自己的草稿改寫為更道地的目標語言表達。
- 💬 **對話** —— 就某個詞、句子或你的寫作展開輔導式追問。
- 🔊 **朗讀** —— 透過 macOS 內建語音或 ElevenLabs 進行文字轉語音。
- 📖 **閱讀器** —— 內建 EPUB / PDF 閱讀器：點按任意單字即可查詢，並標記你想記住的詞彙（保持底線）。同時註冊為 `.epub` / `.pdf` 的「打開檔案的方式」處理程式。
- 🧠 **記憶** —— 可選地從你的對話中學習長期有用的術語、偏好與背景資訊，用於個人化後續回答。
- 🔑 **自帶 LLM** —— 金鑰保存在 macOS **鑰匙圈**中，絕不寫入 App 檔案。
- 🌍 介面**多語言**支援。

## 📸 螢幕截圖

|  翻譯  |  解釋  |
| :--: | :--: |
| ![翻譯](../appstore-screenshots/01-translate.png) | ![解釋](../appstore-screenshots/02-explain.png) |
|  **潤色**  |  **對話**  |
| ![潤色](../appstore-screenshots/03-polish.png) | ![對話](../appstore-screenshots/04-chat.png) |

## ⌨️ 如何觸發

兩種方式，均可在任意 App 中使用：

- **引導鍵快捷鍵** —— 按住引導鍵（預設 `Fn`），再點一個字母：`T` 翻譯、`E` 解釋、`P` 潤色、`C` 對話、`V` 朗讀、`R` 拼字修正。按住時會顯示可選項選單。
- **懸停選單** —— 將指標停在選取範圍上，彈出一個包含相同操作的精簡工具列。

<div align="center">
  <img src="../appstore-screenshots/05-hud.png" width="380" alt="引導鍵選單">
</div>

## 🧩 模型供應商

自帶托管 LLM 的金鑰，或完全在本機執行：

- **托管** —— OpenAI、DeepSeek，以及其他相容 OpenAI 的介面。
- **裝置端** —— Apple Intelligence（Foundation Models），以及用於完全離線查詢的 Apple 翻譯框架與系統辭典。

## 🛠 建置與執行

環境需求：**macOS 15+**、**Xcode 16+**，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）—— `.xcodeproj` 為產生產物，不納入版本庫。

```sh
xcodegen generate     # 由 project.yml 產生 Glotty.xcodeproj
open Glotty.xcodeproj  # 然後在 Xcode 中執行
```

或用命令列做一次未簽署建置：

```sh
xcodegen generate
xcodebuild -project Glotty.xcodeproj -scheme Glotty -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

如需**簽署**建置，請填入你自己的 Apple 開發者身分 —— `project.yml` 中的 `DEVELOPMENT_TEAM` 預設為空；填入你的（並相應調整 `CODE_SIGN_*`），或在 `xcodebuild` 命令列中覆寫。

## ⚙️ 設定與權限

- 在**設定 → 語言模型**中新增 LLM 供應商與 API 金鑰（保存於鑰匙圈）；可選的 ElevenLabs 語音金鑰位於**設定 → 語音**。
- Glotty 是選單列背景 App（無 Dock 圖示）。在其他 App 中讀取選取範圍需要**輔助使用**權限；引導鍵快捷鍵需要**輸入監控**權限；主動提醒需要**通知**權限 —— 在系統提示時授予，或在 App 內的**權限**面板中操作。

## 🌍 在地化

介面字串位於 `Glotty/Resources/Localizable.xcstrings`。`scripts/extract-strings.sh` 掃描原始碼中可翻譯的字面值，`scripts/translate-catalog.py` 用你自己的 LLM 金鑰將目錄填入各語言。

## 📄 授權

[GPL-3.0](../LICENSE)。
