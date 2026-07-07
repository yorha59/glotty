<div align="center">
  <img src="../Glotty/Assets.xcassets/AppIcon.appiconset/icon-256@2x.png" width="128" alt="Glotty アイコン">
  <h1>Glotty</h1>
  <p>
    選択したテキストを<b>翻訳</b>・<b>解説</b>・<b>推敲</b>・<b>チャット</b>・<b>読み上げ</b> ——
    <br>読み書きしている、その場で。
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
    <b>日本語</b> ·
    <a href="README.ko.md">한국어</a>
  </p>
</div>

**Glotty** は、外国語で読み書きするための macOS メニューバーアプリです。任意のアプリでテキストを
選択する —— または内蔵リーダーで本を開く —— だけで、翻訳したり、平易な解説を得たり、自分の下書きを
より自然な言い回しに推敲したり、それについてチャットしたり、読み上げさせたりできます。別の翻訳ウィンドウ
ではなく、その場で使える手早い語学チューターが欲しい学習者のために作られています。アプリの切り替えも
コピペも不要です。


## ✨ 主な機能

- 🌐 **翻訳** —— Apple のオンデバイス翻訳 + macOS システム辞書、任意で LLM による語釈。
- 💡 **解説** —— 母語で分かりやすく解説：ニュアンス・用法・文脈。
- ✏️ **推敲** —— 自分の下書きを、より自然な対象言語の表現に書き換え。
- 💬 **チャット** —— 単語・文・自分の文章について、チューターに追加で質問。
- 🔊 **読み上げ** —— macOS 内蔵の音声、または ElevenLabs によるテキスト読み上げ。
- 📖 **リーダー** —— 内蔵の EPUB / PDF リーダー：単語をタップして調べ、覚えたい語彙をマーク（下線が残ります）。`.epub` / `.pdf` の「このアプリで開く」ハンドラとしても登録されます。
- 🧠 **メモリ** —— 会話から、長く役立つ用語・好み・背景情報を任意で学習し、以降の回答をパーソナライズ。
- 🔑 **自分の LLM を利用** —— 鍵は macOS の**キーチェーン**に保存され、アプリのファイルには書き込みません。
- 🌍 UI は**多言語**対応。

## 📸 スクリーンショット

|  翻訳  |  解説  |
| :--: | :--: |
| ![翻訳](../appstore-screenshots/01-translate.png) | ![解説](../appstore-screenshots/02-explain.png) |
|  **推敲**  |  **チャット**  |
| ![推敲](../appstore-screenshots/03-polish.png) | ![チャット](../appstore-screenshots/04-chat.png) |

## ⌨️ 呼び出し方

どちらもすべてのアプリで動作します：

- **リーダーキーのショートカット** —— リーダーキー（既定は `Fn`）を押しながら文字をタップ：`T` 翻訳、`E` 解説、`P` 推敲、`C` チャット、`V` 読み上げ、`R` スペル修正。押している間、選択肢メニューが表示されます。
- **ホバーメニュー** —— 選択範囲にポインタを合わせると、同じ操作を並べたコンパクトなバーが現れます。

<div align="center">
  <img src="../appstore-screenshots/05-hud.png" width="380" alt="リーダーキーのメニュー">
</div>

## 🧩 プロバイダ

ホスト型 LLM の鍵を持ち込むか、完全にオンデバイスで実行：

- **ホスト型** —— OpenAI、DeepSeek、その他 OpenAI 互換のエンドポイント。
- **オンデバイス** —— Apple Intelligence（Foundation Models）、およびネットワーク不要の検索のための Apple 翻訳フレームワークとシステム辞書。

## 🛠 ビルドと実行

必要環境：**macOS 15+**、**Xcode 16+**、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）—— `.xcodeproj` は生成物で、リポジトリには含めません。

```sh
xcodegen generate     # project.yml から Glotty.xcodeproj を生成
open Glotty.xcodeproj  # Xcode で実行
```

またはコマンドラインで未署名ビルド：

```sh
xcodegen generate
xcodebuild -project Glotty.xcodeproj -scheme Glotty -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

**署名**ビルドには自分の Apple Developer ID を設定してください —— `project.yml` の `DEVELOPMENT_TEAM` は空です。自分のものを設定（`CODE_SIGN_*` も調整）するか、`xcodebuild` のコマンドラインで上書きします。

## ⚙️ 設定と権限

- **設定 → 言語モデル**で LLM プロバイダと API キーを追加（キーチェーンに保存）。任意の ElevenLabs 音声キーは**設定 → 音声**にあります。
- Glotty はメニューバー常駐アプリです（Dock アイコンなし）。他アプリで選択範囲を読むには**アクセシビリティ**、リーダーキーには**入力監視**、プロアクティブなリマインダーには**通知**の権限が必要です —— プロンプト時に、またはアプリ内の**権限**パネルから許可してください。

## 🌍 ローカライズ

UI 文字列は `Glotty/Resources/Localizable.xcstrings` にあります。`scripts/extract-strings.sh` が翻訳対象のリテラルをソースから抽出し、`scripts/translate-catalog.py` が自分の LLM キーでカタログを各言語に埋めます。

## 📄 ライセンス

[GPL-3.0](../LICENSE)。
