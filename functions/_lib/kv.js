// KV access layer over the SUBS namespace.
//
//   user:{googleSub}  -> customerId (string)
//   sub:{customerId}  -> { status, googleId, checkedAt }
//
// Active subscription statuses for access purposes.

export const ACTIVE_STATUSES = ["active", "trialing", "past_due"];

export function isActiveStatus(status) {
  return ACTIVE_STATUSES.includes(status);
}

const userKey = (googleSub) => `user:${googleSub}`;
const subKey = (customerId) => `sub:${customerId}`;

export async function linkUser(env, googleSub, customerId) {
  if (!googleSub || !customerId) return;
  await env.SUBS.put(userKey(googleSub), customerId);
}

export async function getCustomerId(env, googleSub) {
  if (!googleSub) return null;
  return (await env.SUBS.get(userKey(googleSub))) || null;
}

export async function setSubStatus(env, customerId, { status, googleId }) {
  if (!customerId) return;
  const record = { status, googleId: googleId || null, checkedAt: Date.now() };
  await env.SUBS.put(subKey(customerId), JSON.stringify(record));
}

export async function getSubStatus(env, customerId) {
  if (!customerId) return null;
  const raw = await env.SUBS.get(subKey(customerId));
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}
