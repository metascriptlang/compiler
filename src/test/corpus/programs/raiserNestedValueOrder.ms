// @stdout: argOrder=g,a,x!1 | guardOff=- | guardOn=a,true | ternOff=z | ternOn=a,x! | andCall=- | andCallOn=m | classArg=g,ab,6 | classTern=ab,5 | maybeNum=g,n,3
class Box { v: int32 = 5; }
let trace = "";
function note(tag: string): void { trace = trace == "" ? tag : trace + "," + tag; }
function g(): int32 { note("g"); return 1; }
function a(on: boolean): string | null { note("a"); return on ? "x!" : null; }
function ab(on: boolean): Box | null { note("ab"); return on ? new Box() : null; }
function n(on: boolean): int32 | null { note("n"); return on ? 2 : null; }
function m(): boolean { note("m"); return true; }
function join(i: int32, s: string): string { return s + i; }
function boxSum(i: int32, b: Box): int32 { return b.v + i; }
function take(): string { const out = trace == "" ? "-" : trace; trace = ""; return out; }

const argOrder = join(g(), a(true) ?? "d");
const argTrace = take();
const guardOff = false && (a(true) ?? "d") == "d";
const guardOffTrace = take();
const guardOn = true && (a(true) ?? "d") != "d";
const guardOnTrace = take();
const tf = false;
const tt = true;
const ternOff = tf ? (a(true) ?? "d") : "z";
const ternOffTrace = take();
const ternOn = tt ? (a(true) ?? "d") : "z";
const ternOnTrace = take();
const andCall = tf && join(1, a(true) ?? "d") == "q";
const andCallTrace = take();
const andCallOn = tt && m() && join(1, "r") != "q";
const andCallOnTrace = take();
const classArg = boxSum(g(), ab(true) ?? new Box());
const classArgTrace = take();
const classTern = tt ? (ab(true) ?? new Box()).v : 0;
const classTernTrace = take();
const maybeNum = g() + (n(false) ?? 2);
const maybeNumTrace = take();

console.log(`argOrder=${argTrace},${argOrder} | guardOff=${guardOffTrace} | guardOn=${guardOnTrace},${guardOn} | ternOff=${ternOff} | ternOn=${ternOnTrace},${ternOn} | andCall=${andCallTrace} | andCallOn=${andCallOnTrace} | classArg=${classArgTrace},${classArg} | classTern=${classTernTrace},${classTern} | maybeNum=${maybeNumTrace},${maybeNum}`);
