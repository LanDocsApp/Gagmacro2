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
  // LION is what viewers type (from his old videos); it now maps to the WHITELION Stripe
  // promotion code at checkout (see CHECKOUT_CODE_ALIAS). Both are listed so earnings on
  // either code roll up to White Lion's one dashboard.
  lion:  { name: "White Lion", codes: ["LION", "WHITELION"] },
  vexy:  { name: "VexyChaos",  codes: ["VEXY"] },
  poptart: { name: "PopTart",  codes: ["POPTART"] },
};

// Entered creator code -> the Stripe promotion code to ACTUALLY apply at checkout, when the
// two differ. Viewers keep typing the familiar code, but a different (e.g. newer, better)
// Stripe promotion code is what discounts the invoice. Applied in functions/api/checkout.js
// for every entry point (macro + giveaway page), so the mapping is consistent everywhere.
// Keys + values UPPERCASE; codes not listed here apply themselves unchanged.
export const CHECKOUT_CODE_ALIAS = {
  LION: "WHITELION", // "LION" typed -> "WhiteLion" (65% off = $2) applied in Stripe
};

// Resolve an entered code to the promotion code to apply (uppercased). Falls back to the
// entered code when there's no alias.
export function checkoutCodeAlias(code) {
  const CODE = String(code || "").trim().toUpperCase();
  return CHECKOUT_CODE_ALIAS[CODE] || CODE;
}

// The checkout discount each creator code grants (its Stripe promotion code is a percent-off
// coupon). The giveaway page reads this to show "N% off with code LION" when a creator code is
// entered instead of the generic GIVEAWAY chip. Keep in sync with macro.ahk's PromoValid and
// with CREATORS above. Keys UPPERCASE; look up case-insensitively via creatorCodePercent().
export const CREATOR_CODE_PERCENT = {
  OVER:   10,
  ROOKIE: 10,
  JUKEM:  10,
  VEXY:   20,
  // LION now yields the WhiteLion supporter deal (65% off = $2, applied as WHITELION), so
  // its displayed percent matches what a redemption actually gets. Both keys are 65.
  LION:      65,
  WHITELION: 65,
  // POPTART is a "supporter" code: instead of the usual green corner badge it triggers the
  // red flash-style popup in the macro (see macro.ahk SupporterInfo) offering Pro at 65% off
  // ($2 first month). Its Stripe promotion code must be a 65%-off, duration=once coupon so
  // the first-month charge is ~$2 (65% off the $5.93 US price), same coupon math as flash
  // variant 2. Keep this in sync with macro.ahk PromoValid.
  POPTART: 65,
};

// Creators whose subscribers earn a retention bonus: if a subscriber who used the creator's
// code is still subscribed `days` after they started (i.e. did not cancel inside the first
// week), the creator is credited `bonusCents` on top of their first-month earnings. This is
// materialized into the D1 payouts ledger as a 'bonus' row on demand (see
// functions/api/creator/payout.js), so it needs no cron. Keyed by creator slug.
export const RETENTION_BONUS = {
  poptart: { days: 7, bonusCents: 200 }, // retained past 1 week -> +$2 (doubles PopTart's ~$2 take)
};

// Look up a creator by slug (case-insensitive). Returns { id, name, codes } or null.
export function getCreator(id) {
  const key = String(id || "").trim().toLowerCase();
  const c = CREATORS[key];
  return c ? { id: key, name: c.name, codes: c.codes.slice() } : null;
}

// The discount percent for a creator code (0 if it isn't a known creator code). Case-insensitive.
export function creatorCodePercent(code) {
  const CODE = String(code || "").trim().toUpperCase();
  return CREATOR_CODE_PERCENT[CODE] || 0;
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

// ---- Flash-deal A/B price test --------------------------------------------
// A 24h-after-install "flash deal" that discounts the FIRST month of Pro. Every
// install is randomly assigned one of these variants; the macro shows a live
// countdown and auto-applies the matching Stripe promotion code at checkout (see
// functions/api/checkout.js). We run three price points side by side and read the
// winner (conversion % AND net revenue per install) off /stats.
//
// SETUP (do this once in the Stripe dashboard, then paste the real code strings
// below): for each variant create a Coupon with duration "once" and amount_off =
// (your monthly price − the target first-month price), then a Promotion code bound
// to it. Use OPAQUE code strings (NOT "FLASH1") so the price isn't guessable or
// shareable. The `variant` numbers (1/2/3) MUST match macro.ahk's OfferPercents, and
// the code STRINGS here MUST equal the promotion codes exactly (uppercased).
//
//   variant 1 -> 75% off 1st mo   variant 2 -> 65% off 1st mo   variant 3 -> 50% off 1st mo
//
// PERCENT-off (not amount-off) so the coupon is currency-agnostic — it applies to a US
// customer charged in USD AND an EU customer charged in EUR, with no "order doesn't
// qualify" currency mismatch. percentOff here is display-only; the real discount lives
// on the Stripe coupon (create each as a percent-off coupon, Duration: Once). UPPERCASE keys.
export const FLASH_CODES = {
  "GROW7X5": { variant: 1, percentOff: 75 }, // TODO: replace with real Stripe promotion code (75% off)
  "GROW4Q8": { variant: 2, percentOff: 65 }, // TODO: replace with real Stripe promotion code (65% off)
  "GROW9K2": { variant: 3, percentOff: 50 }, // TODO: replace with real Stripe promotion code (50% off)
};

// variant number (1/2/3) -> its UPPERCASE promotion-code string, or null if unknown.
export function flashCodeForVariant(variant) {
  const v = parseInt(variant, 10);
  if (!(v >= 1)) return null;
  for (const [code, meta] of Object.entries(FLASH_CODES)) {
    if (meta.variant === v) return code;
  }
  return null;
}

// Reverse index: uppercased creator code -> owning creator slug.
const CODE_TO_CREATOR = (() => {
  const m = {};
  for (const id of Object.keys(CREATORS))
    for (const code of CREATORS[id].codes) m[code.toUpperCase()] = id;
  return m;
})();

// Normalize + validate a creator code the user entered in the macro. Returns the
// UPPERCASE code string if it belongs to a known creator, else "". The code string
// IS its own Stripe promotion code, so /api/checkout can look it up directly and
// auto-apply it (see checkout.js), the same way the flash deal auto-applies its code.
export function creatorCode(code) {
  const CODE = String(code || "").trim().toUpperCase();
  return CODE_TO_CREATOR[CODE] ? CODE : "";
}

// Tag a promo code string with its purpose + owning creator (if any). Used to
// label the Money tab's discount-code table and to attribute earnings.
// Returns { purpose: "creator"|"conversion"|"loyalty"|"flash"|"other",
//           creatorId: string|null, variant: number|null }.
// `variant` is set only for flash-deal codes (their A/B price arm 1/2/3).
export function codePurpose(code) {
  const CODE = String(code || "").trim().toUpperCase();
  if (CODE_TO_CREATOR[CODE]) return { purpose: "creator", creatorId: CODE_TO_CREATOR[CODE], variant: null };
  if (FLASH_CODES[CODE]) return { purpose: "flash", creatorId: null, variant: FLASH_CODES[CODE].variant };
  if (SYSTEM_CODE_PURPOSE[CODE]) return { purpose: SYSTEM_CODE_PURPOSE[CODE], creatorId: null, variant: null };
  return { purpose: "other", creatorId: null, variant: null };
}
