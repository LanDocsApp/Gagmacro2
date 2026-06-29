// Creator registry for the per-creator stats dashboard (/creator.html).
//
// Each creator owns one or more promo codes -- the same codes the macro offers on
// first launch (see PromoValid in macro.ahk) and the same strings used as Stripe
// promotion codes at checkout. A creator's dashboard aggregates installs and paid
// subscriptions across ALL of their codes, with a per-code breakdown.
//
// The `id` slug (the map key) is what gets embedded in a creator's signed private
// link; it is not secret. Keep this list in sync with macro.ahk's PromoValid when
// adding or removing a code.

export const CREATORS = {
  jose:  { name: "jose",       codes: ["OVER"] },
  jukem: { name: "jukemplayz", codes: ["ROOKIE", "JUKEM"] },
  lion:  { name: "White Lion", codes: ["LION"] },
  vexy:  { name: "VexyChaos",  codes: ["VEXY"] },
};

// Look up a creator by slug (case-insensitive). Returns { id, name, codes } or null.
export function getCreator(id) {
  const key = String(id || "").trim().toLowerCase();
  const c = CREATORS[key];
  return c ? { id: key, name: c.name, codes: c.codes.slice() } : null;
}

// Non-creator system discount codes the macro shows on its own (NOT attribution
// codes), tagged by the lever they represent so the Money dashboard can compare
// "which popup converts". Keep in sync with macro.ahk:
//   superseed -> post-session "seeds you missed" upsell (20%)
//   promacro  -> 5h/20h runtime loyalty popup (50%)
export const SYSTEM_CODE_PURPOSE = {
  SUPERSEED: "conversion",
  PROMACRO: "loyalty",
};

// Reverse index: uppercased creator code -> owning creator slug.
const CODE_TO_CREATOR = (() => {
  const m = {};
  for (const id of Object.keys(CREATORS))
    for (const code of CREATORS[id].codes) m[code.toUpperCase()] = id;
  return m;
})();

// Tag a promo code string with its purpose + owning creator (if any). Used to
// label the Money tab's discount-code table and to attribute earnings.
// Returns { purpose: "creator"|"conversion"|"loyalty"|"other", creatorId: string|null }.
export function codePurpose(code) {
  const CODE = String(code || "").trim().toUpperCase();
  if (CODE_TO_CREATOR[CODE]) return { purpose: "creator", creatorId: CODE_TO_CREATOR[CODE] };
  if (SYSTEM_CODE_PURPOSE[CODE]) return { purpose: SYSTEM_CODE_PURPOSE[CODE], creatorId: null };
  return { purpose: "other", creatorId: null };
}
