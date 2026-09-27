// @stdout: 1 2 3 4 | 5 6 7 8 | 9 10 | 11 12 13 14
// note: identifiers that mangle to one C spelling (`$` expands to `dollar` plus a trailing `_`, which a plain identifier can also end with) stay distinct functions, globals, methods and locals, also across modules (codegen-c-15: C redefined one name, JS declared one identifier twice).

import { a$b, adollarb_, x$y, xdollary_ } from "./mangledNamesLib";

function c$d(): int32 { return 5; }
function cdollard_(): int32 { return 6; }
const g$h: int32 = 7;
const gdollarh_: int32 = 8;

class A { m(): int32 { return 9; } }
function A_m(): int32 { return 10; }

function userThenTemp(): string {
	const dollarv: int32 = 11;
	const $v_1: int32 = 12;
	return `${dollarv} ${$v_1}`;
}

function tempThenUser(): string {
	const $w_1: int32 = 13;
	const dollarw: int32 = 14;
	return `${$w_1} ${dollarw}`;
}

console.log(`${a$b()} ${adollarb_()} ${x$y} ${xdollary_} | ${c$d()} ${cdollard_()} ${g$h} ${gdollarh_} | ${new A().m()} ${A_m()} | ${userThenTemp()} ${tempThenUser()}`);
