// Stripe money + payout computations, shared by /api/money (admin Money tab) and
// /api/creator/payout-view (read-only creator earnings).
//
// CORE FIGURE — "net settled" = balance_transaction.net: the money that actually
// landed in the Stripe account, AFTER Stripe fees, FX-converted into the account's
// settlement currency, with refunds deducted. We never recompute from price×percent
// or trust times_redeemed for dollars.
//
// Every coupon in this app is Stripe duration "once" (first month only), so each
// redemption's discounted invoice IS its first-month invoice — the creator earns
// exactly that invoice's net-settled amount, summed across their redemptions.
//
// API VERSION PIN (money-critical): on Stripe "Basil" (2025-03-31)+ the invoice.charge
// field was REMOVED (moved under invoice.payments[].payment.charge). The repo pins no
// version, so the account default could be either shape. We pin a PRE-Basil version on
// every money call so invoice.charge (and its expandable balance_transaction) is always
// present; a defensive fallback reads the Basil location too, just in case.
//
// Everything here is best-effort: each section is wrapped so a Stripe outage degrades
// a field to null (UI shows "—") and never throws to the caller / never 500s.

import {
  listInvoicesPage,
  listSubscriptionsPage,
  listRefundsPage,
  listPromotionCodesPage,
} from "./stripe.js";
import { codePurpose } from "./creators.js";

export const STRIPE_API_VERSION = "2024-06-20"; // pre-Basil: invoice.charge present

const PAGE_CAP = 40;                              // max list pages walked (×100 rows);
                                                  // hitting it -> available=false (never show a partial sum as final)
const MS_DAY = 86400000;
const MS_MONTH = 30.44 * MS_DAY;

// Customers excluded from ALL dashboard stats (test purchases / internal accounts), so
// they never touch MRR, active subs, revenue, churn, refunds, etc. Add Stripe customer
// ids here (find one in the Stripe dashboard or via the customer's email).
//   cus_UimtMOhR7SG8QQ = marko.miha2006@gmail.com — owner's payment test.
const IGNORED_CUSTOMERS = new Set(["cus_UimtMOhR7SG8QQ"]);

// Normalize a Stripe customer reference (id string or expanded object) to its id.
function customerId(c) {
  return typeof c === "string" ? c : (c && c.id) || "";
}
function isIgnoredCustomer(c) {
  return IGNORED_CUSTOMERS.has(customerId(c));
}

// UTC midnight of the 1st of the current month.
function monthStartMs(now) {
  const d = new Date(now);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1);
}

// "YYYY-MM" for the current UTC month.
function monthLabel(now) {
  return new Date(now).toISOString().slice(0, 7);
}

// Resolve the charge object off an invoice across Stripe API versions:
// pre-Basil -> invoice.charge (expanded object); Basil -> invoice.payments[].payment.charge.
function invoiceCharge(inv) {
  if (inv && inv.charge && typeof inv.charge === "object") return inv.charge;
  const pays = inv && inv.payments && inv.payments.data;
  if (Array.isArray(pays)) {
    for (const p of pays) {
      const ch = p && p.payment && p.payment.charge;
      if (ch && typeof ch === "object") return ch;
    }
  }
  return null;
}

// Net-settled amount (account currency, after fees + FX, refunds deducted) for a
// charge, read from its balance_transaction. Returns { net, gross, fee, currency }.
function chargeNet(charge) {
  const bt = charge && typeof charge.balance_transaction === "object" ? charge.balance_transaction : null;
  if (!bt) return { net: 0, gross: 0, fee: 0, currency: null };
  let net = typeof bt.net === "number" ? bt.net : 0;
  const gross = typeof bt.amount === "number" ? bt.amount : 0;
  const fee = typeof bt.fee === "number" ? bt.fee : 0;
  // Refunds: a fully refunded charge nets to 0; a partial refund scales the net down
  // by the refunded fraction (balance-transaction-exact refund FX is a later refinement).
  if (charge.refunded) net = 0;
  else if (charge.amount_refunded && charge.amount > 0) {
    net = Math.round(net * (1 - charge.amount_refunded / charge.amount));
  }
  return { net, gross, fee, currency: bt.currency || null };
}

// Pull the promotion_code id (pc_...) off an invoice's discount. Matching on the
// promotion_code id (NOT coupon id) is required: several creator codes can share one
// coupon, and only the promotion code distinguishes who gets credited.
// If an invoice ever carries MORE THAN ONE distinct promotion code (discount stacking,
// not possible in the current single-code model), we return null rather than silently
// crediting the whole invoice to a guessed code.
function invoicePromoId(inv) {
  const fromDiscount = (d) => {
    if (!d || typeof d !== "object") return null;
    const pc = d.promotion_code;
    if (!pc) return null;
    return typeof pc === "string" ? pc : pc.id || null;
  };
  const ids = new Set();
  for (const t of (inv && inv.total_discount_amounts) || []) {
    const id = fromDiscount(t && t.discount);
    if (id) ids.add(id);
  }
  for (const d of (inv && inv.discounts) || []) {
    const id = fromDiscount(d);
    if (id) ids.add(id);
  }
  return ids.size === 1 ? [...ids][0] : null;
}

// ---- Promotion-code catalog -------------------------------------------------
// Every promotion code in the account, tagged by purpose. byId: pc_ id -> meta.
export async function loadPromoCodes(env) {
  const byId = new Map();
  let available = true;
  try {
    let after = null, pages = 0;
    while (pages < PAGE_CAP) {
      // active: true -> archived/deactivated promo codes never appear on the dashboard.
      const params = { limit: 100, active: true, expand: ["data.coupon"] };
      if (after) params.starting_after = after;
      const res = await listPromotionCodesPage(env, params, STRIPE_API_VERSION);
      const data = (res && res.data) || [];
      for (const pc of data) {
        const code = String(pc.code || "").toUpperCase();
        const coupon = pc.coupon || (pc.promotion && pc.promotion.coupon) || {};
        const { purpose, creatorId, variant } = codePurpose(code);
        byId.set(pc.id, {
          id: pc.id,
          code,
          couponId: coupon.id || null,
          percentOff: coupon.percent_off != null ? coupon.percent_off : null,
          amountOffCents: coupon.amount_off != null ? coupon.amount_off : null,
          duration: coupon.duration || null,
          timesRedeemed: pc.times_redeemed || 0,
          active: !!pc.active,
          purpose,
          creatorId,
          variant, // flash A/B arm (1/2/3), else null
        });
      }
      if (!res || !res.has_more || !data.length) break;
      after = data[data.length - 1].id;
      pages++;
    }
  } catch {
    available = false;
  }
  return { byId, available };
}

// ---- Invoice scan -> per-code net-settled earnings --------------------------
// Walks paid invoices in-window, attributes each discounted invoice to its promotion
// code, and sums net-settled. Returns:
//   byPc:  Map(pcId -> { grossCents, netCents, redemptions:[{at,amountCents,status}] })
//   month: { grossCents, netCents, feesCents } for invoices created this UTC month
//   currency, available
export async function scanInvoices(env, now) {
  const byPc = new Map();
  const month = { grossCents: 0, netCents: 0, feesCents: 0 };
  const mStart = monthStartMs(now);
  let currency = null;
  let available = true;
  try {
    // Scan ALL paid invoices (bounded by PAGE_CAP) so earnings are complete regardless of
    // age — a creator earns month-1 whenever that happened. The month totals are filtered
    // in-loop by created date. No created-window so nothing is silently dropped by age.
    let after = null, pages = 0;
    while (pages < PAGE_CAP) {
      const params = {
        status: "paid",
        limit: 100,
        expand: [
          "data.charge.balance_transaction",
          "data.total_discount_amounts.discount",
          "data.discounts",
        ],
      };
      if (after) params.starting_after = after;
      const res = await listInvoicesPage(env, params, STRIPE_API_VERSION);
      const data = (res && res.data) || [];
      for (const inv of data) {
        if (isIgnoredCustomer(inv.customer)) continue; // test/internal customer -> ignore
        const charge = invoiceCharge(inv);
        const { net, gross, fee, currency: cur } = chargeNet(charge);
        if (cur && !currency) currency = cur;

        const createdMs = (inv.created || 0) * 1000;
        if (createdMs >= mStart && charge) {
          month.grossCents += gross;
          month.netCents += net;
          month.feesCents += fee;
        }

        const pcId = invoicePromoId(inv);
        if (pcId) {
          let agg = byPc.get(pcId);
          if (!agg) {
            agg = { grossCents: 0, netCents: 0, redemptions: [] };
            byPc.set(pcId, agg);
          }
          agg.grossCents += gross;
          agg.netCents += net;
          agg.redemptions.push({
            at: createdMs,
            amountCents: net,
            status: charge && charge.refunded ? "refunded" : "paid",
          });
        }
      }
      if (!res || !res.has_more || !data.length) break;
      after = data[data.length - 1].id;
      pages++;
    }
    // Exited because we hit the page cap with more still pending -> the sums are partial;
    // degrade to "unavailable" so the UI shows "—" instead of a truncated total as final.
    if (pages >= PAGE_CAP) available = false;
  } catch {
    available = false;
  }
  return { byPc, month, currency, available };
}

// ---- Subscription snapshot --------------------------------------------------
// active/byStatus/MRR/new/churned this month + average lifetime -> LTV.

// A subscription's normalized MONTHLY recurring amount (settlement-of-price currency
// minor units), read from its items inline — no extra Stripe call, supports any interval.
function subMonthlyCents(s) {
  const items = (s.items && s.items.data) || [];
  let cents = 0;
  for (const it of items) {
    const price = it.price || it.plan || {};
    const unit = price.unit_amount != null ? price.unit_amount : price.amount != null ? price.amount : 0;
    const qty = it.quantity || s.quantity || 1;
    const rec = price.recurring || price; // legacy `plan` carries interval at top level
    const interval = rec.interval || "month";
    const ic = rec.interval_count || 1;
    let monthly = unit * qty;
    if (interval === "year") monthly = monthly / (12 * ic);
    else if (interval === "week") monthly = (monthly * 52) / (12 * ic);
    else if (interval === "day") monthly = (monthly * 365) / (12 * ic);
    else monthly = monthly / ic; // month
    cents += monthly;
  }
  if (!items.length && s.plan && s.plan.amount != null) cents = s.plan.amount * (s.quantity || 1);
  return Math.round(cents);
}

// True if the subscription carries an ONGOING (never-ending) discount — a forever/
// repeating comp such as a 100%-off grant. Version-robust: reads BOTH the modern
// `discounts` array AND the legacy singular `discount` field (which is what the pinned
// pre-Basil API version returns), each of which may be an inlined Discount object. A
// one-time ("once") code's discount has its `end` timestamp set, so it is NOT ongoing.
function hasOngoingDiscount(s) {
  const list = [];
  if (Array.isArray(s.discounts)) for (const d of s.discounts) list.push(d);
  if (s.discount) list.push(s.discount);
  for (const d of list) {
    if (d && typeof d === "object" && d.end == null) return true;
  }
  return false;
}

// A "real" active subscriber: status active and NOT a free comp (ongoing 100%-off grant
// to a creator/youtuber). This is what the "Active subscribers" card shows — real subs,
// not freebies. (Ignored test customers are filtered out before this is ever called.)
function isRealActive(s) {
  return s.status === "active" && !hasOngoingDiscount(s);
}

// Does a subscription contribute to MRR? = a real active sub that is NOT pending
// cancellation (cancel_at / cancel_at_period_end / canceled_at set -> €0 going forward).
// NOTE: an ongoing PARTIAL discount (e.g. 50%-off forever) is treated as a comp (€0) here
// — fine for this app where forever-discounts are 100%-off grants.
function mrrCounts(s) {
  if (!isRealActive(s)) return false;
  if (s.cancel_at_period_end || s.cancel_at || s.canceled_at) return false;
  return true;
}

export async function subsSnapshot(env, now) {
  const out = {
    active: null,
    byStatus: {},
    mrrCents: null,
    mrrSubs: null,
    priceCurrency: null,
    newThisMonth: null,
    churnedThisMonth: null,
    avgLifetimeMonths: null,
    ltvCents: null,
    ltvEstimated: false,
    available: true,
  };
  const mStart = monthStartMs(now);

  try {
    let after = null, pages = 0;
    // Count DISTINCT REAL customers — free 100%-off comps (youtuber grants) and ignored
    // test accounts excluded — so two subs from one person, or a freebie, never inflate it.
    const realActive = new Set(); // real customers with an active sub right now
    const payingCust = new Set(); // real customers counted in MRR
    const newReal = new Set();    // real customers whose sub STARTED this month
    const endedReal = new Set();  // real customers whose sub ENDED this month
    let mrr = 0, lifetimeSum = 0, lifetimeN = 0, currency = null;
    const byStatus = {};
    while (pages < PAGE_CAP) {
      // expand discounts: in the LIST they come back as bare discount IDs (strings) unless
      // expanded, so without this hasOngoingDiscount() can't read `end` and 100%-off comps
      // leak in. No version pin here (unlike the invoice scan) — the account default returns
      // the modern `discounts` array; hasOngoingDiscount() also reads legacy `discount`.
      const params = { status: "all", limit: 100, expand: ["data.discounts"] };
      if (after) params.starting_after = after;
      const res = await listSubscriptionsPage(env, params);
      const data = (res && res.data) || [];
      for (const s of data) {
        if (isIgnoredCustomer(s.customer)) continue; // test/internal customer -> ignore entirely
        byStatus[s.status] = (byStatus[s.status] || 0) + 1;
        if (!currency && s.currency) currency = s.currency;
        const cust = customerId(s.customer);
        const comp = hasOngoingDiscount(s); // free 100%-off grant -> not a "real" subscriber
        if (s.status === "active" && !comp) realActive.add(cust);
        if (!comp) {
          const start = (s.start_date || s.created || 0) * 1000;
          if (start && start >= mStart) newReal.add(cust);
          // ENDED (ended_at), not merely scheduled to cancel.
          const ended = (s.ended_at || 0) * 1000;
          if (ended && ended >= mStart) endedReal.add(cust);
          if (ended && start && ended > start) { lifetimeSum += ended - start; lifetimeN++; }
        }
        if (mrrCounts(s)) { mrr += subMonthlyCents(s); payingCust.add(cust); }
      }
      if (!res || !res.has_more || !data.length) break;
      after = data[data.length - 1].id;
      pages++;
    }
    // Truncated at the page cap -> partial; degrade to unavailable rather than show a partial.
    if (pages >= PAGE_CAP) {
      out.available = false;
      return out;
    }
    // Churn = real customers who ended this month AND have no active sub now (a true loss,
    // not a same-month re-subscribe).
    let churned = 0;
    for (const c of endedReal) if (!realActive.has(c)) churned++;

    out.active = realActive.size;
    out.byStatus = byStatus;
    out.priceCurrency = currency;
    out.newThisMonth = newReal.size;
    out.churnedThisMonth = churned;
    out.mrrCents = mrr;
    out.mrrSubs = payingCust.size;

    // Average lifetime: prefer observed (churned) lifetimes; fall back to 1/churn-rate when
    // too few REAL subs have actually churned (flagged so the UI can show "estimate").
    if (lifetimeN >= 3) {
      out.avgLifetimeMonths = Math.round((lifetimeSum / lifetimeN / MS_MONTH) * 10) / 10;
    } else if (realActive.size > 0 && churned > 0) {
      out.avgLifetimeMonths = Math.round((realActive.size / churned) * 10) / 10;
      out.ltvEstimated = true;
    }
    if (out.avgLifetimeMonths != null && payingCust.size > 0) {
      out.ltvCents = Math.round(out.avgLifetimeMonths * (mrr / payingCust.size)); // avg rev/paying sub
    }
  } catch {
    out.available = false;
  }
  return out;
}

// ---- Refunds this month -----------------------------------------------------
export async function refundsThisMonth(env, now) {
  const sinceSec = Math.floor(monthStartMs(now) / 1000);
  let cents = 0, count = 0, available = true;
  try {
    let after = null, pages = 0;
    while (pages < PAGE_CAP) {
      const params = { limit: 100, created: { gte: sinceSec }, expand: ["data.balance_transaction", "data.charge"] };
      if (after) params.starting_after = after;
      const res = await listRefundsPage(env, params, STRIPE_API_VERSION);
      const data = (res && res.data) || [];
      for (const r of data) {
        if (r.charge && isIgnoredCustomer(r.charge.customer)) continue; // test/internal refund -> ignore
        const bt = r.balance_transaction;
        if (bt && typeof bt === "object" && typeof bt.net === "number") cents += Math.abs(bt.net);
        else cents += r.amount || 0;
        count++;
      }
      if (!res || !res.has_more || !data.length) break;
      after = data[data.length - 1].id;
      pages++;
    }
  } catch {
    available = false;
  }
  return { cents, count, available };
}

// ---- Per-creator paid-out + bonuses (D1 payouts ledger) ---------------------
// Splits the ledger by kind: 'payout' rows are money disbursed (paid); 'bonus' rows are
// credits owed on top of Stripe earnings. Owed = earned + bonus - paid.
async function paidOutByCreator(env) {
  const map = {};
  try {
    const rows = await env.STATS.prepare(
      `SELECT creator_id,
         COALESCE(SUM(CASE WHEN kind = 'bonus' THEN 0 ELSE amount_cents END), 0) AS cents,
         COALESCE(SUM(CASE WHEN kind = 'bonus' THEN 0 ELSE subscribers  END), 0) AS subs,
         COALESCE(SUM(CASE WHEN kind = 'bonus' THEN amount_cents ELSE 0  END), 0) AS bonus_cents
       FROM payouts GROUP BY creator_id`
    ).all();
    for (const r of (rows && rows.results) || []) {
      map[r.creator_id] = { cents: r.cents || 0, subs: r.subs || 0, bonusCents: r.bonus_cents || 0 };
    }
  } catch {
    /* ledger table absent (or pre-migration) -> nothing paid out / no bonuses yet */
  }
  return map;
}

// ---- Creator cash actually paid out this month (D1 payouts ledger) ----------
// The CASH-BASIS creator-cost line for the Finances P&L: the sum of disbursements
// (kind='payout' — bonuses are credits still OWED, so excluded) whose ledger row was
// recorded this UTC month. This is what hits the P&L the month you actually pay a
// creator, regardless of when the underlying subscriptions were earned. NULL kind
// (rows predating migration 0005) counts as a payout, matching paidOutByCreator.
async function creatorPaidThisMonth(env, now) {
  const mStart = monthStartMs(now);
  let cents = 0;
  let available = true;
  try {
    const row = await env.STATS.prepare(
      `SELECT COALESCE(SUM(CASE WHEN kind = 'bonus' THEN 0 ELSE amount_cents END), 0) AS cents
         FROM payouts WHERE created_at >= ?1`
    )
      .bind(mStart)
      .first();
    cents = (row && row.cents) || 0;
  } catch {
    available = false; // ledger table absent / pre-migration -> unknown (P&L treats as 0)
  }
  return { cents, available };
}

// ---- Admin Money snapshot (GET /api/money) ----------------------------------
export async function buildMoneySnapshot(env) {
  const now = Date.now();
  const [codes, scan, subs, refunds, paid, paidMonth] = await Promise.all([
    loadPromoCodes(env),
    scanInvoices(env, now),
    subsSnapshot(env, now),
    refundsThisMonth(env, now),
    paidOutByCreator(env),
    creatorPaidThisMonth(env, now),
  ]);

  const currency = scan.currency || subs.priceCurrency || null;

  // Build base rows, then attribute each creator's paid-out (a per-CREATOR figure) to
  // their HIGHEST-earning code, so a multi-code creator's per-row Net is never spuriously
  // negative and column sums stay correct.
  const base = [];
  for (const pc of codes.byId.values()) {
    const agg = scan.byPc.get(pc.id) || { grossCents: 0, netCents: 0 };
    const disc =
      pc.percentOff != null
        ? `${pc.percentOff}% off`
        : pc.amountOffCents != null
        ? `${(pc.amountOffCents / 100).toFixed(2)} off`
        : "—";
    base.push({ pc, agg, disc });
  }
  const paidTarget = {}; // creatorId -> the pc.id that carries the paid-out figure
  const byCreator = {};
  for (const b of base) {
    if (b.pc.purpose === "creator" && b.pc.creatorId) {
      (byCreator[b.pc.creatorId] = byCreator[b.pc.creatorId] || []).push(b);
    }
  }
  for (const cid of Object.keys(byCreator)) {
    let best = byCreator[cid][0];
    for (const b of byCreator[cid]) if ((b.agg.netCents || 0) > (best.agg.netCents || 0)) best = b;
    paidTarget[cid] = best.pc.id;
  }

  const codeRows = base.map(({ pc, agg, disc }) => {
    const isCreator = pc.purpose === "creator" && pc.creatorId;
    // paid-out and bonuses are per-CREATOR figures; attribute both to the creator's
    // highest-earning code (paidTarget) so per-row Net never goes spuriously negative
    // and the column sums stay correct across a multi-code creator.
    const carriesCreatorTotals = isCreator && paidTarget[pc.creatorId] === pc.id;
    const paidToCreatorCents = isCreator ? (carriesCreatorTotals ? (paid[pc.creatorId] || {}).cents || 0 : 0) : null;
    const bonusToCreatorCents = isCreator ? (carriesCreatorTotals ? (paid[pc.creatorId] || {}).bonusCents || 0 : 0) : null;
    return {
      code: pc.code,
      promotionCodeId: pc.id,
      couponId: pc.couponId,
      purpose: pc.purpose,
      creatorId: pc.creatorId,
      variant: pc.variant, // flash A/B arm (1/2/3), else null
      discountLabel: pc.duration === "once" ? disc + " · 1st mo" : disc,
      percentOff: pc.percentOff,
      amountOffCents: pc.amountOffCents,
      active: pc.active,
      uses: pc.timesRedeemed,
      grossCents: scan.available ? agg.grossCents : null,
      netSettledCents: scan.available ? agg.netCents : null,
      paidToCreatorCents,
      bonusToCreatorCents,
      // Owed = still to pay the creator (earned + bonuses − paid). Only meaningful for
      // creator codes; null for conversion/loyalty/other codes (no creator to pay).
      owedCents: isCreator && scan.available
        ? Math.max(0, agg.netCents + (bonusToCreatorCents || 0) - (paidToCreatorCents || 0))
        : null,
    };
  });
  // Highest earners first, then by uses.
  codeRows.sort((a, b) => (b.netSettledCents || 0) - (a.netSettledCents || 0) || b.uses - a.uses);

  // Creator earnings attributable to THIS month (their first-month commission on subs that
  // redeemed a creator code this month) — the P&L's creator-cost line.
  const mStart = monthStartMs(now);
  let creatorEarnedMonth = 0;
  if (scan.available) {
    for (const pc of codes.byId.values()) {
      if (pc.purpose !== "creator") continue;
      const agg = scan.byPc.get(pc.id);
      if (!agg) continue;
      for (const r of agg.redemptions) if (r.at >= mStart && r.status !== "refunded") creatorEarnedMonth += r.amountCents;
    }
  }

  return {
    currency,
    subs: {
      active: subs.active,
      byStatus: subs.byStatus,
      mrrCents: subs.mrrCents,
      mrrSubs: subs.mrrSubs,
      newThisMonth: subs.newThisMonth,
      churnedThisMonth: subs.churnedThisMonth,
      avgLifetimeMonths: subs.avgLifetimeMonths,
      ltvCents: subs.ltvCents,
      ltvEstimated: subs.ltvEstimated,
    },
    month: {
      label: monthLabel(now),
      startedAt: mStart,
      grossCents: scan.available ? scan.month.grossCents : null,
      netSettledCents: scan.available ? scan.month.netCents : null,
      feesCents: scan.available ? scan.month.feesCents : null,
      refundsCents: refunds.available ? refunds.cents : null,
      refundsCount: refunds.available ? refunds.count : null,
      // Accrued (what creators EARNED this month) vs. cash (what you actually PAID OUT
      // this month). The Finances P&L uses the cash figure; earned is kept for context.
      creatorEarnedCents: scan.available ? creatorEarnedMonth : null,
      creatorPaidCents: paidMonth.available ? paidMonth.cents : null,
    },
    codes: codeRows,
    codesAvailable: scan.available && codes.available,
    subsAvailable: subs.available,
    at: now,
  };
}

// ---- Read-only creator earnings (POST /api/creator/payout-view) -------------
// earned (from Stripe) + redemptions list with NO PII. paidOut/pending are layered
// on by the endpoint from the D1 ledger.
export async function buildCreatorEarnings(env, creator) {
  const now = Date.now();
  const wanted = new Set(creator.codes.map((c) => c.toUpperCase()));

  const codes = await loadPromoCodes(env);
  const myPcIds = new Map(); // pcId -> code
  for (const pc of codes.byId.values()) {
    if (wanted.has(pc.code)) myPcIds.set(pc.id, pc.code);
  }

  const scan = await scanInvoices(env, now);
  // subs, money, and the redemptions list must ALL describe the SAME scanned set, or the
  // creator's pending subs and pending dollars disagree (mis-pay risk). So earnedSubs is
  // the count of attributed PAID redemptions — never the lifetime times_redeemed counter.
  const ok = scan.available && codes.available;
  let earnedMoneyCents = 0;
  let earnedSubs = 0;
  const redemptions = [];
  if (ok) {
    for (const [pcId, code] of myPcIds) {
      const agg = scan.byPc.get(pcId);
      if (!agg) continue;
      earnedMoneyCents += agg.netCents;
      for (const r of agg.redemptions) {
        if (r.status !== "refunded") earnedSubs++; // owed only for non-refunded redemptions
        redemptions.push({ at: r.at, code, amountCents: r.amountCents, status: r.status });
      }
    }
    redemptions.sort((a, b) => b.at - a.at);
  }

  return {
    currency: scan.currency,
    earnedSubs: ok ? earnedSubs : null,
    earnedMoneyCents: ok ? earnedMoneyCents : null,
    redemptions,
    available: ok,
  };
}
