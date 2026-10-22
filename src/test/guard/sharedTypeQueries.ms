import { Type } from "../../../std/meta/node";
import {
	createArray, createGenericInstance, createGenericParam, createStruct, hasGenericParams,
	instantiateGenericBody, numberType, setConcurrentTypeQueries, substituteParams,
	typeDisplayNameUnprofiled, typeNameOfUnprofiled,
} from "../../checker/types";

interface SharedGraph {
	recursive: Type;
	instance: Type;
	held: Type;
	fresh: Type;
}

function buildGraph(): SharedGraph {
	const recursiveT = createGenericParam("T");
	const recursive = createStruct("SharedRecursive", ["value"], [recursiveT], false);
	recursive.typeNames.push("next");
	recursive.typeChildren.push(createArray(recursive));
	const box = createStruct("Box", ["value"], [createGenericParam("T")], false);
	const holderT = createGenericParam("T");
	const holder = createStruct("Holder", ["box"], [createGenericInstance(box, [holderT])], false);
	const fresh = createGenericInstance(box, [numberType()]);
	instantiateGenericBody(fresh, "T");
	return {
		recursive: recursive,
		instance: substituteParams(recursive, [recursiveT], [numberType()]),
		held: substituteParams(holder, [holderT], [numberType()]),
		fresh: fresh,
	};
}

function answers(graph: Readonly<SharedGraph>): string {
	const parts: string[] = [];
	for (const t of [graph.recursive, graph.instance, graph.held, graph.fresh]) {
		parts.push(`${hasGenericParams(t)}:${typeNameOfUnprofiled(t)}:${typeDisplayNameUnprofiled(t)}`);
		for (const child of t.typeChildren) parts.push(typeDisplayNameUnprofiled(child));
	}
	return parts.join("|");
}

function query(graph: Readonly<SharedGraph>, expected: string, rounds: int32): int32 {
	let i = 0;
	while (i < rounds) {
		if (answers(graph) != expected) return -1;
		i += 1;
	}
	return rounds;
}

function main(): void {
	const graph = buildGraph();
	const expected = answers(graph);
	if (!expected.startsWith("true:")) throw `shared type graph lost its generic parameter: ${expected}`;
	setConcurrentTypeQueries(true);
	const futures: Promise<int32>[] = [];
	let i = 0;
	while (i < 8) {
		futures.push(spawn(() => query(graph, expected, 500)));
		i += 1;
	}
	let rounds = 0;
	for (const future of futures) {
		const done = await future;
		if (done < 0) throw "shared type query mismatch";
		rounds += done;
	}
	setConcurrentTypeQueries(false);
	if (rounds != 4000) throw "shared type query count";
	console.log("GUARD-OK");
}

main();
