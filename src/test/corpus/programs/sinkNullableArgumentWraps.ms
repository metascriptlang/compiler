// @stdout: fn 2 true 5 | st 2 true 7 | vec 1 true | int 2 true 5 | str 2 true a | map 2 true 6
// @exit: 0
// note: an argument to a `sink` parameter whose type is a Maybe-carried `T | null` gets the `T -> Maybe<T>` wrap, as it does for a plain parameter; Array.push and the JS Map.set extern both declare `sink`.

struct TokenId { index: int32; }

const fns: (((n: number) => void) | null)[] = [];
fns.push(null);
let seen = 0;
fns.push((n: number) => { seen = n as int32; });
const fn = fns[1];
if (fn !== null) fn(5);

const tokens: (TokenId | null)[] = [];
tokens.push(null);
tokens.push({ index: 7 });
const token = tokens[1];

let vec: Vec<TokenId | null> = [];
vec.push(null);

const ints: (int32 | null)[] = [];
ints.push(null);
ints.push(5);
const int = ints[1];

const strs: (string | null)[] = [];
strs.push(null);
strs.push("a");
const str = strs[1];

const map = new Map<string, TokenId | null>();
map.set("a", null);
map.set("b", { index: 6 });
const entry = map.get("b");
const mapped = entry != null ? entry : null;

console.log(`fn ${fns.length} ${fns[0] === null} ${seen} | st ${tokens.length} ${tokens[0] === null} ${token !== null ? token.index : -1} | vec ${vec.length} ${vec[0] === null} | int ${ints.length} ${ints[0] === null} ${int !== null ? int : -1} | str ${strs.length} ${strs[0] === null} ${str !== null ? str : "none"} | map ${map.size} ${map.get("a") === null} ${mapped !== null ? mapped.index : -1}`);
