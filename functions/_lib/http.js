// HTTP/cookie helpers + signed-session read/write.

import { verifyToken } from "./crypto.js";

// 30-day signed session.
export const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
export const SESSION_TTL_S = 30 * 24 * 60 * 60;
export const SESSION_COOKIE = "gag_session";
// Display-only cookie so the static sign-in page can greet the user. NOT used
// for auth — the signed HttpOnly session cookie is the source of truth.
export const DISPLAY_COOKIE = "gag_user";
export const STATE_COOKIE = "gag_oauth_state";

// Public origin. Computed from the request so nothing is hardcoded; override
// with PUBLIC_BASE_URL only if the app is served from a custom domain that
// differs from the request origin (e.g. behind a proxy).
export function baseUrl(request, env) {
  const b = (env.PUBLIC_BASE_URL && env.PUBLIC_BASE_URL.trim()) || new URL(request.url).origin;
  return b.replace(/\/+$/, "");
}

export function redirectUriFor(request, env) {
  return baseUrl(request, env) + "/api/auth/google/callback";
}

export function redirect(location, status = 302) {
  return new Response(null, { status, headers: { Location: location } });
}

export function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

export function html(body, status = 200) {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}

export function cookie(name, value, opts = {}) {
  const p = [`${name}=${value}`, `Path=${opts.path || "/"}`];
  if (opts.maxAge !== undefined) p.push(`Max-Age=${opts.maxAge}`);
  if (opts.httpOnly) p.push("HttpOnly");
  p.push("Secure");
  p.push(`SameSite=${opts.sameSite || "Lax"}`);
  return p.join("; ");
}

export function parseCookies(request) {
  const header = request.headers.get("Cookie") || "";
  const out = {};
  for (const part of header.split(";")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    const k = part.slice(0, i).trim();
    if (k) out[k] = part.slice(i + 1).trim();
  }
  return out;
}

// Returns the verified session payload { sub, email, name, iat, exp } or null.
export async function readSession(request, env) {
  const cookies = parseCookies(request);
  const tok = cookies[SESSION_COOKIE];
  if (!tok) return null;
  const payload = await verifyToken(env.COOKIE_SECRET, "session", tok);
  if (!payload || !payload.sub) return null;
  if (payload.exp && Date.now() > payload.exp) return null;
  return payload;
}

export function escapeHtml(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
