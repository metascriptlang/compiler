import { TypeKind } from "../../../std/meta/node";
import {
	createArray, createGenericInstance, createGenericParam, createStruct, hasGenericParams,
	instantiateGenericBody, numberType, setConcurrentTypeQueries, substituteParams,
} from "../../checker/types";

class QueryResult {
	ok: boolean;
	checks: int32;
	constructor(ok: boolean, checks: int32) {
		this.ok = ok;
		this.checks = checks;
	}
}

const sharedT = createGenericParam("T");
const shared = createStruct("SharedRecursive", ["value"], [sharedT], false);
const box = createStruct("Box", ["value"], [createGenericParam("T")], false);
const holderT = createGenericParam("T");
const holder = createStruct("Holder", ["box"], [createGenericInstance(box, [holderT])], false);

function query(rounds: int32): QueryResult {
	let checks = 0;
	let i = 0;
	while (i < rounds) {
		if (!hasGenericParams(shared)) return new QueryResult(false, checks);
		const all = substituteParams(shared, [sharedT], [numberType()]);
		if (all.kind != TypeKind.Struct || all.typeChildren[0].kind != TypeKind.Number) return new QueryResult(false, checks);
		const fresh = createGenericInstance(box, [numberType()]);
		instantiateGenericBody(fresh, "T");
		if (fresh.typeReturn == null || fresh.typeReturn.typeChildren[0].kind != TypeKind.Number) return new QueryResult(false, checks);
		const held = substituteParams(holder, [holderT], [numberType()]);
		if (held.kind != TypeKind.Struct || held.typeChildren[0].kind != TypeKind.GenericInstance) return new QueryResult(false, checks);
		checks = checks + 4;
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
	if (checks != 16000) throw "shared type query count";
	console.log("GUARD-OK");
}

main();
