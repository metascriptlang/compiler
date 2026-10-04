// @stdout: true 70000 70001 true
// note: an enum crosses the 64-bit boundary as an int32 on JS, where int64 is a BigInt: an int64 converted into an enum compares equal to its member, and an enum converted into int64 takes part in int64 arithmetic (JS threw "Cannot mix BigInt and other types" and compared false).

enum Port { Low = 256, High = 70000 }

function opaque(x: int64): int64 { return x; }
function pick(b: boolean): Port { return b ? Port.High : Port.Low; }

const p = opaque(256) as Port;
const w = pick(true) as int64;
const sum = w + opaque(1);
const back = (sum - opaque(1)) as Port;
console.log(`${p == Port.Low} ${w} ${sum} ${back == Port.High}`);
