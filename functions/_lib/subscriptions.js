// Subscription status resolution with self-heal from Stripe.
//
// KV is the fast path; when it's missing or stale we re-derive truth from
// Stripe (and write it back), so a wiped/cold KV or a missed webhook never
// locks a paying user out.

import {
  getCustomerId,
  getSubStatus,
  setSubStatus,
  linkUser,
  isActiveStatus,
  ACTIVE_STATUSES,
} from "./kv.js";
import { listSubscriptions, searchSubscriptionsByGoogleId } from "./stripe.js";

// Re-validate against Stripe if the cached record is older than this.
const FRESH_MS = 6 * 60 * 60 * 1000; // 6 hours

function customerOf(sub) {
  return typeof sub.customer === "string" ? sub.customer : sub.customer && sub.customer.id;
}

// Pick the "best" status from a list of subscriptions: prefer any active-ish
// one, otherwise fall back to the most recent entry, otherwise canceled.
function pickStatus(subs) {
  if (!subs || subs.length === 0) return "canceled";
  const active = subs.find((s) => ACTIVE_STATUSES.includes(s.status));
  return active ? active.status : subs[0].status;
}

async function refreshByCustomer(env, customerId, googleSub) {
  try {
    const list = await listSubscriptions(env, customerId);
    const status = pickStatus(list.data || []);
    await setSubStatus(env, customerId, { status, googleId: googleSub });
    return isActiveStatus(status);
  } catch {
    return null; // signal "couldn't reach Stripe" so callers can fall back to KV
  }
}

async function refreshByGoogleSub(env, googleSub) {
  try {
    const res = await searchSubscriptionsByGoogleId(env, googleSub);
    const subs = res.data || [];
    if (subs.length === 0) return false;
    const chosen = subs.find((s) => isActiveStatus(s.status)) || subs[0];
    const customerId = customerOf(chosen);
    if (!customerId) return false;
    await linkUser(env, googleSub, customerId);
    const status = pickStatus(subs.filter((s) => customerOf(s) === customerId));
    await setSubStatus(env, customerId, { status, googleId: googleSub });
    return isActiveStatus(status);
  } catch {
    return false;
  }
}

// True if the Google account currently has an access-granting subscription.
export async function resolveActive(env, googleSub) {
  if (!googleSub) return false;

  const customerId = await getCustomerId(env, googleSub);
  if (customerId) {
    const cached = await getSubStatus(env, customerId);
    if (cached && Date.now() - (cached.checkedAt || 0) < FRESH_MS) {
      return isActiveStatus(cached.status);
    }
    // Stale or missing -> refresh from Stripe, fall back to stale cache on error.
    const live = await refreshByCustomer(env, customerId, googleSub);
    if (live !== null) return live;
    return cached ? isActiveStatus(cached.status) : false;
  }

  // No customer link yet -> search Stripe by the google_id metadata.
  return refreshByGoogleSub(env, googleSub);
}
