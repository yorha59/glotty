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
    /// Clear a word's underline (from the preview popover's delete action).
    let onRemoveUnderline: (String) -> Void
    let onTranslate: (String) -> Void
    let onAsk: (String) -> Void
    /// Fires whenever the selection changes so the window can offer a
    /// keyboard path (⌘T) for the same action the chip exposes.
    let onSelectionChange: (String) -> Void
    /// Current page within the chapter, and how many there are. Two-way: the
    /// web view reports what it laid out, and writing a new value pages there.
    @Binding var page: Int
    @Binding var pageCount: Int
    /// Paging past either end of a chapter — `dir` is +1 or -1.
    let onChapterFlip: (Int) -> Void
    /// Where to land after a chapter load: the end, when the reader arrived by
    /// paging backwards.
    let landOnLastPage: Bool

    /// Side margin around the text, applied to the view rather than in CSS so
    /// it survives horizontal paging.
    private static let pageMargin: CGFloat = 44

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
        // Both are inset by the page margin: the paged layout scrolls the text
        // horizontally, so a CSS margin would only apply to the first page —
        // insetting the view itself keeps the margin on every page. The
        // container carries the book's background so the inset isn't a gap.
        let container = NSView()
        container.wantsLayer = true
        let overlay = PassthroughView()
        for v in [web, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.pageMargin),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.pageMargin),
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
        container.layer?.backgroundColor = NSColor(Color(readerHex: bg)).cgColor
        c.onLookup = onLookup
        c.onRemoveUnderline = onRemoveUnderline
        c.onTranslate = onTranslate
        c.onAsk = onAsk
        c.onSelectionChange = onSelectionChange
        c.onChapterFlip = onChapterFlip
        let pageB = $page, countB = $pageCount
        c.onPagination = { p, n in
            if pageB.wrappedValue != p { pageB.wrappedValue = p }
            if countB.wrappedValue != n { countB.wrappedValue = n }
        }
        c.style = Coordinator.Style(scale: fontScale, lineHeight: lineHeight,
                                    letterSpacing: letterSpacing, bg: bg, fg: fg, font: fontCSS)
        c.words = lookedUp.sorted()   // stable order — the dirty check compares it
        if c.loadedChapter != chapterIndex, book.chapters.indices.contains(chapterIndex) {
            c.loadedChapter = chapterIndex
            // `page` is 0 for a forward flip and the restored position when a
            // book is reopened, so landing on it covers both.
            c.pendingLanding = landOnLastPage ? -1 : page
            // Drop the old chapter's selection, else the chip stays floating over
            // the new text and Translate/⌘T would act on the previous chapter.
            c.resetSelection()
            web.loadFileURL(book.chapters[chapterIndex].url, allowingReadAccessTo: book.rootDir)
            // style + marks are (re)applied in didFinish for the fresh document
        } else {
            c.applyStyle()
            c.applyMarks()
            c.syncPage(page)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var overlay: NSView?
        var chip: NSHostingView<SelectionChip>?
        var onLookup: (String) -> Void
        var onRemoveUnderline: (String) -> Void = { _ in }
        var onTranslate: (String) -> Void = { _ in }
        var onAsk: (String) -> Void = { _ in }
        var onSelectionChange: (String) -> Void = { _ in }
        var onPagination: (Int, Int) -> Void = { _, _ in }
        var onChapterFlip: (Int) -> Void = { _ in }
        /// Page to land on once the next chapter finishes loading; -1 = the end.
        var pendingLanding: Int?
        /// Last page the web view reported, so a state round-trip doesn't
        /// re-issue a scroll it already performed.
        private var reportedPage = 0
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
            reportedPage = 0
            applyStyle(); applyMarks()   // applyStyle paginates
            // Queued after the two above, so the layout exists by the time we land.
            let landing = pendingLanding ?? 0
            pendingLanding = nil
            webView.evaluateJavaScript(
                landing < 0 ? "__glottyGoto(__glottyPages() - 1)" : "__glottyGoto(\(landing))",
                completionHandler: nil)
        }

        /// Page the web view to `p` when SwiftUI asks for a page it isn't on.
        func syncPage(_ p: Int) {
            guard p != reportedPage else { return }
            reportedPage = p
            webView?.evaluateJavaScript("__glottyGoto(\(p))", completionHandler: nil)
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
            if (d["type"] as? String) == "pagination" {
                let p = (d["page"] as? Int) ?? 0, n = (d["pages"] as? Int) ?? 1
                reportedPage = p
                onPagination(p, max(1, n))
                return
            }
            if (d["type"] as? String) == "chapterFlip" {
                onChapterFlip((d["dir"] as? Int) ?? 1)
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
                rootView: QueryPreviewView(
                    record: record,
                    onLookAgain: { [weak self] in
                        self?.previewPopover?.performClose(nil)
                        self?.onLookup(term)
                    },
                    onRemoveUnderline: { [weak self] in
                        self?.previewPopover?.performClose(nil)
                        self?.onRemoveUnderline(term)
                    }))
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

      // Paged layout, Apple-Books style: `html` is the fixed frame (padding =
      // the page margin, clips the overflow), `body` is a multi-column box that
      // overflows horizontally and is paged with scrollLeft. Two columns once
      // the window is wide enough, so a big window isn't mostly dead margin.
      window.__glottyStyle = function (scale, bg, fg, lineHeight, letterSpacing, font) {
        var st = document.getElementById('glotty-style');
        if (!st) { st = document.createElement('style'); st.id = 'glotty-style'; (document.head || document.documentElement).appendChild(st); }
        var ff = font ? ('font-family:' + font + ' !important;') : '';
        st.textContent =
          // `body` is the scroll container; `#glotty-page` inside it is the
          // multi-column box. The split matters: a scroll container SCROLLS its
          // overflow instead of fragmenting it into overflow columns, so the
          // multicol box must not be the scroller itself.
          'html{height:100%; overflow:hidden; margin:0; padding:0;' +
          'background:' + bg + ' !important;}' +
          'html,body{color:' + fg + ' !important;' + ff +
          'font-size:' + (scale * 100) + '% !important; line-height:' + lineHeight + ' !important;' +
          'letter-spacing:' + letterSpacing + 'em !important; -webkit-text-size-adjust:none;}' +
          'body{background:' + bg + ' !important; height:100%; margin:0; padding:0;' +
          'overflow:hidden;}' +
          'body::-webkit-scrollbar{display:none;}' +
          '#glotty-page{height:100%; box-sizing:border-box; padding:30px 0 34px;' +
          'column-fill:auto;}' +
          // Nothing may outgrow one column-height, or it creates a blank page.
          'img,svg,table{max-width:100% !important; max-height:100% !important; height:auto !important;}' +
          'a{color:#3b82f6;}' +
          'span.glotty-seen{text-decoration:underline; text-decoration-color:#3b82f6;' +
          'text-decoration-thickness:2px; text-underline-offset:3px; cursor:pointer;}';
        __glottyWrap();
        __glottyPaginate();
      };

      // Move the chapter's content into our own multicol box. Done once per
      // document — the EPUB's own CSS targets body, which we leave alone.
      window.__glottyWrap = function () {
        if (document.getElementById('glotty-page')) return;
        var b = document.body; if (!b) return;
        var wrap = document.createElement('div');
        wrap.id = 'glotty-page';
        while (b.firstChild) wrap.appendChild(b.firstChild);
        b.appendChild(wrap);
      };

      // --- paging -----------------------------------------------------------
      // A "page" is the visible body box; the next page starts one gap later,
      // so advancing means scrolling by clientWidth + columnGap.
      window.__glottyGap = function () {
        var w = document.getElementById('glotty-page');
        return w ? (parseFloat(getComputedStyle(w).columnGap) || 0) : 0;
      };
      window.__glottyStep = function () {
        var b = document.body; if (!b) return 0;
        return b.clientWidth + __glottyGap();
      };
      window.__glottyPages = function () {
        var b = document.body; if (!b) return 1;
        var step = __glottyStep(); if (step <= 0) return 1;
        // P pages span P*clientWidth + (P-1)*gap  ==  P*step - gap.
        return Math.max(1, Math.round((b.scrollWidth + __glottyGap()) / step));
      };
      window.__glottyPage = function () {
        var b = document.body, step = __glottyStep();
        return step > 0 ? Math.round(b.scrollLeft / step) : 0;
      };
      window.__glottyReport = function () {
        window.webkit.messageHandlers.glotty.postMessage(
          { type: 'pagination', page: __glottyPage(), pages: __glottyPages() });
      };
      window.__glottyGoto = function (page) {
        var b = document.body; if (!b) return;
        var p = Math.max(0, Math.min(__glottyPages() - 1, page));
        b.scrollLeft = p * __glottyStep();
        __glottyReport();
      };
      // Step one page; at either end hand off to Swift for a chapter change.
      window.__glottyFlip = function (dir) {
        var next = __glottyPage() + dir;
        if (next < 0 || next >= __glottyPages()) {
          window.webkit.messageHandlers.glotty.postMessage({ type: 'chapterFlip', dir: dir });
          return;
        }
        __glottyGoto(next);
      };
      window.__glottyPaginate = function (keepPage) {
        var wrap = document.getElementById('glotty-page'); if (!wrap) return;
        var w = window.innerWidth;
        // Two columns only when each still gets a readable measure.
        var cols = w >= 820 ? 2 : 1;
        var gap = Math.round(Math.min(76, Math.max(36, w * 0.045)));
        wrap.style.columnGap = gap + 'px';
        // Sized via column-WIDTH, never column-count: WebKit only produces the
        // horizontal overflow columns paging depends on when the width is what's
        // specified. `column-count:1` lays the chapter out as one 20000px-tall
        // column that just gets clipped — i.e. most of the text disappears.
        wrap.style.columnCount = 'auto';
        var avail = wrap.clientWidth || w;
        // floor, not ceil: the browser fits floor((W+gap)/(colW+gap)) columns,
        // so rounding colW *up* by a pixel drops the count to one.
        wrap.style.columnWidth =
          Math.max(120, Math.floor((avail - gap * (cols - 1)) / cols)) + 'px';
        if (typeof keepPage === 'number') __glottyGoto(keepPage); else __glottyReport();
      };

      document.addEventListener('keydown', function (e) {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        if (e.key === 'ArrowRight' || e.key === 'PageDown' || e.key === ' ') {
          __glottyFlip(1); e.preventDefault();
        } else if (e.key === 'ArrowLeft' || e.key === 'PageUp') {
          __glottyFlip(-1); e.preventDefault();
        }
      }, true);

      // Wheel / two-finger swipe pages instead of scrolling. Accumulated with a
      // threshold + cooldown so one gesture doesn't fly through several pages.
      var wheelAcc = 0, wheelLock = 0;
      window.addEventListener('wheel', function (e) {
        e.preventDefault();
        var now = Date.now();
        if (now < wheelLock) return;
        wheelAcc += Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
        if (Math.abs(wheelAcc) < 60) return;
        __glottyFlip(wheelAcc > 0 ? 1 : -1);
        wheelAcc = 0; wheelLock = now + 320;
      }, { passive: false });

      var reflowTimer = null;
      window.addEventListener('resize', function () {
        clearTimeout(reflowTimer);
        var at = __glottyPage();
        reflowTimer = setTimeout(function () { __glottyPaginate(at); }, 120);
      });

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
    /// Clear this word's underline. The look-up stays in the library.
    let onRemoveUnderline: () -> Void
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
            HStack(spacing: 10) {
                Text(record.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                // Icon-only: the full label doesn't fit beside "Look up again"
                // in the popover's width.
                Button(role: .destructive, action: onRemoveUnderline) {
                    Image(systemName: "trash")
                }
                .font(.caption)
                .accessibilityLabel("Remove underline")
                .help("Remove this word's underline. The look-up stays in the library.")
                Button("Look up again", action: onLookAgain).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
