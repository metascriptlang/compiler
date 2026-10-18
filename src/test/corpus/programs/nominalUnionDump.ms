// @stdout: {"shape":{"kind":"circle","radius":3}}
// @stdout: {"shape":{"kind":"square","side":4}}
interface Circle { kind: "circle"; radius: int32; }
interface Square { kind: "square"; side: int32; }
type Shape = Circle | Square;
interface Container { shape: Shape; }
const a: Circle = { kind: "circle", radius: 3 };
const b: Square = { kind: "square", side: 4 };
const ca: Container = { shape: a };
const cb: Container = { shape: b };
console.log(`${ca}`);
console.log(`${cb}`);
