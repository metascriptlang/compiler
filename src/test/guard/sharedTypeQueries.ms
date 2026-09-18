import { TypeKind } from "../../../std/meta/node";
import {
	createArray, createGenericParam, createStruct, hasGenericParams,
	numberType, setConcurrentTypeQueries, substituteAllParams, substituteType,
} from "../../checker/types";

class QueryResult {
	ok: boolean;
	checks: int32;
	constructor(ok: boolean, checks: int32) {
		this.ok = ok;
		this.checks = checks;
	}
}

const shared = createStruct("SharedRecursive", ["value"], [createGenericParam("T")], false);

function query(rounds: int32): QueryResult {
	let checks = 0;
	let i = 0;
	while (i < rounds) {
		if (!hasGenericParams(shared)) return new QueryResult(false, checks);
		const one = substituteType(shared, "T", numberType());
		if (one.kind != TypeKind.Struct || one.typeChildren[0].kind != TypeKind.Number) return new QueryResult(false, checks);
		const all = substituteAllParams(shared, ["T"], [numberType()]);
		if (all.kind != TypeKind.Struct || all.typeChildren[0].kind != TypeKind.Number) return new QueryResult(false, checks);
		checks = checks + 3;
		i = i + 1;
	}
	return new QueryResult(true, checks);
}

function main(): void {
	shared.typeNames.push("next");
	shared.typeChildren.push(createArray(shared));
	setConcurrentTypeQueries(true);
	const futures: Promise<QueryResult>[] = [];
	let i = 0;
	while (i < 8) {
		futures.push(spawn(() => query(500)));
		i = i + 1;
	}
	let checks = 0;
	for (const future of futures) {
		const result = await future;
		if (!result.ok) throw "shared type query mismatch";
		checks = checks + result.checks;
	}
	if (checks != 12000) throw "shared type query count";
	console.log("GUARD-OK");
}

main();
