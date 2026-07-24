import Foundation

/// One web result handed to the model when it calls the search tool.
struct WebSearchResult: Codable, Equatable {
    let title: String
    let url: String
    let snippet: String
}

/// Keyless web search, so any provider's chat can be grounded in current
/// information — not just Z.AI, whose native `web_search` tool is the only
/// built-in one among the providers we ship.
///
/// Uses DuckDuckGo's HTML endpoint: no API key, no signup. It's a scrape, so
/// it's inherently more fragile than a paid search API — the parsing is
/// defensive and an empty result just tells the model it found nothing, which
/// is a normal tool outcome rather than an error.
enum WebSearch {
    static func run(query: String, limit: Int = 5) async -> [WebSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              var comps = URLComponents(string: "https://html.duckduckgo.com/html/")
        else { return [] }
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        // DDG's HTML endpoint returns an empty page to obvious bots; a normal
        // desktop UA gets the real results.
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12

        // One retry: being a scrape, DDG drops or throttles the odd request,
        // and an empty result would otherwise read to the model as "nothing
        // exists" rather than "try again".
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let htmlStr = String(data: data, encoding: .utf8) else { continue }
            let results = parse(htmlStr, limit: limit)
            if !results.isEmpty { return results }
        }
        return []
    }

    // MARK: parsing

    static func parse(_ html: String, limit: Int) -> [WebSearchResult] {
        let titles = matches(#"result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: html)
        let snippets = matches(#"result__snippet"[^>]*>(.*?)</a>"#, in: html).map { $0.1 }
        var out: [WebSearchResult] = []
        for (i, (href, titleHTML)) in titles.enumerated() where out.count < limit {
            let title = strip(titleHTML)
            guard !title.isEmpty else { continue }
            let snippet = i < snippets.count ? strip(snippets[i]) : ""
            out.append(WebSearchResult(title: title, url: resolve(href), snippet: snippet))
        }
        return out
    }

    /// DDG wraps result links in a redirector: `//duckduckgo.com/l/?uddg=<enc>`.
    /// Pull the real destination back out.
    private static func resolve(_ href: String) -> String {
        let full = href.hasPrefix("//") ? "https:" + href : href
        guard let comps = URLComponents(string: full),
              let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return full }
        return uddg
    }

    private static func matches(_ pattern: String, in s: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            let a = m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ""
            let b = m.numberOfRanges > 2 ? ns.substring(with: m.range(at: 2)) : a
            return (a, b)
        }
    }

    /// Drop tags and decode entities from a snippet of result HTML.
    private static func strip(_ s: String) -> String {
        let noTags = s.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
