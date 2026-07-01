import SwiftUI
import WebKit

/// Renders one EPUB chapter in a `WKWebView`. Because we own the DOM we can do
/// what's impossible inside Books.app: a tap on any word fires Glotty's lookup
/// popup, and previously looked-up words are underlined (and re-tappable). Type
/// size + theme are applied by injecting a stylesheet. Resources (CSS / images /
/// fonts) resolve via file URLs scoped to the book's extraction directory.
struct EPUBWebView: NSViewRepresentable {
    let book: EPUBBook
    let chapterIndex: Int
    let fontScale: Double
    let theme: ReaderState.Theme
    let fontCSS: String
    let lookedUp: Set<String>
    let onLookup: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLookup: onLookup) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "glotty")
        ucc.addUserScript(WKUserScript(source: Self.bootstrapJS,
                                       injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController = ucc
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")   // let chapter/theme bg show
        context.coordinator.webView = web
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.onLookup = onLookup
        c.style = (fontScale, theme.rawValue, fontCSS)
        c.words = Array(lookedUp)
        if c.loadedChapter != chapterIndex, book.chapters.indices.contains(chapterIndex) {
            c.loadedChapter = chapterIndex
            web.loadFileURL(book.chapters[chapterIndex].url, allowingReadAccessTo: book.rootDir)
            // style + marks are (re)applied in didFinish for the fresh document
        } else {
            c.applyStyle()
            c.applyMarks()
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onLookup: (String) -> Void
        var loadedChapter = -1
        var style: (Double, String, String) = (1.0, "light", "")
        var words: [String] = []

        init(onLookup: @escaping (String) -> Void) { self.onLookup = onLookup }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyStyle(); applyMarks()
        }

        func applyStyle() {
            webView?.evaluateJavaScript(
                "window.__glottyStyle && __glottyStyle(\(style.0), \(Self.jsString(style.1)), \(Self.jsString(style.2)))",
                completionHandler: nil)
        }
        /// Double-quoted, escaped JS string literal (the font stack contains
        /// commas/quotes, so it can't be interpolated raw).
        private static func jsString(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func applyMarks() {
            let json = (try? JSONSerialization.data(withJSONObject: words))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            webView?.evaluateJavaScript(
                "window.__glottyMark && __glottyMark(\(json))", completionHandler: nil)
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let d = message.body as? [String: Any], let word = d["word"] as? String else { return }
            onLookup(word)
        }
    }

    /// Injected once per chapter. Defines the style + underline helpers and wires
    /// a capturing click handler that resolves the word under the pointer and
    /// posts it back to Swift.
    private static let bootstrapJS = #"""
    (function () {
      if (window.__glottyReady) return; window.__glottyReady = true;

      window.__glottyStyle = function (scale, theme, font) {
        var st = document.getElementById('glotty-style');
        if (!st) { st = document.createElement('style'); st.id = 'glotty-style'; (document.head || document.documentElement).appendChild(st); }
        var bg = '', fg = '';
        if (theme === 'dark')  { bg = '#1c1c1e'; fg = '#d8d8d8'; }
        else if (theme === 'sepia') { bg = '#f4ecd8'; fg = '#5b4636'; }
        else { bg = '#ffffff'; fg = '#111111'; }
        var ff = font ? ('font-family:' + font + ' !important;') : '';
        st.textContent =
          'html,body{background:' + bg + ' !important; color:' + fg + ' !important;' + ff +
          'font-size:' + (scale * 100) + '% !important; line-height:1.65; -webkit-text-size-adjust:none;}' +
          'body{max-width:42em; margin:0 auto; padding:28px 24px 64px;}' +
          'img{max-width:100% !important; height:auto !important;}' +
          'a{color:#3b82f6;}' +
          'span.glotty-seen{text-decoration:underline; text-decoration-color:#3b82f6;' +
          'text-decoration-thickness:2px; text-underline-offset:3px; cursor:pointer;}';
      };

      var isWord = function (c) { return c && /[\p{L}\p{M}'’\-]/u.test(c); };

      window.__glottyMark = function (words) {
        document.querySelectorAll('span.glotty-seen').forEach(function (s) {
          s.replaceWith(document.createTextNode(s.textContent));
        });
        document.body && document.body.normalize();
        if (!words || !words.length) return;
        var esc = words.map(function (w) { return w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); });
        var re = new RegExp('(^|[^\\p{L}])(' + esc.join('|') + ')(?![\\p{L}])', 'giu');
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
        nodes.forEach(function (n) {
          var p = n.parentNode; if (!p) return;
          var tag = p.tagName; if (tag === 'SCRIPT' || tag === 'STYLE') return;
          if (p.className === 'glotty-seen') return;
          var txt = n.textContent; re.lastIndex = 0;
          if (!re.test(txt)) return;
          re.lastIndex = 0;
          var frag = document.createDocumentFragment(), last = 0, m;
          while ((m = re.exec(txt))) {
            var pre = m[1] || '', word = m[2], at = m.index + pre.length;
            if (at > last) frag.appendChild(document.createTextNode(txt.slice(last, at)));
            var sp = document.createElement('span'); sp.className = 'glotty-seen'; sp.textContent = word;
            frag.appendChild(sp);
            last = at + word.length;
            if (m.index === re.lastIndex) re.lastIndex++;
          }
          if (last < txt.length) frag.appendChild(document.createTextNode(txt.slice(last)));
          p.replaceChild(frag, n);
        });
      };

      document.addEventListener('click', function (e) {
        var r = document.caretRangeFromPoint ? document.caretRangeFromPoint(e.clientX, e.clientY) : null;
        if (!r) return;
        var node = r.startContainer;
        if (!node || node.nodeType !== 3) return;
        var text = node.textContent, i = r.startOffset, s = i, en = i;
        while (s > 0 && isWord(text[s - 1])) s--;
        while (en < text.length && isWord(text[en])) en++;
        var word = text.slice(s, en).trim();
        if (word.length < 1) return;
        window.webkit.messageHandlers.glotty.postMessage({ word: word });
      }, true);
    })();
    """#
}
