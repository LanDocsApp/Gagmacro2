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
  getPrice,
} from "./stripe.js";
import { codePurpose } from "./creators.js";

export const STRIPE_API_VERSION = "2024-06-20"; // pre-Basil: invoice.charge present

const PAGE_CAP = 40;                              // max list pages walked (×100 rows);
                                                  // hitting it -> available=false (never show a partial sum as final)
const MS_DAY = 86400000;
const MS_MONTH = 30.44 * MS_DAY;

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
      const params = { limit: 100, expand: ["data.coupon"] };
      if (after) params.starting_after = after;
      const res = await listPromotionCodesPage(env, params, STRIPE_API_VERSION);
      const data = (res && res.data) || [];
      for (const pc of data) {
        const code = String(pc.code || "").toUpperCase();
        const coupon = pc.coupon || (pc.promotion && pc.promotion.coupon) || {};
        const { purpose, creatorId } = codePurpose(code);
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
export async function subsSnapshot(env, now) {
  const out = {
    active: null,
    byStatus: {},
    mrrCents: null,
    priceCurrency: null,
    newThisMonth: null,
    churnedThisMonth: null,
    avgLifetimeMonths: null,
    ltvCents: null,
    ltvEstimated: false,
    available: true,
  };
  const mStart = monthStartMs(now);
  const ACTIVE = new Set(["active", "trialing", "past_due"]);

  let unitAmount = null;
  try {
    if (env.STRIPE_PRICE_ID) {
      const price = await getPrice(env, env.STRIPE_PRICE_ID, STRIPE_API_VERSION);
      unitAmount = price && price.unit_amount != null ? price.unit_amount : null;
      out.priceCurrency = price && price.currency ? price.currency : null;
    }
  } catch {
    /* price unavailable -> MRR stays null */
  }

  try {
    let after = null, pages = 0;
    let active = 0, newM = 0, churnedM = 0, lifetimeSum = 0, lifetimeN = 0;
    const byStatus = {};
    while (pages < PAGE_CAP) {
      const params = { status: "all", limit: 100 };
      if (after) params.starting_after = after;
      const res = await listSubscriptionsPage(env, params, STRIPE_API_VERSION);
      const data = (res && res.data) || [];
      for (const s of data) {
        byStatus[s.status] = (byStatus[s.status] || 0) + 1;
        if (ACTIVE.has(s.status)) active++;
        const start = (s.start_date || s.created || 0) * 1000;
        if (start && start >= mStart) newM++;
        const ended = (s.canceled_at || s.ended_at || 0) * 1000;
        if (ended && ended >= mStart) churnedM++;
        if (ended && start && ended > start) {
          lifetimeSum += ended - start;
          lifetimeN++;
        }
      }
      if (!res || !res.has_more || !data.length) break;
      after = data[data.length - 1].id;
      pages++;
    }
    // Truncated at the page cap -> counts/MRR/churn would be partial; leave them null and
    // flag unavailable rather than presenting an incomplete subscriber base as authoritative.
    if (pages >= PAGE_CAP) {
      out.available = false;
      return out;
    }
    out.active = active;
    out.byStatus = byStatus;
    out.newThisMonth = newM;
    out.churnedThisMonth = churnedM;
    out.mrrCents = unitAmount != null ? active * unitAmount : null;

    // Average lifetime: prefer observed (churned) lifetimes; fall back to 1/churn-rate
    // when too few have actually churned (flagged so the UI can show "estimate").
    if (lifetimeN >= 3) {
      out.avgLifetimeMonths = Math.round((lifetimeSum / lifetimeN / MS_MONTH) * 10) / 10;
    } else if (active > 0 && churnedM > 0) {
      out.avgLifetimeMonths = Math.round((active / churnedM) * 10) / 10;
      out.ltvEstimated = true;
    }
    if (out.avgLifetimeMonths != null && unitAmount != null) {
      out.ltvCents = Math.round(out.avgLifetimeMonths * unitAmount);
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
      const params = { limit: 100, created: { gte: sinceSec }, expand: ["data.balance_transaction"] };
      if (after) params.starting_after = after;
      const res = await listRefundsPage(env, params, STRIPE_API_VERSION);
      const data = (res && res.data) || [];
      for (const r of data) {
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

// ---- Per-creator paid-out (D1 disbursement ledger) --------------------------
async function paidOutByCreator(env) {
  const map = {};
  try {
    const rows = await env.STATS.prepare(
      `SELECT creator_id, COALESCE(SUM(amount_cents),0) AS cents, COALESCE(SUM(subscribers),0) AS subs
       FROM payouts GROUP BY creator_id`
    ).all();
    for (const r of (rows && rows.results) || []) {
      map[r.creator_id] = { cents: r.cents || 0, subs: r.subs || 0 };
    }
  } catch {
    /* ledger table absent -> nothing paid out yet */
  }
  return map;
}

// ---- Admin Money snapshot (GET /api/money) ----------------------------------
export async function buildMoneySnapshot(env) {
  const now = Date.now();
  const [codes, scan, subs, refunds, paid] = await Promise.all([
    loadPromoCodes(env),
    scanInvoices(env, now),
    subsSnapshot(env, now),
    refundsThisMonth(env, now),
    paidOutByCreator(env),
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
    const paidToCreatorCents = isCreator
      ? paidTarget[pc.creatorId] === pc.id
        ? (paid[pc.creatorId] || {}).cents || 0
        : 0
      : null;
    return {
      code: pc.code,
      promotionCodeId: pc.id,
      couponId: pc.couponId,
      purpose: pc.purpose,
      creatorId: pc.creatorId,
      discountLabel: pc.duration === "once" ? disc + " · 1st mo" : disc,
      percentOff: pc.percentOff,
      amountOffCents: pc.amountOffCents,
      active: pc.active,
      uses: pc.timesRedeemed,
      grossCents: scan.available ? agg.grossCents : null,
      netSettledCents: scan.available ? agg.netCents : null,
      paidToCreatorCents,
      netCents: scan.available ? agg.netCents - (paidToCreatorCents || 0) : null,
    };
  });
  // Highest earners first, then by uses.
  codeRows.sort((a, b) => (b.netSettledCents || 0) - (a.netSettledCents || 0) || b.uses - a.uses);

  return {
    currency,
    subs: {
      active: subs.active,
      byStatus: subs.byStatus,
      mrrCents: subs.mrrCents,
      newThisMonth: subs.newThisMonth,
      churnedThisMonth: subs.churnedThisMonth,
      avgLifetimeMonths: subs.avgLifetimeMonths,
      ltvCents: subs.ltvCents,
      ltvEstimated: subs.ltvEstimated,
    },
    month: {
      label: monthLabel(now),
      startedAt: monthStartMs(now),
      grossCents: scan.available ? scan.month.grossCents : null,
      netSettledCents: scan.available ? scan.month.netCents : null,
      feesCents: scan.available ? scan.month.feesCents : null,
      refundsCents: refunds.available ? refunds.cents : null,
      refundsCount: refunds.available ? refunds.count : null,
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
