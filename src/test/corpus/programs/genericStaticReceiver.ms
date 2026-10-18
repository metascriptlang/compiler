// @stdout: 2 1 true 5
// note: a static extension or static method called through a type parameter binds to the declaration the argument names, in both generic instances.
struct StaticPet { a: uint8; }
struct StaticBlock { b: uint8; }
enum StaticKind { Plain, Fancy }
class StaticTag { static tag(): int32 { return 5; } }

function accountKind(this typeof StaticPet): uint8 { return 2; }
function accountKind(this typeof StaticBlock): uint8 { return 1; }
function first(this typeof StaticKind): StaticKind { return StaticKind.Fancy; }
function kindOf<T>(): uint8 { return T.accountKind(); }
function firstOf<T>(): T { return T.first(); }
function tagOf<T>(): int32 { return T.tag(); }

console.log(`${kindOf<StaticPet>()} ${kindOf<StaticBlock>()} ${firstOf<StaticKind>() == StaticKind.Fancy} ${tagOf<StaticTag>()}`);
