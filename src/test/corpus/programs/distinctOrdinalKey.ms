// Parity program — a distinct type over an integer, char, boolean or enum keys a Map, Set or
// HashSet with its base's hash, through any depth of distinct; a distinct over another base keys
// one once it declares an exported hash. Equality is not inherited: each key delegates an
// exported `==`, the one the collection's generic code can see.
//
// @stdout: user=a,1 admin=1,1,true,1,1 flag=1,1 ch=1,1 big=1,1 tint=1,-1,1 score=2,true,false
// @exit: 0

type UserId = distinct int32;
type AdminId = distinct UserId;
type Flag = distinct boolean;
type Ch = distinct char;
type Big = distinct int64;
enum Color { Red, Green }
type Tint = distinct Color;
type Score = distinct float64;

@delegate export function `==`(this a: UserId, b: UserId): boolean;
@delegate export function `==`(this a: AdminId, b: AdminId): boolean;
@delegate export function `==`(this a: Flag, b: Flag): boolean;
@delegate export function `==`(this a: Ch, b: Ch): boolean;
@delegate export function `==`(this a: Big, b: Big): boolean;
@delegate export function `==`(this a: Tint, b: Tint): boolean;
@delegate export function `==`(this a: Score, b: Score): boolean;

export function hash(this s: Score): int64 { return Math.floor(s as float64) as int64; }

const users = new Map<UserId, string>();
users.set(1 as UserId, "a");

const k1: AdminId = (1 as UserId) as AdminId;
const k2: AdminId = (1 as UserId) as AdminId;
const admins = new Map<AdminId, int32>();
admins.set(k1, 1);
const adminSet = new HashSet<AdminId>();
adminSet.add(k1);
adminSet.add(k2);

const flags = new Set<Flag>();
flags.add(true as Flag);
flags.add(true as Flag);
const byFlag = new Map<Flag, int32>();
byFlag.set(true as Flag, 1);

const chars = new HashSet<Ch>();
chars.add((65 as char) as Ch);
chars.add((65 as char) as Ch);
const byCh = new Map<Ch, int32>();
byCh.set((65 as char) as Ch, 1);

const bigs = new Set<Big>();
bigs.add((5 as int64) as Big);
bigs.add((5 as int64) as Big);
const byBig = new HashMap<Big, int32>();
byBig.set((5 as int64) as Big, 1);

const tints = new Map<Tint, int32>();
tints.set(Color.Green as Tint, 1);

const scores = new Set<Score>();
scores.add(1.5 as Score);
scores.add(1.5 as Score);
scores.add(1.25 as Score);

console.log(`user=${users.get(1 as UserId) ?? "none"},${users.size} admin=${admins.get(k1) ?? -1},${admins.get(k2) ?? -1},${admins.has(k2)},${admins.size},${adminSet.size} flag=${flags.size},${byFlag.get(true as Flag) ?? -1} ch=${chars.size},${byCh.get((65 as char) as Ch) ?? -1} big=${bigs.size},${byBig.get((5 as int64) as Big) ?? -1} tint=${tints.get(Color.Green as Tint) ?? -1},${tints.get(Color.Red as Tint) ?? -1},${tints.size} score=${scores.size},${scores.has(1.25 as Score)},${scores.has(2.5 as Score)}`);
