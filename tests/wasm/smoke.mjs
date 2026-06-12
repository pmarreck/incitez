#!/usr/bin/env node
// WASM ABI smoke test — an independent (non-Zig) consumer that drives the
// exact boundary a browser would use, so it MFIC-checks the artifact rather
// than the source that produced it. Instantiates incitez.wasm with ZERO
// imports (freestanding, no WASI), then exercises every export.
//
// Usage: node smoke.mjs <path/to/incitez.wasm>
// Exit 0 = all checks passed; non-zero = a numbered check failed.
import { readFile } from "node:fs/promises";

const wasmPath = process.argv[2];
if (!wasmPath) {
	console.error("usage: node smoke.mjs <path/to/incitez.wasm>");
	process.exit(2);
}

let failures = 0;
function check(label, cond, detail) {
	if (cond) {
		console.log(`  ok   ${label}`);
	} else {
		failures++;
		console.error(`  FAIL ${label}${detail ? ` — ${detail}` : ""}`);
	}
}

const bytes = await readFile(wasmPath);
// Zero imports: a freestanding reactor module must instantiate cleanly with
// an empty import object. If this throws, the artifact is not browser-ready.
const { instance } = await WebAssembly.instantiate(bytes, {});
const ex = instance.exports;

// Linear memory grows during extract(); the old ArrayBuffer detaches on grow,
// so always re-derive views AFTER the call that allocated.
const mem = () => ex.memory.buffer;
const u8 = () => new Uint8Array(mem());
const dv = () => new DataView(mem());
const enc = new TextEncoder();
const dec = new TextDecoder();

function readCString(off) {
	const m = u8();
	let end = off;
	while (m[end] !== 0) end++;
	return dec.decode(m.subarray(off, end));
}

// 1) Required exports are present.
for (const name of [
	"memory",
	"incitez_alloc",
	"incitez_free",
	"incitez_extract",
	"incitez_selftest",
	"incitez_version_ptr",
]) {
	check(`export ${name}`, name in ex, "missing");
}

// 2) version string is a non-empty NUL-terminated ASCII string.
const version = readCString(ex.incitez_version_ptr());
check("version non-empty", version.length > 0, JSON.stringify(version));

// 3) selftest: high 16 bits = passed, low 16 = total; all must pass.
const st = ex.incitez_selftest() >>> 0;
const passed = st >>> 16;
const total = st & 0xffff;
check(`selftest ${passed}/${total}`, total > 0 && passed === total,
	`${passed} of ${total}`);

// extract(text) -> parsed JSON array, via the documented memory protocol.
function extract(text) {
	const inBytes = enc.encode(text);
	const inPtr = ex.incitez_alloc(inBytes.length);
	if (inPtr === 0) throw new Error("incitez_alloc returned 0");
	u8().set(inBytes, inPtr);
	const resPtr = ex.incitez_extract(inPtr, inBytes.length);
	if (resPtr === 0) throw new Error("incitez_extract returned 0");
	// re-derive views: extract may have grown memory
	const jsonLen = dv().getUint32(resPtr, true);
	const jsonBytes = u8().subarray(resPtr + 4, resPtr + 4 + jsonLen);
	const json = dec.decode(jsonBytes);
	ex.incitez_free(inPtr);
	ex.incitez_free(resPtr);
	return JSON.parse(json);
}

// 4) a basic full citation round-trips through the ABI.
{
	const cites = extract("Foo v. Bar, 1 U.S. 1 (1982).");
	check("extract finds 1 cite", cites.length === 1, `got ${cites.length}`);
	const c = cites[0] ?? {};
	check("cite reporter U.S.", c.reporter === "U.S.", JSON.stringify(c.reporter));
	check("cite year 1982", c.year === 1982, JSON.stringify(c.year));
}

// 5) empty input yields an empty array (not a crash, not null).
{
	const cites = extract("");
	check("empty input -> []", Array.isArray(cites) && cites.length === 0);
}

// 6) the en-dash pin "surpass" survives the round trip.
{
	const cites = extract("530 U. S. 238, 241–242 (2000)");
	const c = cites[0] ?? {};
	check("en-dash pin recovered", cites.length === 1 && c.pin_cite != null,
		JSON.stringify(c.pin_cite));
}

if (failures === 0) {
	console.log(`\nWASM smoke: ALL PASSED (incitez ${version})`);
	process.exit(0);
} else {
	console.error(`\nWASM smoke: ${failures} FAILED`);
	process.exit(1);
}
