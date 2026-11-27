// Checks a running install through the app, as a browser would: every mode's custom nodes are registered in ComfyUI,
// and which model files are still missing. Run it after start.sh, with the address it printed:
//
//   node scripts/linux/check.mjs https://….trycloudflare.com "$OPENJUTSU_PASSWORD"
//   node scripts/linux/check.mjs http://127.0.0.1:3000
//
// Exits 1 when a mode lacks custom nodes, or when a model in REQUIRED_MODELS (space-separated file names) is missing.
const [address, password = ""] = process.argv.slice(2);
if (!address) {
  console.error("Usage: node scripts/linux/check.mjs <app address> [password]");
  process.exit(2);
}
const base = address.replace(/\/+$/, "");
const headers = { "Content-Type": "application/json", Origin: new URL(base).origin };
if (password) headers.Authorization = `Basic ${Buffer.from(`openjutsu:${password}`).toString("base64")}`;

const model = {
  model: "minimax_h3_ref2va_pruned_int8_convrot.safetensors",
  loras: [{ name: "minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors", strength: 1 }],
  steps: 6, describer: "qwen3vl_8b_int8_convrot.safetensors", textEncoder: "qwen3vl_32b_minimax_h3_int4_convrot.safetensors",
  videoVae: "minimax_h3_video_vae_int8_convrot.safetensors", audioVae: "minimax_h3_audio_vae_fp32.safetensors", acceleration: "none",
};
const run = { resolution: "736p", motion: 512, hatFix: true, noLipSync: true, margin: "normal", seed: 0, clipSeconds: 6 };
const tone = { mode: "Reinhard", exposure: 0.09, contrast: 0.84, pivot: 0.69, highlight_rolloff: 0.27, shadow_lift: 0.15, black_floor: 0.03, saturation: 1.05, strength: 0.2 };
const object = { ...run, target: "hair", changeTo: "short pink hair", biggestOnly: false, keepOutline: true, margin: "normal" };
const modes = {
  "Simple": { kind: "simple", settings: { ...run, role: "", target: "person" }, model },
  "Check mask": { kind: "mask", hatFix: true, margin: "normal", target: "person" },
  "Advanced": { kind: "advanced", settings: { ...run, roles: ["", "", "", ""] }, pictures: 4, model },
  "One pass per person": { kind: "advanced_maxq", settings: { ...run, roles: ["", ""] }, pictures: 2, model },
  "Montage": { kind: "montage", settings: { ...run, roles: ["a - b", "c - d"] }, pictures: 2, review: null, model },
  "Find people": { kind: "people", resolution: "736p", describer: model.describer },
  "Object: change": { kind: "object", settings: { ...object, mode: "change" }, picture: true, model },
  "Object: remove": { kind: "object", settings: { ...object, mode: "remove" }, picture: false, model },
  "Object: background": { kind: "object", settings: { ...object, mode: "background", target: "person" }, picture: true, model },
  "Object: add": { kind: "object", settings: { ...object, mode: "add", target: "on the table", changeTo: "a cake", placement: [{ frame: 0, x: 0.2, y: 0.2, width: 0.3, height: 0.3 }] }, picture: false, model },
  "Check fit": { kind: "fit", resolution: "736p" },
  "Fix faces": { kind: "face", settings: { style: "mouth", seed: 0, chunkSeconds: 6.5 }, model },
  "Fix colours": { kind: "color", settings: { detail: -0.2, tone } },
};

async function setup(selection) {
  for (let attempt = 1; ; attempt++) {
    try {
      const response = await fetch(`${base}/api/setup`, { method: "POST", headers, body: JSON.stringify(selection) });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(`HTTP ${response.status}: ${body.error ?? "no JSON"}`);
      return body;
    } catch (error) {
      // A new quick tunnel can take a little while to resolve.
      if (attempt === 10 || /HTTP 40[13]/.test(error.message)) throw error;
      await new Promise((resolve) => setTimeout(resolve, 3000));
    }
  }
}

let failed = false;
const missingModels = new Set();
for (const [name, selection] of Object.entries(modes)) {
  const result = await setup(selection);
  if (result.error && result.packs.length === 0 && result.models.length === 0) {
    console.log(`✗ ${name}: ${result.error}`);
    failed = true;
    continue;
  }
  const packs = result.packs.map((pack) => `${pack.name} (${pack.nodes.join(", ") || "no nodes"})`);
  for (const m of result.models) missingModels.add(`${m.folder}/${m.name}`);
  console.log(`${packs.length ? "✗" : "✓"} ${name}${packs.length ? `: missing ${packs.join("; ")}` : ""}${result.models.length ? `  (models missing: ${result.models.map((m) => m.name).join(", ")})` : ""}`);
  if (packs.length) failed = true;
}
const required = (process.env.REQUIRED_MODELS ?? "").split(/\s+/).filter(Boolean);
for (const name of required) {
  if ([...missingModels].some((entry) => entry.endsWith(`/${name}`) || entry.endsWith(`\\${name}`))) {
    console.log(`✗ required model missing: ${name}`);
    failed = true;
  }
}
console.log(failed ? "\nSome modes are not ready; see ✗ above." : `\nEvery mode's custom nodes are installed.${missingModels.size ? ` Missing model files: ${[...missingModels].join(", ")}` : ""}`);
process.exit(failed ? 1 : 0);
