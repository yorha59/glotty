# Hosted AI + Payment — architecture design (exploratory)

Status: **discussion / not implemented.** Captures the design direction for
adding paid hosted AI to Glotty so it can be picked up later. Nothing here is
built yet; treat it as a decision record + plan, not current behavior.

Date: 2026-06-07.

---

## 1. Goal & motivation

Today Glotty is **bring-your-own-key (BYO)**: the user pastes an LLM provider
API key (z.ai / DeepSeek / Gemini / OpenAI-compatible …), stored in Keychain.
That key-setup step is a wall for non-technical users.

**Plan: offer hosted AI** — the user subscribes and Glotty provides the LLM,
no key setup. "It just works after you subscribe." This is the higher-value
product for mainstream users.

Trade-offs accepted going in:
- Glotty becomes a **data processor** — text now leaves the device through our
  server. This changes the "local/private" story; must be disclosed.
- We now **run and are on-call for a service** (the gateway + auth/billing).

---

## 2. Decisions made

1. **Hosted AI** (vs feature-unlock-only). BYO stays as a fallback.
2. **Flat subscription** (fair-use), not usage credits. Simpler, nicer UX.
3. **Singleflight: deferred.** Like caching, it mostly pays off at scale (it
   only helps when many users hit the *same uncached* query simultaneously —
   rare with a small user base). Not worth the cost/complexity now.
4. **No caching yet** — same reasoning; revisit at scale.
5. **Gateway: lean self-hosted LiteLLM** (see §6), keeping the data path to
   just `app → our server → provider` (privacy), and getting per-user
   budgets / observability / provider fallback off the shelf.

### Primary cost lever at low scale
NOT dedup (singleflight/cache) — those need scale. It's **per-user fair-use
quotas / rate limits**, which a flat subscription needs anyway so one heavy
user can't drain the margin. Build this from day one.

---

## 3. Keep BYO as a fallback (cheap, architecturally)

Glotty already has a provider abstraction (`OpenAICompatibleProvider`,
`DeepSeekProvider`, … selected by `glotty.llmProvider`). Hosted AI is just
**one more provider — "Glotty Cloud"** — that targets *our* gateway and
authenticates with a **session token** instead of a user API key.

- Default for normal users: **Glotty Cloud** (subscription).
- Power users / privacy-conscious: **BYO key** (unchanged).
- The rest of the app is unchanged — it still calls "the current provider."
- De-risks launch: a gateway outage doesn't break BYO users, and Cloud users
  can fall back (Apple Translation for plain translate, local dictionaries)
  to stay useful offline.

---

## 4. The two-distribution-channel constraint

Glotty ships **Mac App Store** *and* **Developer ID (DMG)**. Payment rules
differ and both rails must end at the **same kind of gateway token**:

| | Mac App Store | Direct (DMG) |
|---|---|---|
| Payment | **StoreKit 2 subscription is mandatory** | Stripe / Paddle / LemonSqueezy (Apple IAP forbidden) |
| Tax/VAT | Apple handles | self, or a Merchant-of-Record (Paddle/LemonSqueezy) handles |
| Cut | 15–30% | ~0–8% + fees |

Hosted AI **forces per-user identity** (the gateway meters/quotas each user),
so the anonymous-license-key option that would work for feature-unlock is off
the table here. A purchase on either channel must mint a per-user token.

---

## 5. The piece we actually have to build: purchase → gateway token

This is the same regardless of which gateway product we pick.

```
                       ┌────────────────────────────┐
 StoreKit 2 (MAS) ────▶│  our auth/entitlement svc  │
 Stripe/Paddle (direct)│  - verify the subscription │──▶ mint short-lived,
   via webhook ───────▶│  - map to a Glotty user    │    refreshable per-user
                       │  - enforce quota/fair-use  │    TOKEN (stored in
                       └────────────────────────────┘    Keychain on device)
```

- **MAS**: verify with StoreKit 2 (`Transaction.currentEntitlements` on device;
  App Store Server API server-side for robustness).
- **Direct**: Stripe/Paddle subscription; reconcile via **webhook** to our svc.
- **Token**: short-lived + refreshable so a leaked token can't drain the bill;
  carries the user id + quota class. App sends it to the gateway as its
  "Glotty Cloud" credential.
- **Identity**: required here (unlike feature-unlock). Keep PII at the payment
  provider; our svc maps purchase → opaque user id. Consider
  Sign-in-with-Apple to minimize account friction.

`EntitlementStore` in the app remains the single source of truth for
"is the user a paying Cloud subscriber" and feeds both the Cloud provider's
auth and any UI gating.

---

## 6. The gateway

A proxy between the app and the model providers. What it buys us:

1. **Observability / cost attribution** — per-request tokens, latency, $ per
   user/feature. Highest early value: *we* pay the bill, so seeing where
   tokens go (and catching runaways) is essential.
2. **Virtual keys + budgets + rate limits** — per-user key with a spend/req
   cap = our flat-sub fair-use enforcement, without hand-building metering.
3. **Provider routing & fallback** — auto-failover if a provider is down /
   rate-limited; swap or A/B models centrally without an app update.
4. **Retries / load-balancing** across keys.
5. **Caching** — toggle on later, no app change.
6. **Guardrails / PII redaction** (some products).

What a gateway does **not** replace: our subscription billing, the
purchase→token mint (§5), user identity, and true **singleflight** (gateways
give persistent caching, not in-flight dedup — that's a small custom piece if
we ever want it specifically).

### Product landscape
- **LiteLLM (self-hosted, OSS)** — unified provider API, **virtual keys with
  budgets + rate limits + spend tracking**, fallbacks, optional caching. Sweet
  spot: full control, per-user quota infra out of the box, data path stays
  `app → our server → provider`. *(Chosen direction.)*
- **Cloudflare AI Gateway (hosted)** — analytics, caching, rate limiting,
  retries; near-zero ops; lighter on per-user budgets.
- **Portkey** — routing, fallbacks, virtual keys + budgets, caching,
  guardrails; OSS gateway + hosted.
- **Helicone** — observability/logging/cost + caching + rate limits; drop-in.
- **OpenRouter** — provider *aggregation* + one bill to us, but NOT a
  per-*our-user* metering layer (Glotty already supports it as a BYO provider).

### Privacy catch
A **hosted** gateway (Cloudflare/Portkey/Helicone) adds **another third party**
to the data path: `app → gateway-vendor → provider`. For a privacy-positioned
app that's an extra processor to disclose/trust. **Self-hosting (LiteLLM)**
keeps the chain to just us — same trust boundary we already accept by going
hosted-AI at all. This is why the lean is self-host.

### Recommended shape

```
app ──(per-user token)──▶ thin auth/quota shim ──▶ LiteLLM ──▶ providers
                              │                       │
                     verify subscription,      virtual keys, budgets,
                     mint/rotate token          fallback, usage logs
```

If we want zero servers: Cloudflare AI Gateway gives observability + caching
with no ops, but we still need a tiny serverless function for purchase→token +
quota, and accept the extra third party in the path.

---

## 7. Cost levers (priority order for our scale)

1. **Per-user fair-use quotas / rate limits** — protects the flat-sub margin
   now (gateway virtual keys). **Build first.**
2. **Provider/model cost tuning** — route to cheaper models per task
   (e.g. cheap model for plain translate, stronger for explain/polish);
   centralized in the gateway, no app update.
3. **On-device cache** (free, private) — repeat lookups by the same user never
   hit the server. Extend the existing local caches for Cloud results.
4. **Singleflight** — collapse concurrent identical in-flight calls. *Scale.*
5. **Server-side shared cache** — cross-user dedup; biggest COGS win, but only
   at scale, and carries a privacy rule (below). *Scale.*

### Caching design notes (for when we add it)
- Cache key must include everything that changes output:
  `hash(text, sourceLang, targetLang, mode, model, promptVersion)`.
- Set **temperature 0** for translate so caching is legitimate.
- **Version the prompt/model in the key** so a prompt/model change doesn't
  serve stale results.
- **Shared-cache privacy split**: only share-cache **short/generic inputs**
  (single words / dictionary lookups / below a length threshold). Use
  **per-user or no cache** for free-form text (a sentence may contain PII; a
  shared cache would store/serve it across users). This also aligns the
  savings with the cheap, high-volume operations.

---

## 8. Billing model

**Flat subscription with fair-use.** Headline can be "unlimited everyday use,"
with quotas/rate-limits capping abuse and the long tail. StoreKit
auto-renewable subscription on MAS; Stripe/Paddle subscription direct. Both
mint the same gateway token (§5).

---

## 9. Risks to design for

- **Cost runaway / abuse** — per-user quotas, rate limits, short-lived tokens,
  anomaly alerts. A leaked token must not be able to drain the provider bill.
- **Latency & offline** — gateway adds a hop; keep on-device fallback (Apple
  Translation, local dictionaries) for outages/offline.
- **MAS rules** — subscription must be StoreKit IAP on the App Store; can't
  point MAS users at Stripe. Both rails mint the same token kind.
- **Privacy posture shift** — be explicit in UI + policy that Cloud sends text
  to our servers; keep BYO/local as the "nothing leaves your device" option.
- **Service ownership** — uptime, on-call, provider key rotation, billing
  reconciliation. Real operational weight for a solo dev.

---

## 10. Phased rollout

1. **"Glotty Cloud" provider + gateway + per-user tokens + quotas** (no cache,
   no singleflight). Prove the purchase→token→metered-call loop end to end.
2. **Model cost tuning** in the gateway (cheap model for translate, etc.).
3. **On-device Cloud cache** (free, private; helps UX latency too).
4. **Singleflight**, then **server-side shared cache** with the privacy split
   — only once scale justifies the complexity.

---

## 11. Open decisions / questions

- **Identity**: Sign-in-with-Apple vs email vs anonymous device-bound account?
  (Hosted AI needs *some* per-user identity for metering.)
- **Cross-channel entitlement**: does a MAS subscription unlock the DMG build
  and vice-versa? (Account-based = yes but more backend; per-channel = simpler.)
- **Direct payment provider**: Stripe (we handle tax) vs Paddle/LemonSqueezy
  (Merchant-of-Record handles global VAT/sales tax — likely better for solo).
- **Free tier**: is there a limited free hosted tier, or is hosted strictly
  paid (with BYO as the free path)?
- **Build vs buy the gateway** confirmed as self-hosted LiteLLM, but revisit if
  ops burden outweighs the privacy benefit.

---

## Related
- `doc/ime-fullscreen-issue.md` — agent/regular activation model.
- `doc/app-store-submission.md`, `doc/release-checklist.md` — the MAS + Dev ID
  dual-distribution context that forces the two payment rails.
