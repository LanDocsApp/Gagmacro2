// GET /api/creator/link?key=<STATS_KEY>[&id=<slug>] — admin helper to mint the
// private dashboard link(s) you hand to creators. Gated by the same STATS_KEY as
// /api/stats, so only you can generate them.
//
//   ?id=jukem  -> one creator's link
//   (no id)    -> every creator's link, for onboarding them all at once
//
// The returned `url` is the magic link (token in the URL fragment); send it to the
// creator. They open it once and it's remembered in their browser.

import { json, baseUrl } from "../../_lib/http.js";
import { signToken } from "../../_lib/crypto.js";
import { CREATORS, getCreator } from "../../_lib/creators.js";

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const key = url.searchParams.get("key") || "";
  if (!env.STATS_KEY || key !== env.STATS_KEY) {
    return json({ error: "unauthorized" }, 401);
  }

  const base = baseUrl(request, env);

  async function linkFor(id) {
    const c = getCreator(id);
    if (!c) return null;
    const token = await signToken(env.COOKIE_SECRET, "creator", { t: "creator", id: c.id });
    return {
      id: c.id,
      name: c.name,
      codes: c.codes,
      token,
      url: `${base}/creator.html#${token}`,
    };
  }

  const wanted = url.searchParams.get("id");
  if (wanted) {
    const one = await linkFor(wanted);
    if (!one) return json({ error: "unknown creator" }, 404);
    return json(one);
  }

  const creators = [];
  for (const id of Object.keys(CREATORS)) creators.push(await linkFor(id));
  return json({ creators });
}
