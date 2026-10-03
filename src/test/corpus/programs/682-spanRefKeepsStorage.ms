// @stdout: refs 11 99 33 44 | 11 22 99 44 | 1 77 3 | 5 99 7 | true false 6
struct Item { value: uint32; }

function put(ref value: uint8): void { value = 99; }
function forward(ref value: uint8): void { put(value); }
function write(view: Span<uint8>): void { forward(view[1]); }
function putItem(ref item: Item): void { item = { value: 77 }; }
function writeItems(view: Span<Item>): void { putItem(view[1]); }

function run(): void {
	let dynamic: uint8[] = [11, 22, 33, 44];
	write(dynamic);
	let fixed: uint8[4] = [11, 22, 33, 44];
	write(fixed[1..3]);
	let items: Item[] = [{ value: 1 }, { value: 2 }, { value: 3 }];
	writeItems(items);
	let sliced: uint8[] = [5, 6, 7];
	put(sliced[0..3][1]);
	const afterPut = sliced[1];
	const head = sliced[1..3] as Ptr<uint8>;
	const same = sliced[1..2] as Ptr<uint8>;
	const first = sliced[0..3] as Ptr<uint8>;
	head[] = head[] - 93;
	console.log(`refs ${dynamic[0]} ${dynamic[1]} ${dynamic[2]} ${dynamic[3]} | ${fixed[0]} ${fixed[1]} ${fixed[2]} ${fixed[3]} | ${items[0].value} ${items[1].value} ${items[2].value} | ${sliced[0]} ${afterPut} ${sliced[2]} | ${head == same} ${head == first} ${sliced[1]}`);
}
run();
