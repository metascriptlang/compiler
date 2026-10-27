// @xfail(raiser): error: Undefined variable 'Buffer'
// @stdout: 4 4 4 e2.82.ac.41
// @stdout: 0 0
// note: a Buffer is uint8[] on every target, so its length counts bytes even when they are not ASCII or not UTF-8, as node's Buffer.length does; expected lines come from node.

const bytes = Buffer.fromArray([0xE2, 0x82, 0xAC, 0x41]);
const text = Buffer.fromString("€A", "utf8");
let hex = "";
for (let i = 0; i < bytes.length; i++) hex += bytes.byteAt(i).toString(16) + ".";
console.log(`${bytes.length} ${text.length} ${Buffer.fromArray([0xFF, 0xC3, 0x80, 0xED]).length} ${hex.slice(0, hex.length - 1)}`);
console.log(`${Buffer.alloc(0).length} ${Buffer.fromString("", "utf8").length}`);
