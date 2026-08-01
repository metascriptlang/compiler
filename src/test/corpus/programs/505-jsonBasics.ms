// @ledger-slack(msRefArrayRefCell): 1
// @xfail(san): parsed null/true/false literals leak 1 JsonValueData each —
// parser.ms builds jsonBool(true)/jsonNull() as CALL-SITE args in match arms
// (parseLiteral value param): the open DRC call-arg-object gap (siblings
// 609/610). Builder-side construction is clean (probed). XPASS = fix landed.
// Parity program — std json floor: parse → dynamic access → stringify roundtrip.
// Facade lives at std/core/json (prelude, auto-loaded); codec is pure MS in
// std/serialize/json/ — this program is the contract for the whole chain.
// getDynamicField/at return jsonNull sentinels (not |null) — chain freely,
// probe kind for absence. Intermediates annotated `: JsonValue` (method
// dispatch on the raw match-type expansion is the open G1/DU cluster).

function main(): void {
	const pr = parseJson("{\"s\":\"hi\",\"n\":42,\"f\":true,\"z\":null,\"a\":[1,2,3],\"o\":{\"k\":\"v\"}}");
	if (!pr.ok) { console.log("parseFail=" + pr.error); return; }
	const v: JsonValue = pr.value;
	console.log("round=" + stringify(v));

	const s: JsonValue = v.getDynamicField("s");
	console.log("s=" + s.asString());
	const n: JsonValue = v.getDynamicField("n");
	console.log("n=" + n.asNumber().toString());
	const f: JsonValue = v.getDynamicField("f");
	console.log("f=" + (f.asBoolean() ? "t" : "f"));
	const z: JsonValue = v.getDynamicField("z");
	console.log("zKind=" + (z.kind === JsonKind.Null ? "null" : "other"));
	const missing: JsonValue = v.getDynamicField("nope");
	console.log("missing=" + (missing.kind === JsonKind.Null ? "null" : "found"));

	const a: JsonValue = v.getDynamicField("a");
	console.log("aLen=" + a.length().toString());
	const a1: JsonValue = a.at(1);
	console.log("a1=" + a1.asNumber().toString());
	const o: JsonValue = v.getDynamicField("o");
	const k: JsonValue = o.getDynamicField("k");
	console.log("ok=" + k.asString());

	const bad = parseJson("{\"open\":");
	console.log("badRejected=" + (bad.ok ? "no" : "yes"));

	const built: JsonValue = jsonObject([], []);
	built.setDynamicField("name", jsonString("neo"));
	built.setDynamicField("count", jsonInt(7));
	built.setDynamicField("list", jsonArrayOfNumbers([1.5, 2.5]));
	console.log("built=" + stringify(built));
}

main();
