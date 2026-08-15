// Phase 6 — user-defined type predicates (`x is T` return type).
//
// The parser recognizes `<ident> is <type>` in return position, resolvePass
// resolves the target type and stashes a sentinel on the Function type's
// `typeExtra`, and flow narrowing reads that sentinel when the call appears
// in a predicate position. TrueCondition narrows to the target type;
// FalseCondition excludes the variant from the surrounding union.
//
// This example exercises the parser + checker + flow path end-to-end. Full
// codegen with variant-aware member dispatch after flow narrow is a separate
// gap; here we only call functions that take the narrowed type as a
// pass-through, so the checker's narrowing is enough to make the code type-
// check without any member access on the narrow.

function isNonEmpty(s: string): s is string {
	return s.length > 0;
}

function shout(s: string): string {
	return s + "!";
}

function announce(name: string): string {
	if (isNonEmpty(name)) {
		// Narrowed by predicate (same type here, but the narrowing path ran).
		return shout(name);
	}
	return "<unnamed>";
}

function main(): int32 {
	console.log(announce("Alice"));
	console.log(announce(""));
	return 0;
}

main();
