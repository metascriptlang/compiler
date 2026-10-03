// @stdout: pointers 11 55 99 44 | 9 11 4 5 | true | 2
struct Pet { a: uint32; b: uint8; }
struct Holder { ptr: Ptr<Pet>; }
function setByte(ref value: uint8): void { value = 99; }
function setPet(p: Ptr<Pet>): void { p[].a = 9; }
function ptrOf(view: Span<Pet>): Ptr<Pet> { return view as Ptr<Pet>; }
function identity<T>(p: Ptr<T>): Ptr<T> { return p; }
function source(values: Pet[], ref calls: int32): Pet[] { calls += 1; return values; }
function pointer(values: Pet[], ref calls: int32): Ptr<Pet> { calls += 1; return values[1] as Ptr<Pet>; }

function run(): void {
	let bytes: uint8[] = [11, 22, 33, 44];
	const byteView: Span<uint8> = bytes[1..4];
	const bp = byteView as Ptr<uint8>;
	bp[] = 55;
	setByte(byteView[1]);

	let pets: Pet[] = [{ a: 1, b: 2 }, { a: 3, b: 4 }, { a: 5, b: 6 }];
	setPet(ptrOf(pets));
	let calls: int32 = 0;
	const holder: Holder = { ptr: identity(pointer(pets, calls)) };
	holder.ptr[].a = 11;
	const direct = pets[1] as Ptr<Pet>;
	const measured = (source(pets, calls)[2..3] as Span<Pet>) as Ptr<Pet>;
	measured[0].a = 5;
	console.log(`pointers ${bytes[0]} ${bytes[1]} ${bytes[2]} ${bytes[3]} | ${pets[0].a} ${pets[1].a} ${pets[1].b} ${pets[2].a} | ${holder.ptr == direct} | ${calls}`);
}
run();
