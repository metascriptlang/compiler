// @stdout: 2 1 box=7 local=3 label=hi
class Box { v: int32; constructor(v: int32) { this.v = v; } }

class Holder {
	static items: int32[] = [1, 2];
	static replaced: int32[] = [1, 2, 3];
	static box: Box = new Box(7);
	static label: string = "hi";
}

export class Exported {
	static rows: int32[][] = [[1], [2, 3]];
}

function localCount(): int32 {
	class Local { static parts: Box[] = [new Box(1), new Box(2), new Box(3)]; }
	return Local.parts.length;
}

Holder.replaced = [4];
console.log(`${Holder.items.length} ${Holder.replaced.length} box=${Holder.box.v} local=${localCount()} label=${Holder.label}`);
