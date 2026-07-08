<div align="center">
  <img src="../icon.png" width="128" alt="Glotty 图标">
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


## ✨ 亮点

- 🌐 **翻译** —— Apple 的本地翻译 + macOS 系统词典，并可选 LLM 释义。
- 💡 **解释** —— 用你的母语给出通俗解释：语感、用法与语境。
- ✏️ **润色** —— 把你自己的草稿改写为更地道的目标语言表达。
- 💬 **对话** —— 就某个词、句子或你的写作展开辅导式追问。
- 🔊 **朗读** —— 通过 macOS 内置语音或 ElevenLabs 进行文本转语音。
- 🧠 **记忆** —— 可选地从你的对话中学习长期有用的术语、偏好与背景信息，用于个性化后续回答。
- 🔗 **理解上下文** —— 在各步骤间保留上下文：一次润色可延续为追问对话，翻译也会参考它记住的关于你的信息。
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

|  引导键  |  悬停菜单  |
| :--: | :--: |
| ![引导键菜单](../appstore-screenshots/05-hud.png) | ![悬停菜单](../appstore-screenshots/06-hover.png) |

## 🧠 理解上下文

Glotty 在各步骤之间保留上下文——一次润色可延续为对话，一次翻译会参考它对你的了解。

|  上下文追问  |  记忆感知翻译  |
| :--: | :--: |
| ![润色后追问](../appstore-screenshots/07-polish-chat.png) | ![记住你，按语境翻译](../appstore-screenshots/08-memory-translate.png) |

## 🧩 模型提供方

自带托管模型的密钥，或在本地运行 —— 在**设置 → 语言模型**中配置：

- **OpenAI 兼容** —— OpenAI 或任意兼容 OpenAI 的接口（自定义 base URL + 密钥）
- **DeepSeek**
- **Kimi For Coding**（月之暗面）
- **MiniMax**
- **Apple Intelligence** —— 本地（Foundation Models），无需密钥或联网
- **自定义** —— 添加任意其他兼容 OpenAI 的提供方

翻译也可完全离线运行：使用 Apple 翻译框架 + macOS 词典，无需 LLM。

## 📄 许可证

[GPL-3.0](../LICENSE)。
