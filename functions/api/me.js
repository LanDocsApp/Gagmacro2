// GET /api/me — lightweight JSON account status for the static sign-in page.
//
// Reads the signed session cookie and reports whether the user is signed in and
// whether they currently hold an access-granting subscription. The static
// "Welcome back" page uses this to show a "Manage subscription" button to
// subscribers only. Auth is the signed HttpOnly session cookie — never the
// display cookie, which is presentation-only.

import { resolveActive } from "../_lib/subscriptions.js";
import { readSession, json } from "../_lib/http.js";

export async function onRequestGet({ request, env }) {
  const session = await readSession(request, env);
  if (!session) return json({ signedIn: false, active: false });

  let active = false;
  try {
    // resolveActive can return null when Stripe/KV are unreachable (status
    // undetermined). Only a definite `true` reveals the manage button — a
    // transient outage just hides it, which is harmless for a convenience link.
    active = (await resolveActive(env, session.sub)) === true;
  } catch {
    active = false;
  }

  return json({ signedIn: true, email: session.email || "", active });
}
