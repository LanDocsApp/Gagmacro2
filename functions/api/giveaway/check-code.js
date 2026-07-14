// GET /api/giveaway/check-code?code=XXXX
//
// Read-only validation used by the giveaway wizard so it can tell the user
// "code is invalid" the moment they type it, WITHOUT shipping the real macro
// code down to the page (the public /api/giveaway payload only exposes the
// code's length, never the code itself). No session or DB needed.

import { json } from "../../_lib/http.js";
import { MACRO_CODE } from "../../_lib/giveaways.js";

export async function onRequestGet({ request }) {
  const url = new URL(request.url);
  const code = String(url.searchParams.get("code") || "").trim().toUpperCase();
  return json({ valid: !!code && code === MACRO_CODE.toUpperCase() });
}
