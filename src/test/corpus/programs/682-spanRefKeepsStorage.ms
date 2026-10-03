// @stdout: refs 11 99 33 44 | 11 22 99 44 | 1 77 3
// @xfail(raiser): scalar ref writes are unsupported by the Raiser VM
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
	console.log(`refs ${dynamic[0]} ${dynamic[1]} ${dynamic[2]} ${dynamic[3]} | ${fixed[0]} ${fixed[1]} ${fixed[2]} ${fixed[3]} | ${items[0].value} ${items[1].value} ${items[2].value}`);
}
run();
