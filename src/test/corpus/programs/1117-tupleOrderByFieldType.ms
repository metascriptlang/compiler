// @xfail(raiser): cannot compile node kind BigIntLiteral at comptime (inbox 2026-10-09-raiser-bigint-literal-at-comptime-in-1117)
// @stdout: last=true,false first=true,false le=true gt=true ge=false nested=false,true deep=true,false big=false,true
// note: tuple `<`, `<=`, `>`, `>=` walk the fields in order and compare each by its own type: a string by its text, a bigint by its value, a nested tuple by its own ordering. Same output on every backend.

function lastIsText(x: [int32, string], y: [int32, string]): boolean { return x < y; }
function firstIsText(x: [string, int32], y: [string, int32]): boolean { return x < y; }
function atMost(x: [int32, string], y: [int32, string]): boolean { return x <= y; }
function above(x: [int32, string], y: [int32, string]): boolean { return x > y; }
function atLeast(x: [int32, string], y: [int32, string]): boolean { return x >= y; }
function nested(x: [[int32, string], int32], y: [[int32, string], int32]): boolean { return x < y; }
function deep(x: [int32, [string, [int32, string]]], y: [int32, [string, [int32, string]]]): boolean { return x <= y; }
function byBig(x: [bigint, int32], y: [bigint, int32]): boolean { return x < y; }

const large: bigint = 100n;
const small: bigint = 99n;
const last = `${lastIsText([1, "a"], [1, "b"])},${lastIsText([1, "b"], [1, "a"])}`;
const first = `${firstIsText(["a", 9], ["b", 1])},${firstIsText(["b", 1], ["a", 9])}`;
const nest = `${nested([[10, "a"], 0], [[9, "a"], 0])},${nested([[9, "a"], 0], [[10, "a"], 0])}`;
const deepest = `${deep([1, ["a", [2, "b"]]], [1, ["a", [2, "b"]]])},${deep([1, ["a", [2, "c"]]], [1, ["a", [2, "b"]]])}`;
const big = `${byBig([large, 1], [small, 2])},${byBig([small, 1], [large, 2])}`;
console.log(`last=${last} first=${first} le=${atMost([1, "a"], [1, "a"])} gt=${above([1, "b"], [1, "a"])} ge=${atLeast([1, "a"], [1, "b"])} nested=${nest} deep=${deepest} big=${big}`);
