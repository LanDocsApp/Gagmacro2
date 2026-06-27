// Best-effort Discord webhook notifications.
//
// Never throws into the caller and never blocks on failure: a Discord outage or
// a bad URL must NOT affect the 200/500 we return to Stripe from /api/webhook.
// Returns true if Discord accepted the message, false otherwise.

// Channel webhook. Overridable via the DISCORD_WEBHOOK_URL env var (Pages →
// Settings → Environment variables) so it can be rotated without a redeploy.
const DEFAULT_WEBHOOK_URL =
  "https://discord.com/api/webhooks/1520438020984143942/BLSP17_bEUaNswx1H5Vz_G5DKYpclB-K1sq1eYgq1gyqoGmSc4fjMsIYc71g_PqoaMPH";

export async function notifyDiscord(env, payload) {
  const url = (env && env.DISCORD_WEBHOOK_URL) || DEFAULT_WEBHOOK_URL;
  if (!url) return false;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      console.error("discord: webhook returned", res.status);
      return false;
    }
    return true;
  } catch (e) {
    console.error("discord: notify failed —", e && (e.message || e));
    return false;
  }
}

// Ping for a brand-new paying subscriber.
export async function notifyNewSubscriber(env, { customerId, googleId, status } = {}) {
  const fields = [];
  if (status) fields.push({ name: "Status", value: String(status), inline: true });
  if (customerId)
    fields.push({ name: "Stripe customer", value: String(customerId), inline: true });
  if (googleId)
    fields.push({ name: "Google ID", value: String(googleId), inline: false });

  return notifyDiscord(env, {
    content: "🎉 **New subscriber!**",
    embeds: [
      {
        title: "New subscription",
        color: 0x57f287, // Discord green
        fields,
        timestamp: new Date().toISOString(),
      },
    ],
  });
}
