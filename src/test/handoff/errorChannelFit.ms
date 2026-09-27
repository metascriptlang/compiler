import { compileToCWithStd } from "../helpers";

const errors = `
enum SourceError { Missing, WrongOwner }
enum TargetError { Account, Dead }
function load(): Result<uint64, SourceError> { return Result.err(SourceError.WrongOwner); }
`;

struct ConversionScope {
	declarations: string;
	accepted: boolean;
}

test "propagation requires one unambiguous conversion into the enclosing error channel" {
	const scopes: ConversionScope[] = [
		{ declarations: "", accepted: false },
		{ declarations: "converter convert(e: SourceError): TargetError { return TargetError.Account; }", accepted: true },
		{ declarations: "converter first(e: SourceError): TargetError { return TargetError.Account; } converter second(e: SourceError): TargetError { return TargetError.Dead; }", accepted: false },
	];
	for (const scope of scopes) {
		for (const body of ["const v = try load(); return Result.ok(v);", "return Result.ok(try load());"]) {
			for (const asyncPrefix of ["", "async "]) {
				const returnType = asyncPrefix == "" ? "Result<uint64, TargetError>" : "Promise<Result<uint64, TargetError>>";
				const result = compileToCWithStd(errors + scope.declarations + `${asyncPrefix}function feed(): ${returnType} { ${body} } feed();`);
				assert result.ok == scope.accepted, asyncPrefix + body + scope.declarations;
			}
		}
	}
}

test "inferred and instantiated returns enforce their own settled error channel" {
	for (const target of ["SourceError", "TargetError"]) {
		const inferred = compileToCWithStd(errors + `function feed(fail: boolean) { if (fail) return Result.err(${target}.` + (target == "SourceError" ? "Missing" : "Dead") + `) as Result<uint64, ${target}>; const v = try load(); return Result.ok(v) as Result<uint64, ${target}>; } feed(false);`);
		const arrow = compileToCWithStd(errors + `const f = () => { const v = try load(); return Result.ok(v) as Result<uint64, ${target}>; }; f();`);
		const mismatchedCall = target == "SourceError" ? "" : "feed<TargetError>(TargetError.Dead);";
		const generic = compileToCWithStd(errors + "function feed<E>(fallback: E): Result<uint64, E> { const v = try load(); return Result.ok(v); } feed<SourceError>(SourceError.Missing);" + mismatchedCall);
		assert inferred.ok == (target == "SourceError"), "inferred " + target;
		assert arrow.ok == (target == "SourceError"), "arrow " + target;
		assert generic.ok == (target == "SourceError"), "instance " + target;
	}
}

test "a local catch discharges propagation where no Result can be returned" {
	for (const fallback of ["", " catch 0"]) {
		const binding = `const v = try load()${fallback};`;
		const consumers = [
			`function plain(): int32 { ${binding} return v as int32; } plain();`,
			`function run() { ${binding} console.log(v); } run();`,
			`const f = () => { ${binding} console.log(v); }; f();`,
			binding + "console.log(v);",
		];
		for (const consumer of consumers) {
			const result = compileToCWithStd(errors + consumer);
			assert result.ok == (fallback != ""), consumer;
		}
	}
}
