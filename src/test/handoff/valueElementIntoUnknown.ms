import { strictErrorCount } from "./helpers";

const DECL = "struct Report { tx: int64; }\nclass Box { n: int32 = 1; }\nfunction made(): Result<Report | null, string> { return Result.ok({ tx: 7 }); }\nfunction counted(): Result<number, string> { return Result.ok(3); }\nfunction boxed(): Result<Box, string> { return Result.ok(new Box()); }\nfunction shown(r: Result<unknown, string>): boolean { return r.ok; }\n";

test "valueElementIntoUnknown: a Result whose payload is a value is refused where Result<unknown> is declared, at a return, an argument and a declaration" {
	const refused = [
		{ name: "a return of a nullable struct payload", source: DECL + "function wrapped(): Result<unknown, string> { return made(); }" },
		{ name: "an argument of a number payload", source: DECL + "const b = shown(counted());" },
		{ name: "a declaration of a nullable struct payload", source: DECL + "const r: Result<unknown, string> = made();" },
		{ name: "an array of numbers into unknown[]", source: DECL + "const xs: number[] = [1];\nconst ys: unknown[] = xs;" },
	];
	for (const row of refused) {
		assert strictErrorCount(row.source) > 0, row.name;
	}
}

test "valueElementIntoUnknown: a Result whose payload is a class instance still fits Result<unknown>" {
	const accepted = [
		{ name: "an argument", source: DECL + "const b = shown(boxed());" },
		{ name: "a return", source: DECL + "function wrapped(): Result<unknown, string> { return boxed(); }" },
	];
	for (const row of accepted) {
		assert strictErrorCount(row.source) == 0, row.name;
	}
}
