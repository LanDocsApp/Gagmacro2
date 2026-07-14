// Giveaway registry + entry-weighting rules — the single source of truth the owner edits.
//
// Same pattern as _lib/creators.js: the giveaways themselves live in code (no CRUD table),
// so running a new one is a one-line edit + redeploy. Runtime state (who entered, who won)
// lives in D1 (see migrations/0007_add_giveaways.sql).

// The code shown at the BOTTOM of the macro window (under the version line). Entering it on
// the giveaway page proves the person actually has the free macro installed -> +2 entries.
// It is a single shared code (everyone with the macro sees the same one), by design — this
// is a low-stakes "do you have the macro?" check, not a per-user secret. Keep it in sync with
// the macro's footer in macro.ahk (search for GiveawayCode).
export const MACRO_CODE = "3QIHX";

// White Lion's channel. sub_confirmation=1 pops the YouTube subscribe dialog directly.
export const SUBSCRIBE_URL = "https://www.youtube.com/@whitelion15rbx?sub_confirmation=1";

// Raffle tickets per account. YouTube gives no reliable way to verify a subscribe, so the
// subscribe is an honor gate (it unlocks entry) and does NOT itself add tickets — the ladder
// rewards actually having / paying for the macro, which is the growth lever:
//   base  = signed in with Google + confirmed the subscribe        -> 1 ticket
//   macro = entered the code shown in the macro (has the free app)  -> 3 tickets (1 + 2 bonus)
//   pro   = active Pro member                                       -> 10 tickets
export const WEIGHTS = { base: 1, macro: 3, pro: 10 };

// Resolve an account's ticket count. Pro always wins (10); otherwise +2 for having the macro.
export function computeWeight({ hasMacro, isPro }) {
  if (isPro) return WEIGHTS.pro;
  if (hasMacro) return WEIGHTS.macro;
  return WEIGHTS.base;
}

// ---- The giveaways -------------------------------------------------------
//
// Edit this object to run a giveaway. `endsAt` is an ISO-8601 instant (UTC "Z" recommended)
// that the countdown targets. `kind`:
//   'normal'  — anyone signed in + subscribed can enter (weighted).
//   'premium' — same page, but only active Pro members can enter (better prizes).
// The `image` is optional (a data: URI or same-origin path); the page renders a clean
// placeholder when it's absent, so it's safe to leave the visuals for later.
export const GIVEAWAYS = {
  venusflytrap: {
    id: "venusflytrap",
    title: "Venus Fly Trap Seed",
    tagline: "One lucky winner gets a Venus Fly Trap Seed",
    prize: "1x Venus Fly Trap Seed, delivered straight into your Grow a Garden account.",
    kind: "normal",
    endsAt: "2026-07-28T18:00:00Z",
    image: "/VenusFlyTrapSeed.webp",
  },
  "pro-drop": {
    id: "pro-drop",
    title: "Pro Members Mega Drop",
    tagline: "A bigger prize — Pro members only",
    prize: "A premium seed bundle reserved for Pro members. Bigger prizes, far better odds.",
    kind: "premium",
    endsAt: "2026-07-28T18:00:00Z",
    image: "",
  },
};

// The giveaway the public page shows when no ?g= is given.
export const DEFAULT_GIVEAWAY = "venusflytrap";

// Return a giveaway (defaulted) with parsed timing fields, or null if the registry is empty.
export function getGiveaway(id) {
  const g = GIVEAWAYS[id] || GIVEAWAYS[DEFAULT_GIVEAWAY];
  if (!g) return null;
  const endsAtMs = Date.parse(g.endsAt) || 0;
  return { ...g, endsAtMs, ended: endsAtMs > 0 && endsAtMs < Date.now() };
}

// All giveaways, defaulted timing included (used to cross-link normal <-> premium).
export function listGiveaways() {
  return Object.keys(GIVEAWAYS).map((id) => getGiveaway(id));
}
