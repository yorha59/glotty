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
- 🧠 **メモリ** —— 会話から、長く役立つ用語・好み・背景情報を任意で学習し、以降の回答をパーソナライズ。
- 🔗 **文脈を理解** —— ステップ間で文脈を保持：推敲はそのまま追加質問の会話になり、翻訳はあなたについて覚えた情報を活かします。
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

|  リーダーキー  |  ホバーメニュー  |
| :--: | :--: |
| ![リーダーキーのメニュー](../appstore-screenshots/05-hud.png) | ![ホバーメニュー](../appstore-screenshots/06-hover.png) |

## 🧠 文脈を理解

Glotty はステップ間で文脈を保ちます——推敲はそのまま会話になり、翻訳はあなたについて学んだことを踏まえます。

|  文脈を踏まえた追加質問  |  メモリを踏まえた翻訳  |
| :--: | :--: |
| ![推敲してから理由を聞く](../appstore-screenshots/07-polish-chat.png) | ![あなたを覚えて文脈で翻訳](../appstore-screenshots/08-memory-translate.png) |

## 🧩 プロバイダ

ホスト型モデルの鍵を持ち込むか、オンデバイスで実行 —— **設定 → 言語モデル**で設定：

- **OpenAI 互換** —— OpenAI または OpenAI 互換の任意のエンドポイント（base URL + 鍵を設定）
- **DeepSeek**
- **Kimi For Coding**（Moonshot）
- **MiniMax**
- **Apple Intelligence** —— オンデバイス（Foundation Models）、鍵もネットワークも不要
- **カスタム** —— その他の OpenAI 互換プロバイダを追加

翻訳は Apple 翻訳フレームワーク + macOS 辞書で完全オフライン実行も可能。LLM 不要。

## 📄 ライセンス

[GPL-3.0](../LICENSE)。
