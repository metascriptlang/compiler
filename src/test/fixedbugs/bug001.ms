// bug001 — DU type-cache structural-key collision
//
// Symptom:  Two NAMED generic DUs with structurally-identical variants
//           (e.g. `Either<string, number>` and `Result<number, string>`,
//           both having `{ok:true,value:number} | {ok:false,error:string}`)
//           coexisting in one module → second-emitted union typedef MISSING →
//           link error: undefined symbol `Result__number_string`.
//
// Root cause: `genUnionType` (src/codegen/c/types.ms) had a structural-key
//             cross-cache that was meant for anonymous-vs-named matching but
//             accidentally collapsed two NAMED unions to one C typedef when
//             their variant shapes matched.
//
// Fix:        Removed the structural-key lookup entirely. typeKey is unique
//             per type (named: `union:<monoName>`, anon: `union(<v0>|<v1>)`)
//             and that's enough; named-named collision can no longer happen.

type Either<L, R> = match (ok: boolean) {
	true => { value: R },
	false => { error: L },
};

function eitherDiv(a: number, b: number): Either<string, number> {
	if (b == 0) return { ok: false, error: "div0" };
	return { ok: true, value: a / b };
}

function resultDiv(a: number, b: number): Result<number, string> {
	if (b == 0) return Result.err("div0");
	return Result.ok(a / b);
}

test "bug001: Either + Result with identical variant shape coexist" {
	// Pre-fix: link error — `Result__number_string` typedef never emitted.
	const e = eitherDiv(20, 4);
	const r = resultDiv(20, 4);
	assert e.ok && r.ok;
	if (e.ok) assert e.value == 5;
	if (r.ok) assert r.value == 5;
}

test "bug001: error variants of structurally-identical DUs distinct at runtime" {
	const e = eitherDiv(10, 0);
	const r = resultDiv(10, 0);
	assert !e.ok && !r.ok;
	if (!e.ok) assert e.error == "div0";
	if (!r.ok) assert r.error == "div0";
}
