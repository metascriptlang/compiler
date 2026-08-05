// @ledger-slack(msRefArrayRefCell): 1
// Parity program — std json codec depth: escape decode (incl. \u + surrogate
// pairs → WTF-8 byte metrics, corpus 101 convention), int/float split,
// stringifyPretty shape, and the typed macro path JSON.stringify<T> /
// JSON.parse<T> (compile-time codec expansion — the serialize flagship).

interface Item {
	id: int32;
	label: string;
	price: number;
	active: boolean;
}

function main(): void {
	const er = parseJson("{\"e\":\"a\\nb\\tc\\\"d\\\\e\",\"u\":\"\\u0041\\u00e9\",\"astral\":\"\\ud83d\\ude00\"}");
	if (!er.ok) { console.log("escFail=" + er.error); return; }
	const ev: JsonValue = er.value;
	const e: JsonValue = ev.getDynamicField("e");
	console.log("escLen=" + e.asString().byteLength().toString());
	const u: JsonValue = ev.getDynamicField("u");
	console.log("uLen=" + u.asString().byteLength().toString());
	const astral: JsonValue = ev.getDynamicField("astral");
	console.log("astralLen=" + astral.asString().byteLength().toString());

	const nr = parseJson("{\"i\":123456789012345,\"neg\":-7,\"f\":0.5,\"zero\":0}");
	if (!nr.ok) { console.log("numFail=" + nr.error); return; }
	const nv: JsonValue = nr.value;
	const i: JsonValue = nv.getDynamicField("i");
	console.log("i=" + i.asInt64().toString());
	const neg: JsonValue = nv.getDynamicField("neg");
	console.log("neg=" + neg.asInt64().toString());
	const fl: JsonValue = nv.getDynamicField("f");
	console.log("f=" + fl.asNumber().toString());
	const zero: JsonValue = nv.getDynamicField("zero");
	console.log("zeroKind=" + (zero.kind === JsonKind.Int ? "int" : "num"));

	const pr = parseJson("{\"a\":[1],\"o\":{\"b\":true}}");
	if (!pr.ok) { console.log("preFail=" + pr.error); return; }
	const pv: JsonValue = pr.value;
	console.log("pretty:");
	console.log(stringifyPretty(pv, 2));

	const it: Item = { id: 3, label: "spoon", price: 2.5, active: true };
	const ts = JSON.stringify(it);
	console.log("typed=" + ts);
	const back = JSON.parse<Item>(ts);
	if (!back.ok) { console.log("backFail=" + back.error); return; }
	console.log("back=" + back.value.label + "/" + back.value.id.toString() + "/" + (back.value.active ? "t" : "f"));

	// Lone surrogates have no valid UTF-8 encoding. Emitting them raw produced
	// invalid UTF-8 on C and U+FFFD on JS — the two backends corrupted the same
	// input differently, which is exactly what this lane exists to catch.
	const lone = JSON.parseValue("[\"\\ud800\",\"a\\udfffb\",\"\\ud83d\\ude00\"]");
	if (!lone.ok) { console.log("loneFail=" + lone.error); return; }
	const lv: JsonValue = lone.value;
	console.log("lone=" + stringify(lv));
	const roundTrip = JSON.parseValue(stringify(lv));
	if (!roundTrip.ok) { console.log("rtFail=" + roundTrip.error); return; }
	const rv: JsonValue = roundTrip.value;
	console.log("loneRT=" + stringify(rv));
	console.log("loneBytes=" + lv.at(0).asString().byteLength.toString()
		+ "," + lv.at(1).asString().byteLength.toString()
		+ "," + lv.at(2).asString().byteLength.toString());
}

main();
