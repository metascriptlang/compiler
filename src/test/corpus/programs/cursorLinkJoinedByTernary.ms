// @stdout: field=x|x|x elem=x|x|x arg=x|x|x
class S { name: string; kids: S[]; }
class N { sym: Cursor<S>; callee: N | null; links: Cursor<S>[]; }

function same(s: S): S { return s; }

function viaField(call: N, i: int32): string {
	const set = i < 0 ? null : i < 1 ? call.sym : call.sym;
	if (set == null) return "";
	const hook = i > 0 ? set.kids[0] : set;
	return hook.name;
}

function viaElement(call: N, i: int32): string {
	const set = i < 0 ? null : i < 1 ? call.links[0] : call.links[0];
	if (set == null) return "";
	const hook = i > 0 ? set.kids[0] : set;
	return hook.name;
}

function viaArgument(call: N, i: int32): string {
	const set = i < 0 ? null : i < 1 ? call.sym : call.sym;
	if (set == null) return "";
	const hook = i > 0 ? set.kids[0] : same(set);
	return hook.name;
}

const owner: S = { name: "x", kids: [] };
const inner: N = { sym: owner, callee: null, links: [owner] };
const n: N = { sym: owner, callee: inner, links: [owner] };

function repeat(run: (call: N, i: int32) => string): string {
	return run(n, 0) + "|" + run(n, 0) + "|" + owner.name;
}

console.log(`field=${repeat(viaField)} elem=${repeat(viaElement)} arg=${repeat(viaArgument)}`);
