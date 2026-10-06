// A @comptime block runs on the Raiser VM, which holds a struct as an object and
// has no bytes behind it. A byte view of a struct span is refused there exactly as
// it is on JS (NIM-REF CK-134), and the diagnostic names the block it came from.
//
// A red guard means the VM went back to reading the element object as the byte:
// the block folds `{ a: 258 }`'s first byte to 1 instead of failing.
//
// GUARD-CHECK-FAIL @comptime block:
// GUARD-CHECK-FAIL cannot convert Ptr<void> to Ptr<uint8> on the Raiser VM

struct Pet { a: uint32; b: uint8; }

function firstByte(view: Span<Pet>): uint8 {
	const bytes = view as Ptr<void> as Ptr<uint8>;
	return bytes[0];
}

const FIRST: number = @comptime {
	const pets: Pet[] = [{ a: 258, b: 9 }];
	return firstByte(pets) as number;
};

function main(): int32 {
	console.log(`${FIRST}`);
	return 0;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
