// Parity program — a thrown string reaches `catch` as a std Error carrying it, on every lane:
// a literal, a string variable, a template, one raised in a callee, and a rethrow.

function label(n: number): string {
	return `label ${n}`;
}

function fail(n: number): void {
	if (n > 2) { throw `too big: ${n}`; }
}

function report(tag: string, e: Error): void {
	console.log(tag + " msg=[" + e.message + "]");
}

function main(): void {
	try { throw "bare 7"; } catch (e) { report("literal", e); }
	const s = label(3);
	try { throw s; } catch (e) { report("variable", e); }
	try { throw `${s}!`; } catch (e) { report("template", e); }
	try { fail(5); } catch (e) { report("callee", e); }
	try {
		try { fail(9); } catch (e) { throw e; }
	} catch (e2) { report("rethrow", e2); }
	try { throw new Error("rich 7"); } catch (e) { report("error", e); }
}
main();
