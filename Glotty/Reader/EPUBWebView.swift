import SwiftUI
import WebKit

/// Renders one EPUB chapter in a `WKWebView`. Because we own the DOM we can do
/// what's impossible inside Books.app: selecting a passage floats a
/// Translate/Ask chip over it, and previously looked-up words are underlined
/// (click one to preview what was saved). Type size + theme are applied by
/// injecting a stylesheet. Resources (CSS / images / fonts) resolve via file
/// URLs scoped to the book's extraction directory.
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
    let onTranslate: (String) -> Void
    let onAsk: (String) -> Void
    /// Fires whenever the selection changes so the window can offer a
    /// keyboard path (⌘T) for the same action the chip exposes.
    let onSelectionChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLookup: onLookup, bookID: bookID) }

    func makeNSView(context: Context) -> NSView {
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

        // Web view + a click-through overlay that hosts the selection chip, so
        // the chip floats above the text without blocking selection elsewhere.
        let container = NSView()
        let overlay = PassthroughView()
        for v in [web, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        let c = context.coordinator
        let chip = NSHostingView(rootView: SelectionChip(
            onTranslate: { [weak c] in c?.translateTapped() },
            onAsk: { [weak c] in c?.askTapped() }))
        chip.isHidden = true
        overlay.addSubview(chip)
        c.overlay = overlay
        c.chip = chip
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let c = context.coordinator
        guard let web = c.webView else { return }
        c.onLookup = onLookup
        c.onTranslate = onTranslate
        c.onAsk = onAsk
        c.onSelectionChange = onSelectionChange
        c.style = Coordinator.Style(scale: fontScale, lineHeight: lineHeight,
                                    letterSpacing: letterSpacing, bg: bg, fg: fg, font: fontCSS)
        c.words = lookedUp.sorted()   // stable order — the dirty check compares it
        if c.loadedChapter != chapterIndex, book.chapters.indices.contains(chapterIndex) {
            c.loadedChapter = chapterIndex
            // Drop the old chapter's selection, else the chip stays floating over
            // the new text and Translate/⌘T would act on the previous chapter.
            c.resetSelection()
            web.loadFileURL(book.chapters[chapterIndex].url, allowingReadAccessTo: book.rootDir)
            // style + marks are (re)applied in didFinish for the fresh document
        } else {
            c.applyStyle()
            c.applyMarks()
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var overlay: NSView?
        var chip: NSHostingView<SelectionChip>?
        var onLookup: (String) -> Void
        var onTranslate: (String) -> Void = { _ in }
        var onAsk: (String) -> Void = { _ in }
        var onSelectionChange: (String) -> Void = { _ in }
        /// Text of the live selection — what the chip and ⌘T act on.
        private var pendingSelection = ""
        let bookID: String
        private var previewPopover: NSPopover?
        var loadedChapter = -1
        struct Style: Equatable {
            var scale = 1.0, lineHeight = 1.65, letterSpacing = 0.0
            var bg = "#ffffff", fg = "#111111", font = ""
        }
        var style = Style()
        var words: [String] = []
        /// Last values actually pushed into the DOM. Re-marking is destructive —
        /// it replaces the text nodes the user's selection is anchored in, which
        /// wipes the live highlight — so only push when something really changed.
        private var appliedStyle: Style?
        private var appliedWords: [String]?

        init(onLookup: @escaping (String) -> Void, bookID: String) {
            self.onLookup = onLookup; self.bookID = bookID
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Fresh document — nothing of ours survived, so force a re-apply.
            appliedStyle = nil; appliedWords = nil
            applyStyle(); applyMarks()
        }

        func applyStyle() {
            guard appliedStyle != style else { return }
            appliedStyle = style
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
            guard appliedWords != words else { return }
            appliedWords = words
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
            if (d["type"] as? String) == "selection" {
                let text = ((d["text"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                pendingSelection = text
                onSelectionChange(text)
                guard !text.isEmpty else { chip?.isHidden = true; return }
                let x = (d["x"] as? Double) ?? 0, y = (d["y"] as? Double) ?? 0
                let w = (d["w"] as? Double) ?? 0, h = (d["h"] as? Double) ?? 0
                layoutChip(cssRect: CGRect(x: x, y: y, width: w, height: h))
                return
            }
            if let word = d["word"] as? String { onLookup(word) }
        }

        /// Place the chip just under the selection. The rect arrives in CSS
        /// pixels (viewport-relative, origin top-left); the overlay is AppKit
        /// (origin bottom-left), hence the flip.
        private func layoutChip(cssRect r: CGRect) {
            guard let overlay, let chip else { return }
            let bounds = overlay.bounds
            guard bounds.height > 0, bounds.width > 0 else { return }
            // Selection scrolled out of view — an unclamped frame would draw the
            // chip outside the reader (over the control bar), where it also
            // wouldn't be clickable.
            guard r.maxY > 0, r.minY < bounds.height else { chip.isHidden = true; return }
            let size = chip.fittingSize
            let x = min(max(2, r.maxX - size.width), max(2, bounds.width - size.width - 2))
            // AppKit y of the selection's bottom edge, then drop the chip below it.
            var y = bounds.height - r.maxY - size.height - 4
            if y < 2 { y = bounds.height - r.minY + 4 }   // no room below → go above
            y = min(max(2, y), max(2, bounds.height - size.height - 2))
            chip.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            chip.isHidden = false
        }

        func translateTapped() {
            let text = pendingSelection
            guard !text.isEmpty else { return }
            onTranslate(text)
            clearSelectionUI()
        }

        func askTapped() {
            let text = pendingSelection
            guard !text.isEmpty else { return }
            onAsk(text)
            clearSelectionUI()
        }

        private func clearSelectionUI() {
            resetSelection()
            webView?.evaluateJavaScript("window.getSelection().removeAllRanges()",
                                        completionHandler: nil)
        }

        /// Forget the current selection. Called on chapter change too, where it
        /// runs inside `updateNSView` — hence the deferred `onSelectionChange`,
        /// which writes SwiftUI state and must not fire during a view update.
        func resetSelection() {
            chip?.isHidden = true
            guard !pendingSelection.isEmpty else { return }
            pendingSelection = ""
            let notify = onSelectionChange
            DispatchQueue.main.async { notify("") }
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

      // Left-click on an already-looked-up (underlined) word → preview the saved
      // record. A bare click no longer fires a look-up: reading the book used to
      // trip the popup constantly. Translation is selection-driven now (chip/⌘T).
      document.addEventListener('click', function (e) {
        if (e.button !== 0) return;                 // never the secondary button
        var seen = e.target && e.target.closest ? e.target.closest('span.glotty-seen') : null;
        if (!seen) return;
        window.webkit.messageHandlers.glotty.postMessage(
          { type: 'preview', term: seen.textContent, x: e.clientX, y: e.clientY });
        e.preventDefault(); e.stopPropagation();
      }, true);

      // Report the current selection (with its viewport rect) so Swift can float
      // the Translate/Ask chip over it — same interaction the PDF reader uses.
      var postSel = function () {
        var sel = window.getSelection();
        var text = sel ? String(sel).trim() : '';
        if (!text || !sel.rangeCount) {
          window.webkit.messageHandlers.glotty.postMessage({ type: 'selection', text: '' });
          return;
        }
        var r = sel.getRangeAt(0).getBoundingClientRect();
        window.webkit.messageHandlers.glotty.postMessage(
          { type: 'selection', text: text, x: r.left, y: r.top, w: r.width, h: r.height });
      };
      // Selection finishes on primary mouse-up; keyboard selection ends on keyup.
      // Deferred a tick so the selection is settled when we read it.
      document.addEventListener('mouseup', function (e) {
        if (e.button !== 0) return;
        setTimeout(postSel, 0);
      }, true);
      document.addEventListener('keyup', function () { setTimeout(postSel, 0); }, true);
      // Keep the chip glued to the text while the page moves. Coalesced to one
      // report per frame — getBoundingClientRect forces layout, and a raw scroll
      // listener fires far more often than the chip needs to move.
      var selQueued = false;
      window.addEventListener('scroll', function () {
        if (selQueued) return;
        selQueued = true;
        requestAnimationFrame(function () { selQueued = false; postSel(); });
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
