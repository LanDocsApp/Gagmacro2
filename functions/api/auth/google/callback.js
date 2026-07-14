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

  // Where to land after login, in priority order:
  //   1. gag_return — a safe same-origin path the page asked to come back to (e.g. the
  //      giveaway page set it before sending the user to Google). Lets any page do a
  //      "sign in and come right back" round-trip.
  //   2. gag_offer — a pending flash-deal checkout (the macro opened /api/checkout?offer=N
  //      while signed out); send them STRAIGHT into checkout so the discount auto-applies.
  //   3. the normal sign-in landing.
  const ret = safeReturnPath(cookies["gag_return"]);
  const pendingOffer = (cookies["gag_offer"] || "").trim();
  const dest = ret
    ? `${base}${ret}`
    : /^[123]$/.test(pendingOffer)
    ? `${base}/api/checkout?offer=${pendingOffer}`
    : `${base}/signin.html`;
  const headers = new Headers({ Location: dest, "Cache-Control": "no-store" });
  // Consume the one-time return cookie.
  if (cookies["gag_return"]) headers.append("Set-Cookie", cookie("gag_return", "", { maxAge: 0 }));
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

// Validate a post-login return target. Only same-origin ABSOLUTE PATHS are allowed —
// it must start with a single "/" (not "//" or "/\", which browsers treat as a
// protocol-relative URL to another host), contain no backslashes, and use a
// conservative charset. Anything else -> null (fall through to the default landing).
// This blocks open-redirects: the cookie can never send a user to an external site.
function safeReturnPath(raw) {
  const s = String(raw || "").trim();
  if (!s || s.length > 512) return null;
  if (s[0] !== "/" || s[1] === "/" || s[1] === "\\") return null;
  if (s.includes("\\")) return null;
  if (!/^\/[A-Za-z0-9\-._~/?#\[\]@!$&'()*+,;=%]*$/.test(s)) return null;
  return s;
}
