// @stdout: true true true
// note: std's JSON parser keeps its powers-of-ten table as a readonly module const, so a Sendable
// function (one a task or another thread may run) can parse decimals, integers and exponents.
import { parseJson } from "std/serialize/json";

const decimal: Sendable<() => boolean> = (): boolean => parseJson("1.25").ok;
const integer: Sendable<() => boolean> = (): boolean => parseJson("[1, -42, 9007199254740991]").ok;
const exponent: Sendable<() => boolean> = (): boolean => parseJson("{\"x\": 6.02e23, \"y\": 1e-7}").ok;
console.log(`${decimal()} ${integer()} ${exponent()}`);
