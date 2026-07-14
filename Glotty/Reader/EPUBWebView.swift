import SwiftUI
import WebKit

/// Renders one EPUB chapter in a `WKWebView`. Because we own the DOM we can do
/// what's impossible inside Books.app: a tap on any word fires Glotty's lookup
/// popup, and previously looked-up words are underlined (and re-tappable). Type
/// size + theme are applied by injecting a stylesheet. Resources (CSS / images /
/// fonts) resolve via file URLs scoped to the book's extraction directory.
struct EPUBWebView: NSViewRepresentable {
    let book: EPUBBook
    let bookID: String
    let chapterIndex: Int
    let fontScale: Double
    let bg: String
    let fg: String
    let lineHeight: Double
    let letterSpacing: Double
    let fontCSS: String
    let lookedUp: Set<String>
    let onLookup: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLookup: onLookup, bookID: bookID) }

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
        c.style = Coordinator.Style(scale: fontScale, lineHeight: lineHeight,
                                    letterSpacing: letterSpacing, bg: bg, fg: fg, font: fontCSS)
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
        let bookID: String
        private var previewPopover: NSPopover?
        var loadedChapter = -1
        struct Style {
            var scale = 1.0, lineHeight = 1.65, letterSpacing = 0.0
            var bg = "#ffffff", fg = "#111111", font = ""
        }
        var style = Style()
        var words: [String] = []

        init(onLookup: @escaping (String) -> Void, bookID: String) {
            self.onLookup = onLookup; self.bookID = bookID
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyStyle(); applyMarks()
        }

        func applyStyle() {
            let s = style
            webView?.evaluateJavaScript(
                "window.__glottyStyle && __glottyStyle(\(s.scale), \(Self.jsString(s.bg)), \(Self.jsString(s.fg)), \(s.lineHeight), \(s.letterSpacing), \(Self.jsString(s.font)))",
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
            guard let d = message.body as? [String: Any] else { return }
            if (d["type"] as? String) == "preview", let term = d["term"] as? String {
                let x = (d["x"] as? Double) ?? 0, y = (d["y"] as? Double) ?? 0
                showPreview(term: term, at: CGPoint(x: x, y: y))
                return
            }
            if let word = d["word"] as? String { onLookup(word) }
        }

        /// Popover previewing the saved look-up for an underlined word. Falls
        /// back to a fresh look-up if nothing was recorded.
        private func showPreview(term: String, at pt: CGPoint) {
            guard let web = webView else { return }
            guard let record = BookLibrary.record(bookID: bookID, term: term) else { onLookup(term); return }
            previewPopover?.performClose(nil)
            let pop = NSPopover()
            pop.behavior = .transient
            let term = term
            pop.contentViewController = NSHostingController(
                rootView: QueryPreviewView(record: record) { [weak self] in
                    self?.previewPopover?.performClose(nil)
                    self?.onLookup(term)
                })
            pop.show(relativeTo: NSRect(x: pt.x, y: pt.y, width: 1, height: 1),
                     of: web, preferredEdge: .maxY)
            previewPopover = pop
        }
    }

    /// Injected once per chapter. Defines the style + underline helpers and wires
    /// a capturing click handler that resolves the word under the pointer and
    /// posts it back to Swift.
    private static let bootstrapJS = #"""
    (function () {
      if (window.__glottyReady) return; window.__glottyReady = true;

      window.__glottyStyle = function (scale, bg, fg, lineHeight, letterSpacing, font) {
        var st = document.getElementById('glotty-style');
        if (!st) { st = document.createElement('style'); st.id = 'glotty-style'; (document.head || document.documentElement).appendChild(st); }
        var ff = font ? ('font-family:' + font + ' !important;') : '';
        st.textContent =
          'html,body{background:' + bg + ' !important; color:' + fg + ' !important;' + ff +
          'font-size:' + (scale * 100) + '% !important; line-height:' + lineHeight + ' !important;' +
          'letter-spacing:' + letterSpacing + 'em !important; -webkit-text-size-adjust:none;}' +
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
        // Click on an already-looked-up (underlined) word → preview the record.
        var seen = e.target && e.target.closest ? e.target.closest('span.glotty-seen') : null;
        if (seen) {
          window.webkit.messageHandlers.glotty.postMessage(
            { type: 'preview', term: seen.textContent, x: e.clientX, y: e.clientY });
          e.preventDefault(); e.stopPropagation();
          return;
        }
        var r = document.caretRangeFromPoint ? document.caretRangeFromPoint(e.clientX, e.clientY) : null;
        if (!r) return;
        var node = r.startContainer;
        if (!node || node.nodeType !== 3) return;
        var text = node.textContent, i = r.startOffset, s = i, en = i;
        while (s > 0 && isWord(text[s - 1])) s--;
        while (en < text.length && isWord(text[en])) en++;
        var word = text.slice(s, en).trim();
        if (!/\p{L}/u.test(word)) return;   // need a letter — ignore lone punctuation
        window.webkit.messageHandlers.glotty.postMessage({ type: 'lookup', word: word });
      }, true);
    })();
    """#
}

/// The click-preview shown for an underlined (already-looked-up) word.
struct QueryPreviewView: View {
    let record: QueryRecord
    let onLookAgain: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(record.term).font(.headline).lineLimit(2)
                Text(record.kind == "translate" ? "Translation" : "Explanation")
                    .font(.caption2).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
            }
            ScrollView {
                Text(record.result)
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            HStack {
                Text(record.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Look up again", action: onLookAgain).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
