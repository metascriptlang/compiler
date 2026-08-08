// @ledger-slack(msRefArrayRefCell): 1
// Parity program — array fields through the typed JSON.parse<T> facade.
// Its own program since birth: the split predates a since-fixed instantiation
// bug (an array-typed interface declared next to 509's dropped the `string`
// in Result<T, string>); kept because corpus programs are append-only.
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

interface Line {
	sku: string;
	qty: int64;
}

interface Cart {
	items: Line[];
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

	const cart = JSON.parse<Cart>("{\"items\":[{\"sku\":\"a\",\"qty\":2},{\"sku\":\"b\",\"qty\":3}]}");
	if (cart.ok) {
		console.log("cart ok n=" + cart.value.items.length.toString() + " second=" + cart.value.items[1].sku + " qty=" + cart.value.items[1].qty.toString());
	} else {
		console.log("cart err=" + cart.error);
	}

	const badElem = JSON.parse<Cart>("{\"items\":[{\"sku\":\"a\",\"qty\":\"two\"}]}");
	if (badElem.ok) {
		console.log("badElem ok — WRONG");
	} else {
		console.log("badElem err=" + badElem.error);
	}

	const missingElemField = JSON.parse<Cart>("{\"items\":[{\"sku\":\"a\",\"qty\":1},{\"sku\":\"b\"}]}");
	if (missingElemField.ok) {
		console.log("missingElemField ok — WRONG");
	} else {
		console.log("missingElemField err=" + missingElemField.error);
	}

	const nonObjElem = JSON.parse<Cart>("{\"items\":[7]}");
	if (nonObjElem.ok) {
		console.log("nonObjElem ok — WRONG");
	} else {
		console.log("nonObjElem err=" + nonObjElem.error);
	}

	const emptyItems = JSON.parse<Cart>("{\"items\":[]}");
	if (emptyItems.ok) {
		console.log("emptyItems ok n=" + emptyItems.value.items.length.toString());
	} else {
		console.log("emptyItems err=" + emptyItems.error);
	}
}

main();
