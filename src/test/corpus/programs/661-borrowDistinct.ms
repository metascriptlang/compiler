// @stdout: key=42/42/42 dot=21/3/maker/5 generic=42/42 fields=21/5 ref=8 copy=5/5
// note: a function or a distinct type marked @delegate takes its base's implementation: a delegated method runs the base function through method and call syntax, delegated field access reads and writes the base's fields on a copy of the value, generic delegation and delegation through a distinct of a distinct reach the same base, a ref receiver delegates to a ref base; a distinct value stored or pushed is a copy of its base. Same output on every backend.

struct Account { address: uint64; lamports: uint64; name: string; }
function key(this a: Account): uint64 { return a.address * 2; }
function bump(this ref a: Account, by: uint64): void { a.lamports += by; }

type Signer = distinct Account;
@delegate function key(this s: Signer): uint64;
@delegate function bump(this ref s: Signer, by: uint64): void;

@delegate type Payer = distinct Account;

type Owned<T> = distinct Account;
type Mutable<T> = distinct Owned<T>;
@delegate function key<T>(this o: Owned<T>): uint64;
@delegate function key<T>(this m: Mutable<T>): uint64;

@delegate type Shared<T> = distinct Account;
@delegate type Exclusive<T> = distinct Shared<T>;

struct Vault { amount: uint64; }

let base: Account = { address: 21, lamports: 5, name: "maker" };
const signer = base as Signer;
let payer = base as Payer;
payer.lamports = 3;
const owned = base as Owned<Vault>;
const mutable = owned as Mutable<Vault>;
const exclusive = (base as Shared<Vault>) as Exclusive<Vault>;
let bumped = base as Signer;
bumped.bump(3);
const kept = base as Signer;
const signers: Signer[] = [];
signers.push(kept);
base.lamports = 7;

console.log("key=" + signer.key() + "/" + key(signer) + "/" + base.key()
	+ " dot=" + payer.address + "/" + payer.lamports + "/" + payer.name + "/" + (signer as Account).lamports
	+ " generic=" + owned.key() + "/" + mutable.key()
	+ " fields=" + exclusive.address + "/" + exclusive.lamports
	+ " ref=" + (bumped as Account).lamports
	+ " copy=" + (kept as Account).lamports + "/" + (signers[0] as Account).lamports);
