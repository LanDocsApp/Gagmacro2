// GET /api/auth/google/login — start Google OAuth with a CSRF state.

import { googleAuthUrl } from "../../../_lib/google.js";
import { randomToken } from "../../../_lib/crypto.js";
import { redirectUriFor, cookie, STATE_COOKIE } from "../../../_lib/http.js";

export async function onRequestGet({ request, env }) {
  const state = randomToken(16);
  const url = googleAuthUrl(env, state, redirectUriFor(request, env));

  const headers = new Headers({ Location: url, "Cache-Control": "no-store" });
  headers.append(
    "Set-Cookie",
    cookie(STATE_COOKIE, state, { maxAge: 600, httpOnly: true, sameSite: "Lax" })
  );
  return new Response(null, { status: 302, headers });
}
