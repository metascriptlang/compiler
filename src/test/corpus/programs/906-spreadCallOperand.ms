// @stdout: call=3 3|member=2|index=0 3|all=4 2|guard=0 1|mixed=4 4
// @xfail(raiser): the Raiser VM stops with 'array index out of bounds: 0 (length 0)' on a spread call operand
function arr(): int32[] { return [1, 2, 3]; }
let reads: int32 = 0;
function counted(xs: int32[]): int32[] { reads = reads + 1; return xs; }
function firstItems(groups: int32[][]): int32[] {
	const r: int32[] = groups.length > 0 ? [...groups[0], 9] : [];
	return r;
}
function guarded(xs: int32[]): int32 {
	reads = 0;
	const empty = xs.length == 0;
	const ok: boolean = empty || [...counted(xs), 1].length > 1;
	return ok ? reads : -1;
}
function run(): void {
	const s1 = [...(arr())];
	const s2 = [...arr()];
	const t: int32[] = [1, 2, 3];
	const m: int32[] = [...t.slice(1, 3)];
	const base = arr();
	const all = [...arr(), ...base];
	const mixed = [...arr(), 4];
	console.log("call=" + s1.length.toString() + " " + s2.length.toString()
		+ "|member=" + m.length.toString()
		+ "|index=" + firstItems([]).length.toString() + " " + firstItems([[1, 2]]).length.toString()
		+ "|all=" + (all.length - 2).toString() + " " + all[4].toString()
		+ "|guard=" + guarded([]).toString() + " " + guarded([2]).toString()
		+ "|mixed=" + mixed.length.toString() + " " + mixed[3].toString());
}
run();
