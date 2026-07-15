// GET /api/giveaway/check-code?code=XXXX
//
// Read-only validation used by the giveaway wizard so it can tell the user
// "code is invalid" the moment they type it, WITHOUT shipping the real macro
// code down to the page (the public /api/giveaway payload only exposes the
// code's length, never the code itself). No session or DB needed.
//
// Two kinds of code count as valid (both prove the person has the macro -> +2 entries):
//   - the single shared MACRO_CODE (everyone with the macro sees it in the footer)
//   - any creator code (a creator's audience sees THEIR code in the footer instead)
// For a creator code we also hand back the code + its checkout discount percent, so the
// wizard can swap the generic "30% off GIVEAWAY" chip for "N% off with code LION".

import { json } from "../../_lib/http.js";
import { MACRO_CODE } from "../../_lib/giveaways.js";
import { creatorCode, creatorCodePercent } from "../../_lib/creators.js";

export async function onRequestGet({ request }) {
  const url = new URL(request.url);
  const code = String(url.searchParams.get("code") || "").trim().toUpperCase();

  if (code && code === MACRO_CODE.toUpperCase()) {
    return json({ valid: true, creator: false });
  }

  const cc = creatorCode(code); // "" unless it's a known creator code
  if (cc) {
    return json({ valid: true, creator: true, code: cc, percentOff: creatorCodePercent(cc) });
  }

  return json({ valid: false });
}
