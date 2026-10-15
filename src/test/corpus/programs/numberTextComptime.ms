// @stdout: number text comptime 31 5 ff.8 -2 1000 NaN 9007199254740993 -101-1
// note: Number(string), parseInt, parseFloat, Math.round and toString(radix) give the TS answers inside @comptime too, where they run on the Raiser.

const hex = @comptime { return "0x1F".parseInt(); };
const binary = @comptime { return Number(" 0b101 "); };
const radix = @comptime { return (255.5).toString(16); };
const tie = @comptime { return Math.round(-2.5); };
const prefix = @comptime { return "1e3x".parseFloat(); };
const bare = @comptime { return Number("0x"); };
const exact = @comptime { return "9007199254740993".parseInt(); };
const neg = @comptime { return (-5.0).toString(2) + (-1).toString(2); };
console.log(`number text comptime ${hex} ${binary} ${radix} ${tie} ${prefix} ${bare} ${exact} ${neg}`);
