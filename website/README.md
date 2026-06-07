# Glotty website (Privacy Policy + Support pages)

Two static pages App Store Connect requires, plus a tiny landing page.
No build step, no dependencies — plain HTML.

**Published (GitHub Pages, repo `github.com/yorha59/glotty-site`):**
- Privacy Policy URL → <https://yorha59.github.io/glotty-site/privacy.html>
- Support URL → <https://yorha59.github.io/glotty-site/support.html>

To update the live pages: edit here, then copy into the `glotty-site`
repo and push (it serves `main`/root). These files are the source of truth.

- `privacy.html` → **Privacy Policy URL** (App Store Connect → App Information)
- `support.html` → **Support URL** (App Store Connect → version page)
- `index.html` → optional landing page linking both

## Hosting on GitHub Pages (free, reachable by App Review)

1. Create a public GitHub repo, e.g. `glotty-site`.
2. Copy the contents of this `website/` folder into the repo root and push.
3. Repo **Settings → Pages** → Source: `Deploy from a branch` →
   Branch: `main` / `/ (root)` → Save.
4. After ~1 minute your URLs are:
   - `https://<your-username>.github.io/glotty-site/privacy.html`
   - `https://<your-username>.github.io/glotty-site/support.html`
5. Paste those into App Store Connect.

## Before you publish

- Confirm the contact email (`hemoon@outlook.com`) is the one you want shown.
- If you later ship to **mainland China**, re-host these on a
  China-reachable host (Gitee Pages / a China VPS / your own public
  domain) — `github.io` is unreliable there — and obtain an ICP filing
  (see `doc/app-store-submission.md`).
- A Simplified/Traditional Chinese version can be added as
  `privacy.zh.html` / `support.zh.html` if you want localized listings.
