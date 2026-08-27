// Parity program — the strict typed-decode contract: JSON.parse<T> fails
// loud instead of fabricating defaults. Every failing case here returned
// `ok` with zero-valued fields before the req* accessors landed, so this
// file is the regression pin against silent data invention.
// The error TEXT is part of the contract (callers act on it), hence printed
// rather than only the ok/err flag.
// Array-field cases live in 510-jsonStrictArray. The split predates a
// since-fixed instantiation bug (an unused array-typed interface declared
// alongside these dropped the `string` in Result<T, string>); kept because
// corpus programs are append-only.

interface User {
	id: int64;
	name: string;
}

interface Address {
	city: string;
	zip: int32;
}

interface Employee {
	name: string;
	addr: Address;
}

function show(label: string, r: Result<User, string>): void {
	if (r.ok) {
		console.log(label + " ok id=" + r.value.id.toString() + " name=" + r.value.name);
	} else {
		console.log(label + " err=" + r.error);
	}
}

function main(): void {
	show("valid", JSON.parse<User>("{\"id\":7,\"name\":\"ada\"}"));
	show("empty", JSON.parse<User>("{}"));
	show("wrongKind", JSON.parse<User>("{\"id\":\"abc\",\"name\":42}"));
	show("floatForInt", JSON.parse<User>("{\"id\":1.5,\"name\":\"x\"}"));
	show("nullField", JSON.parse<User>("{\"id\":null,\"name\":\"x\"}"));
	show("topArray", JSON.parse<User>("[1,2]"));
	show("topInt", JSON.parse<User>("42"));
	show("syntax", JSON.parse<User>("{oops"));

	// Extra keys are accepted — the type says what is REQUIRED, not what is
	// forbidden (JS parity: an unknown key is not an error).
	show("extraKey", JSON.parse<User>("{\"id\":1,\"name\":\"n\",\"extra\":true}"));

	// Duplicate keys: last one wins, matching the JS engine on the same text.
	show("dup", JSON.parse<User>("{\"id\":1,\"name\":\"first\",\"name\":\"last\"}"));

	const okEmp = JSON.parse<Employee>("{\"name\":\"a\",\"addr\":{\"city\":\"HN\",\"zip\":100}}");
	if (okEmp.ok) {
		console.log("nested ok city=" + okEmp.value.addr.city + " zip=" + okEmp.value.addr.zip.toString());
	} else {
		console.log("nested err=" + okEmp.error);
	}

	const badEmp = JSON.parse<Employee>("{\"name\":\"a\",\"addr\":{\"city\":\"HN\"}}");
	if (badEmp.ok) {
		console.log("nestedMissing ok — WRONG");
	} else {
		console.log("nestedMissing err=" + badEmp.error);
	}

	const noAddr = JSON.parse<Employee>("{\"name\":\"a\"}");
	if (noAddr.ok) {
		console.log("nestedAbsent ok — WRONG");
	} else {
		console.log("nestedAbsent err=" + noAddr.error);
	}
}

main();
