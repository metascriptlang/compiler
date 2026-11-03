// @stdout: macro 4997
// @stdout: nested 1334
// note: a function body reuses the registers of each statement's temps and of a closed block's locals. Before, every temp of a body got its own register, so a macro body or a Raiser function of a thousand statements named a register past the 8191 a tagged operand holds and stopped with 'past what an operand of this opcode holds'.

import { Node, NodeKind } from "std/meta";

macro wideSum(): Node {
	const p = "ab";
	const q = "xyz";
	let text = "";
	let total: number = 0;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	text = text + p.slice(1) + q.slice(2); total = total + 6;
	text = text + p.slice(1) + q.slice(2); total = total + 0;
	text = text + p.slice(1) + q.slice(2); total = total + 1;
	text = text + p.slice(1) + q.slice(2); total = total + 2;
	text = text + p.slice(1) + q.slice(2); total = total + 3;
	text = text + p.slice(1) + q.slice(2); total = total + 4;
	text = text + p.slice(1) + q.slice(2); total = total + 5;
	return { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: total + text.length, isFloat: false };
}

function nested(k: int64, p: string, q: string): string {
	let text = "";
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 1) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 2) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	if (k > 0) { const piece = p.slice(1); { const more = q.slice(2) + piece; text = text + more; } }
	return `${text.length}`;
}

const sum: number = wideSum();
console.log("macro " + sum.toString());
console.log("nested " + nested(2, "ab", "xyz"));
