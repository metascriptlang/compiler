// @stdout: m s s m | s m | mm ss | ms sm
type Meters = distinct float64;
type Seconds = distinct float64;

function unit(this m: Meters): string { return "m"; }
function unit(this s: Seconds): string { return "s"; }

function show<T>(x: T): string { return x.unit(); }
function showOther<T>(x: T): string { return x.unit(); }
function both<T>(xs: T[]): string { return xs[0].unit() + xs[1].unit(); }
function pair<A, B>(x: A, y: B): string { return x.unit() + y.unit(); }

const a = 3.0 as Meters;
const b = 4.0 as Seconds;
const direct = `${a.unit()} ${b.unit()} ${show(b)} ${show(a)}`;
const flipped = `${showOther(b)} ${showOther(a)}`;
const nested = `${both([a, a])} ${both([b, b])}`;
const twoArgs = `${pair(a, b)} ${pair(b, a)}`;
console.log(`${direct} | ${flipped} | ${nested} | ${twoArgs}`);
