// GET /api/auth/google/callback — verify CSRF state, exchange the code, and
// set a signed session cookie, then return to the sign-in landing page.

import { exchangeCode, decodeIdToken } from "../../../_lib/google.js";
import { signToken } from "../../../_lib/crypto.js";
import {
  baseUrl,
  redirectUriFor,
  parseCookies,
  cookie,
  STATE_COOKIE,
  SESSION_COOKIE,
  DISPLAY_COOKIE,
  SESSION_TTL_MS,
  SESSION_TTL_S,
} from "../../../_lib/http.js";

export async function onRequestGet({ request, env }) {
  const base = baseUrl(request, env);
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const cookies = parseCookies(request);

  const fail = (reason) => {
    const headers = new Headers({ Location: `${base}/signin.html?error=${reason}` });
    // Clear the one-time state cookie regardless of outcome.
    headers.append("Set-Cookie", cookie(STATE_COOKIE, "", { maxAge: 0 }));
    return new Response(null, { status: 302, headers });
  };

  if (url.searchParams.get("error")) return fail("denied");
  if (!code) return fail("auth");
  if (!state || state !== cookies[STATE_COOKIE]) return fail("state");

  let profile;
  try {
    const tokens = await exchangeCode(env, code, redirectUriFor(request, env));
    profile = decodeIdToken(tokens.id_token);
  } catch {
    return fail("exchange");
  }
  if (!profile || !profile.sub) return fail("profile");

  const now = Date.now();
  const session = await signToken(env.COOKIE_SECRET, "session", {
    sub: profile.sub,
    email: profile.email || "",
    name: profile.name || "",
    iat: now,
    exp: now + SESSION_TTL_MS,
  });

  // If a flash-deal checkout is pending (the macro opened /api/checkout?offer=N while
  // signed out, which stashed the variant in the gag_offer cookie), send the user STRAIGHT
  // back into checkout after login so the discount auto-applies — instead of dropping them
  // on the sign-in page. Otherwise, the normal landing.
  const pendingOffer = (cookies["gag_offer"] || "").trim();
  const dest = /^[123]$/.test(pendingOffer)
    ? `${base}/api/checkout?offer=${pendingOffer}`
    : `${base}/signin.html`;
  const headers = new Headers({ Location: dest, "Cache-Control": "no-store" });
  headers.append(
    "Set-Cookie",
    cookie(SESSION_COOKIE, session, { maxAge: SESSION_TTL_S, httpOnly: true, sameSite: "Lax" })
  );
  // Display-only (readable by the static page) — never trusted for auth.
  headers.append(
    "Set-Cookie",
    cookie(DISPLAY_COOKIE, encodeURIComponent(profile.email || ""), {
      maxAge: SESSION_TTL_S,
      sameSite: "Lax",
    })
  );
  headers.append("Set-Cookie", cookie(STATE_COOKIE, "", { maxAge: 0 }));
  return new Response(null, { status: 302, headers });
}
