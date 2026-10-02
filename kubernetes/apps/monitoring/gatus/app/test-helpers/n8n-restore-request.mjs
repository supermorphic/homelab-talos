const endpoint = `http://${process.env.APP_NAME}.automation.svc.cluster.local:5678/webhook/platform-canary`;
const correlation = `restore-${process.env.RUN_HASH}`;
const send = (value, token) => fetch(endpoint, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    ...(token ? {"X-Platform-Canary": token} : {}),
  },
  body: JSON.stringify({correlation: value}),
  signal: AbortSignal.timeout(60000),
});
const negative = await send(`restore-negative-${process.env.RUN_HASH}`);
if (![400, 401, 403, 404].includes(negative.status)) {
  throw new Error(`Unauthenticated request returned HTTP ${negative.status}`);
}
const positive = await send(correlation, process.env.CANARY_TOKEN);
if (!positive.ok) throw new Error(`Authenticated request returned HTTP ${positive.status}`);
let body;
try { body = await positive.json(); } catch { throw new Error("Authenticated response was not JSON"); }
const keys = Object.keys(body).sort();
if (JSON.stringify(keys) !== JSON.stringify(["correlation", "executionId", "status"])) {
  throw new Error("Authenticated response had an unexpected key set");
}
if (body.status !== "ok" || body.correlation !== correlation ||
    typeof body.executionId !== "string" || body.executionId.length === 0) {
  throw new Error("Authenticated response failed its exact value contract");
}
