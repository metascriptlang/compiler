// @stdout: 4 true 3 5 7 true
// note: a generic call whose T is bound to a value-type X | null by one argument takes a bare X from another argument to the same parameter, inferred and explicit, for a struct, a primitive and a function payload, with the null argument first or last.

struct TokenId { index: int32; }
function put<T>(ref arr: T[], v: T): void { arr.push(v); }
function id<T>(v: T): T { return v; }
function pick<T>(a: T, b: T): T { return a !== null ? a : b; }

const values: (TokenId | null)[] = [];
put(values, null);
put(values, { index: 3 });
const tok: TokenId = { index: 5 };
put(values, tok);
put(values, null);

const nums: (int32 | null)[] = [];
put(nums, 7);
put(nums, null);

const fns: ((() => int32) | null)[] = [];
const f = (): int32 => 9;
put(fns, f);
put(fns, null);

const explicit = id<TokenId | null>({ index: 5 });
const none = id<TokenId | null>(null);
const picked: int32 | null = pick(nums[1], 7 as int32);
const second = values[1];
console.log(`${values.length} ${values[0] === null} ${second !== null ? second.index : -1} ${explicit !== null ? explicit.index : -1} ${picked !== null ? picked : -1} ${none === null && fns[1] === null}`);
