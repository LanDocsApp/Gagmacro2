// Web Crypto helpers — HMAC sign/verify for the session cookie and the
// desktop paste-code, plus Stripe webhook signature verification.
// No SDKs, no Node built-ins: just the platform's crypto.subtle + fetch.

const enc = new TextEncoder();
const dec = new TextDecoder();

// ---- base64url ----------------------------------------------------------

export function b64urlFromBytes(bytes) {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function b64urlFromString(str) {
  return b64urlFromBytes(enc.encode(str));
}

export function bytesFromB64url(s) {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function stringFromB64url(s) {
  return dec.decode(bytesFromB64url(s));
}

function toHex(bytes) {
  let h = "";
  for (let i = 0; i < bytes.length; i++) h += bytes[i].toString(16).padStart(2, "0");
  return h;
}

// Constant-time-ish string compare (avoids leaking length-prefix match timing).
function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// ---- HMAC-SHA256 --------------------------------------------------------

async function hmacKey(secret) {
  return crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
}

async function hmac(secret, data) {
  const key = await hmacKey(secret);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(data));
  return new Uint8Array(sig);
}

// ---- signed tokens (session + desktop paste-code) -----------------------
//
// Format: <payloadB64url>.<sigB64url>
// The signature covers `${context}.${payload}` so a session token can never
// be replayed as a desktop token (domain separation).

export async function signToken(secret, context, payloadObj) {
  const payload = b64urlFromString(JSON.stringify(payloadObj));
  const sig = b64urlFromBytes(await hmac(secret, context + "." + payload));
  return payload + "." + sig;
}

export async function verifyToken(secret, context, token) {
  if (!token || typeof token !== "string") return null;
  const dot = token.indexOf(".");
  if (dot < 0) return null;
  const payload = token.slice(0, dot);
  const sig = token.slice(dot + 1);
  if (!payload || !sig) return null;
  const expected = b64urlFromBytes(await hmac(secret, context + "." + payload));
  if (!timingSafeEqual(sig, expected)) return null;
  try {
    return JSON.parse(stringFromB64url(payload));
  } catch {
    return null;
  }
}

// Random opaque token (hex) — used for the OAuth CSRF state value.
export function randomToken(bytes = 16) {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return toHex(buf);
}

// ---- Stripe webhook signature ------------------------------------------
//
// Stripe-Signature: "t=<ts>,v1=<hex>,..."  signed over `${t}.${rawBody}`.

export async function verifyStripeWebhook(rawBody, sigHeader, secret, toleranceSec = 300) {
  if (!sigHeader) return false;
  let t = null;
  const v1 = [];
  for (const part of sigHeader.split(",")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    const k = part.slice(0, i).trim();
    const v = part.slice(i + 1).trim();
    if (k === "t") t = v;
    else if (k === "v1") v1.push(v);
  }
  if (!t || v1.length === 0) return false;

  // Replay-window check.
  const ts = Number(t);
  if (Number.isFinite(ts) && toleranceSec > 0) {
    if (Math.abs(Date.now() / 1000 - ts) > toleranceSec) return false;
  }

  const expected = toHex(await hmac(secret, `${t}.${rawBody}`));
  return v1.some((sig) => timingSafeEqual(sig, expected));
}
