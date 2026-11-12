import { getOwner } from "./runtime";

export function onCleanup(fn: () => void): () => void {
	const owner = getOwner();
	if (owner === null) { throw new Error("onCleanup called outside a reactive context will never be run"); }
	const list = owner.disposal;
	if (list === null) { owner.disposal = [fn]; } else { list.push(fn); }
	return fn;
}
