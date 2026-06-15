// Google OAuth (OpenID Connect) helpers — scope "openid email profile".

import { stringFromB64url } from "./crypto.js";

export function googleAuthUrl(env, state, redirectUri) {
  const p = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: "openid email profile",
    state,
    access_type: "online",
    include_granted_scopes: "true",
    prompt: "select_account",
  });
  return "https://accounts.google.com/o/oauth2/v2/auth?" + p.toString();
}

export async function exchangeCode(env, code, redirectUri) {
  const body = new URLSearchParams({
    code,
    client_id: env.GOOGLE_CLIENT_ID,
    client_secret: env.GOOGLE_CLIENT_SECRET,
    redirect_uri: redirectUri,
    grant_type: "authorization_code",
  });
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.error_description || data.error || `token exchange failed (${res.status})`);
  }
  return data; // { access_token, id_token, expires_in, ... }
}

// The id_token comes straight from Google's token endpoint over TLS, so per the
// OIDC spec we can trust its claims without re-fetching the JWKS — just decode
// the payload to read sub/email/name.
export function decodeIdToken(idToken) {
  if (!idToken || typeof idToken !== "string") return null;
  const parts = idToken.split(".");
  if (parts.length < 2) return null;
  try {
    return JSON.parse(stringFromB64url(parts[1]));
  } catch {
    return null;
  }
}
