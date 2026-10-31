// @xfail(raiser): error: Undefined variable 'Buffer'
// @stdout: héllo|a�b|hélloa�b
// @stdout: {"b":{"type":"Buffer","data":[97,255,98]}}
// @stdout: <Buffer 61 ff 62>
// @stdout: { b: <Buffer 00 00> }
// @stdout: él|a�b
const fromText = Buffer.fromString("héllo", "utf8");
const fromBytes = Buffer.fromArray([0x61, 0xff, 0x62]);
const joined = Buffer.concat(fromText, fromBytes);
console.log(`${fromText}|${String(fromBytes)}|${"" + joined}`);
console.log(JSON.stringify({ b: fromBytes }));
console.log(fromBytes, { b: Buffer.alloc(2) });
console.log(`${joined.slice(1, 4)}|${joined.slice(6)}`);
