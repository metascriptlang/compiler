// @ledger-slack(msRefArrayRefCell): 1
// Parity program — array fields through the typed JSON.parse<T> facade.
// Deliberately its own program: an array-typed interface declared next to
// 509's interfaces makes generic instantiation drop the `string` in
// Result<T, string> (compiler bug, reported separately).
// Array fields never worked through the facade before the strict decode
// landed — a `T[]` field arrives as Ref<Array<T>> and fell through to the
// "unsupported field type" arm; nothing in the tree exercised that path.

interface Tagged {
	label: string;
	tags: string[];
}

interface Sized {
	name: string;
	sizes: int32[];
}

function main(): void {
	const okTags = JSON.parse<Tagged>("{\"label\":\"l\",\"tags\":[\"a\",\"b\"]}");
	if (okTags.ok) {
		console.log("tags ok n=" + okTags.value.tags.length.toString() + " first=" + okTags.value.tags[0]);
	} else {
		console.log("tags err=" + okTags.error);
	}

	const emptyTags = JSON.parse<Tagged>("{\"label\":\"l\",\"tags\":[]}");
	if (emptyTags.ok) {
		console.log("empty ok n=" + emptyTags.value.tags.length.toString());
	} else {
		console.log("empty err=" + emptyTags.error);
	}

	const wrongKind = JSON.parse<Tagged>("{\"label\":\"l\",\"tags\":3}");
	if (wrongKind.ok) {
		console.log("wrongKind ok — WRONG");
	} else {
		console.log("wrongKind err=" + wrongKind.error);
	}

	const missing = JSON.parse<Tagged>("{\"label\":\"l\"}");
	if (missing.ok) {
		console.log("missing ok — WRONG");
	} else {
		console.log("missing err=" + missing.error);
	}

	const sized = JSON.parse<Sized>("{\"name\":\"s\",\"sizes\":[1,2,3]}");
	if (sized.ok) {
		console.log("sized ok n=" + sized.value.sizes.length.toString() + " last=" + sized.value.sizes[2].toString());
	} else {
		console.log("sized err=" + sized.error);
	}
}

main();
