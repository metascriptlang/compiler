// @stdout: view=1,1,1 mutable=1,1,1 two=2,2,2 same=true,true,false first=3,4
// note: a generic `Readonly<T | null>` binds T from a nullable of a view and from a nullable of the mutable value, for a struct carrying a Vec, a plain struct and a class, and `Readonly<T | U | null>` binds both parameters, as `Readonly<T>` alone binds T to the argument's own type.

struct Skin { joints: Vec<int32>; }
struct Plain { n: int32; }
class Cls { n: int32 = 3; }

function seen<T>(x: Readonly<T | null>): int32 { return x == null ? -1 : 1; }
function either<T, U>(x: Readonly<T | U | null>): int32 { return x == null ? -1 : 2; }
function agree<T>(a: Readonly<T | null>, b: Readonly<T | null>): boolean { return a == b; }
function whole<T>(x: Readonly<T>): int32 { return 1; }
function firstOf<T>(xs: Readonly<T[]>): Readonly<T | null> { return xs.length > 0 ? xs[0] : null; }

const skinView: Readonly<Skin | null> = { joints: [1] };
const skin: Skin | null = { joints: [1] };
const plain: Plain | null = { n: 1 };
const cls: Cls | null = new Cls();
const clsView: Readonly<Cls | null> = cls;
const others: Skin | null = { joints: [2] };
const nums: Plain[] = [{ n: 3 }];
const picked = firstOf(nums);

const view = [seen(skinView), seen(clsView), seen(plain)];
const mutable = [seen(skin), seen(plain), seen(cls)];
const two = [either(skinView), either(plain), either(cls)];
const same = [agree(skinView, skin), agree(cls, cls), agree(skin, others)];
console.log(`view=${view.join(",")} mutable=${mutable.join(",")} two=${two.join(",")} same=${same.join(",")} first=${picked != null ? picked.n : -1},${whole(nums[0]) + 3}`);
