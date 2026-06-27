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
};

// Look up a creator by slug (case-insensitive). Returns { id, name, codes } or null.
export function getCreator(id) {
  const key = String(id || "").trim().toLowerCase();
  const c = CREATORS[key];
  return c ? { id: key, name: c.name, codes: c.codes.slice() } : null;
}
