<div align="center">
  <img src="../Glotty/Assets.xcassets/AppIcon.appiconset/icon-256@2x.png" width="128" alt="Glotty 图标">
  <h1>Glotty</h1>
  <p>
    <b>翻译</b>、<b>解释</b>、<b>润色</b>、<b>对话</b>、<b>朗读</b>任意文本 ——
    <br>就在你阅读或写作的地方。
  </p>
  <p>
    <img src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white" alt="macOS 15+">
    <img src="https://img.shields.io/badge/License-GPLv3-3b82f6.svg" alt="License: GPL v3">
    <img src="https://github.com/yorha59/glotty/actions/workflows/build.yml/badge.svg" alt="Build">
  </p>
  <p>
    <a href="../README.md">English</a> ·
    <b>简体中文</b> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a>
  </p>
</div>

**Glotty** 是一款用于外语阅读与写作的 macOS 菜单栏应用。在*任意* App 中选中文本 ——
或在内置阅读器中打开一本书 —— 即可翻译它、获得通俗易懂的解释、把你的草稿润色为地道表达、
就它展开对话，或朗读出来。它为想要即时、就地的语言辅导（而非另开一个翻译窗口）的学习者而生：
无需切换应用，无需复制粘贴。

> 个人项目，以 GPL 协议原样分享。难免有粗糙之处。

## ✨ 亮点

- 🌐 **翻译** —— Apple 的本地翻译 + macOS 系统词典，并可选 LLM 释义。
- 💡 **解释** —— 用你的母语给出通俗解释：语感、用法与语境。
- ✏️ **润色** —— 把你自己的草稿改写为更地道的目标语言表达。
- 💬 **对话** —— 就某个词、句子或你的写作展开辅导式追问。
- 🔊 **朗读** —— 通过 macOS 内置语音或 ElevenLabs 进行文本转语音。
- 📖 **阅读器** —— 内置 EPUB / PDF 阅读器：点按任意单词即可查询，并标记你想记住的词汇（保持下划线）。同时注册为 `.epub` / `.pdf` 的“打开方式”处理程序。
- 🧠 **记忆** —— 可选地从你的对话中学习长期有用的术语、偏好与背景信息，用于个性化后续回答。
- 🔑 **自带 LLM** —— 密钥保存在 macOS **钥匙串**中，绝不写入应用文件。
- 🌍 界面**多语言**支持。

## 📸 截图

|  翻译  |  解释  |
| :--: | :--: |
| ![翻译](../appstore-screenshots/01-translate.png) | ![解释](../appstore-screenshots/02-explain.png) |
|  **润色**  |  **对话**  |
| ![润色](../appstore-screenshots/03-polish.png) | ![对话](../appstore-screenshots/04-chat.png) |

## ⌨️ 如何触发

两种方式，均可在任意 App 中使用：

- **引导键快捷键** —— 按住引导键（默认 `Fn`），再点一个字母：`T` 翻译、`E` 解释、`P` 润色、`C` 对话、`V` 朗读、`R` 拼写纠正。按住时会显示可选项菜单。
- **悬停菜单** —— 将指针停在选区上，弹出一个包含相同操作的紧凑工具条。

<div align="center">
  <img src="../appstore-screenshots/05-hud.png" width="380" alt="引导键菜单">
</div>

## 🧩 模型提供方

自带托管 LLM 的密钥，或完全在本地运行：

- **托管** —— OpenAI、DeepSeek，以及其他兼容 OpenAI 的接口。
- **本地** —— Apple Intelligence（Foundation Models），以及用于完全离线查询的 Apple 翻译框架与系统词典。

## 🛠 构建与运行

环境要求：**macOS 15+**、**Xcode 16+**，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）—— `.xcodeproj` 为生成产物，不纳入版本库。

```sh
xcodegen generate     # 由 project.yml 生成 Glotty.xcodeproj
open Glotty.xcodeproj  # 然后在 Xcode 中运行
```

或用命令行做一次未签名构建：

```sh
xcodegen generate
xcodebuild -project Glotty.xcodeproj -scheme Glotty -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

如需**签名**构建，请填入你自己的 Apple 开发者身份 —— `project.yml` 中的 `DEVELOPMENT_TEAM` 默认为空；填入你的（并相应调整 `CODE_SIGN_*`），或在 `xcodebuild` 命令行中覆盖。

## ⚙️ 配置与权限

- 在**设置 → 语言模型**中添加 LLM 提供方与 API 密钥（保存于钥匙串）；可选的 ElevenLabs 语音密钥位于**设置 → 语音**。
- Glotty 是菜单栏后台应用（无 Dock 图标）。在其他 App 中读取选区需要**辅助功能**权限；引导键快捷键需要**输入监控**权限；主动提醒需要**通知**权限 —— 在系统提示时授予，或在应用内的**权限**面板中操作。

## 🌍 本地化

界面字符串位于 `Glotty/Resources/Localizable.xcstrings`。`scripts/extract-strings.sh` 扫描源码中可翻译的字面量，`scripts/translate-catalog.py` 用你自己的 LLM 密钥将目录填充至各语言。

## 📄 许可证

[GPL-3.0](../LICENSE)。
