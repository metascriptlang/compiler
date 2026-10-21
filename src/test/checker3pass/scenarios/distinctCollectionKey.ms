import { checkOnly } from "../helpers";

test "a distinct key over a string, a float or a struct is refused where the collection is made" {
	const src = `
type Email = distinct string;
type Score = distinct number;
struct P { x: int32; }
type Q = distinct P;
type Raw = distinct float64;
type Alias = Raw;
type Again = distinct Alias;
function hash(this e: Email): int64 { return 0; }
const a = new Map<Email, int32>();
const b = new Set<Score>();
const c = new HashSet<Q>();
const d: HashMap<Again, int32> = new HashMap();
`;
	const text = checkOnly(src).errors.join("\n");
	assert text.contains("'Email' cannot be a Map key: a distinct type hashes as its base only over an integer, char, boolean or enum, and 'Email' is over 'string' — declare 'export function hash(this k: Email): int64'"), "a distinct string, even with a hash that is not exported: " + text;
	assert text.contains("'Score' cannot be a Set key"), "a distinct number: " + text;
	assert text.contains("'Q' cannot be a HashSet key"), "a distinct struct: " + text;
	assert text.contains("'Again' cannot be a HashMap key") && text.contains("is over 'float64'"), "a distinct over an alias of a distinct float: " + text;
}

test "a distinct string key is refused in a Map literal" {
	const src = `
type Email = distinct string;
const e: Map<Email, int32> = { "a@x": 1 };
`;
	const text = checkOnly(src).errors.join("\n");
	assert text.contains("'Email' cannot be a Map key"), "the literal: " + text;
}

test "a distinct string key is refused in a generic instance" {
	const src = `
type Email = distinct string;
function mk<K>(k: K): int32 { const m = new Map<K, int32>(); return m.size; }
const f = mk("b@x" as Email);
`;
	const text = checkOnly(src).errors.join("\n");
	assert text.contains("'Email' cannot be a Map key"), "the instance of mk: " + text;
}

test "a distinct key over an integer, char, boolean or enum, or with an exported hash, is accepted" {
	const src = `
type UserId = distinct int32;
type AdminId = distinct UserId;
type Flag = distinct boolean;
type Ch = distinct char;
enum Color { Red, Green }
type Tint = distinct Color;
type Score = distinct float64;
export function hash(this s: Score): int64 { return 0; }
const a = new Map<AdminId, string>();
const b = new Set<Flag>();
const c = new HashSet<Ch>();
const d = new HashMap<Tint, int32>();
const e = new Set<Score>();
`;
	const errors = checkOnly(src).errors;
	assert errors.length == 0, "every key here has a hash: " + errors.join("\n");
}
