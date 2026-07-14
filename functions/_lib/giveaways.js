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
// Edit this object to run a giveaway. Anyone signed in + subscribed can enter (weighted:
// base 1, macro code +2, Pro 10). `endsAt` is an ISO-8601 instant (UTC "Z" recommended)
// that the countdown targets. The `image` is optional (a data: URI or same-origin path);
// the page renders a clean placeholder when it's absent, so it's safe to leave visuals for later.
export const GIVEAWAYS = {
  moonbloom: {
    id: "moonbloom",
    title: "Moon Bloom Seed",
    tagline: "Win 10x Moon Bloom Seeds",
    prize: "Enter the giveaway and have a chance to win 10x Moon Bloom Seeds.",
    endsAt: "2026-07-19T18:00:00Z",
    image: "/10X.png",
  },
};

// The giveaway the public page shows when no ?g= is given.
export const DEFAULT_GIVEAWAY = "moonbloom";

// Return a giveaway (defaulted) with parsed timing fields, or null if the registry is empty.
export function getGiveaway(id) {
  const g = GIVEAWAYS[id] || GIVEAWAYS[DEFAULT_GIVEAWAY];
  if (!g) return null;
  const endsAtMs = Date.parse(g.endsAt) || 0;
  return { ...g, endsAtMs, ended: endsAtMs > 0 && endsAtMs < Date.now() };
}

// All giveaways, defaulted timing included (used by the admin summaries).
export function listGiveaways() {
  return Object.keys(GIVEAWAYS).map((id) => getGiveaway(id));
}
