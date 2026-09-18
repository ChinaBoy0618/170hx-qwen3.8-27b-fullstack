#!/usr/bin/env node
// Simulate a FRESH plain CC session ("你好") against 760.
// Body = byte-identical to what cc-haha would send for a brand-new plain
// session today: stable core (system+14 tools+deferred-tools+SessionStart+skills)
// + claudeMd block containing the CURRENT 14-line MEMORY.md index + date + "你好".
// Expected: near-full prefix hit (cached ≈ 23,3xx, uncached ≈ a few hundred).
import fs from "fs";
const KEY = process.env.SGLANG_API_KEY;
const body = JSON.parse(fs.readFileSync("/mnt/data/sglang-qwen38/cc-warm/new-session-nihao.json", "utf8"));

async function hit(port) {
  const t0 = Date.now();
  const r = await fetch(`http://localhost:${port}/v1/messages`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${KEY}` },
    body: JSON.stringify(body),
  });
  const j = await r.json().catch(() => ({}));
  const u = j.usage || {};
  const ms = Date.now() - t0;
  return { port, http: r.status, ms, cached: u.cache_read_input_tokens ?? null, uncached: u.input_tokens ?? null };
}

const rows = [];
for (const port of [5800, 5801, 5802, 5803]) {
  try { rows.push(await hit(port)); } catch (e) { rows.push({ port, err: e.message }); }
}
// production path: smg gateway (cache_aware) — raw passthrough of Bearer
try {
  rows.push(await hit(30010));
} catch (e) { rows.push({ port: 30010, err: e.message }); }

for (const x of rows) {
  if (x.err) { console.log(`[card ${x.port}] ERROR ${x.err}`); continue; }
  const total = (x.cached ?? 0) + (x.uncached ?? 0);
  const pct = total ? Math.round((x.cached / total) * 100) : null;
  console.log(`[card ${x.port}] http=${x.http} frt=${x.ms}ms cached=${x.cached} uncached=${x.uncached} hit=${pct}%`);
}
