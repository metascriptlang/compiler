// A spread whose operand is an element read keeps value semantics when a call
// earlier in the same statement stops the operand being hoisted: the copy owns
// its nested struct and fixed array, so a later slot store cannot write into
// the source.

struct Key { bytes: uint8[4]; }
struct Acct { key: Key; signer: boolean; data: uint8[]; lamports: uint64; }
struct Pair { acct: Acct; tag: int32; }

function keyOf(n: uint8): Key { return { bytes: [n, 0, 0, 0] }; }
function account(key: Key): Acct { return { key: key, signer: false, data: [], lamports: 10 }; }
function wallet(key: Key): Acct { return { ...account(key), signer: true }; }
function take(made: Acct[]): Acct[] { return [wallet(keyOf(3)), { ...made[0], signer: false }]; }
function arg(a: Acct[], b: Acct[]): number { return a.length + b.length; }
function viaArg(made: Acct[]): Acct[] {
	const out: Acct[] = [];
	arg([wallet(keyOf(4))], out);
	out.push({ ...made[0], lamports: 1 });
	return out;
}
function nested(made: Acct[]): Pair[] { return [{ acct: wallet(keyOf(5)), tag: 1 }, { acct: { ...made[0], signer: false }, tag: 2 }]; }
function fixed(made: Key[]): Key[] { return [keyOf(6), { ...made[0] }]; }

const made: Acct[] = [wallet(keyOf(1))];
const pre = take(made);
pre[1] = { ...wallet(keyOf(9)), signer: false };
console.log(`made ${made[0].key.bytes[0]} pre ${pre[1].key.bytes[0]}`);

const viaCall = viaArg(made);
viaCall[0] = { ...wallet(keyOf(8)), signer: false };
console.log(`made ${made[0].key.bytes[0]} arg ${viaCall[0].key.bytes[0]}`);

const pairs = nested(made);
pairs[1] = { acct: wallet(keyOf(7)), tag: 3 };
console.log(`made ${made[0].key.bytes[0]} pair ${pairs[1].acct.key.bytes[0]}`);

const keys: Key[] = [keyOf(2)];
const copies = fixed(keys);
copies[1] = keyOf(11);
console.log(`keys ${keys[0].bytes[0]} copies ${copies[1].bytes[0]}`);

let reads = 0;
function slot(): int32 { reads += 1; return 0; }
function impure(made: Acct[]): Acct[] { return [wallet(keyOf(12)), { ...made[slot()], signer: false }]; }
const imp = impure(made);
imp[1] = { ...wallet(keyOf(13)), signer: false };
console.log(`made ${made[0].key.bytes[0]} impure ${imp[1].key.bytes[0]} reads ${reads}`);
