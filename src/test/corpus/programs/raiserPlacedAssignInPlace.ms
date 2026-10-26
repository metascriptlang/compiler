// @stdout: 4
// @stdout: 7
// @stdout: 9
struct Cell { id: int32; }
class Holder { cell: Cell = { id: 1 }; }

function run(): void {
	let local: Cell = { id: 1 };
	const viaPointer = local as Ptr<Cell>;
	local = { id: 4 };
	console.log(viaPointer.id);

	const holder = new Holder();
	const viaField = holder.cell as Ptr<Cell>;
	holder.cell = { id: 7 };
	console.log(viaField.id);

	let target: Ref<Cell> = { id: 2 };
	const alias = target;
	target[] = { id: 9 };
	console.log(alias.id);
}

run();
