// Parity program — the ES2025 set method family over the three storage bands.
// The operator forms `|` `&` `^` stay the shorthand for the familiar three.
//
// @stdout: 3,1,1,2,true,true,true,false|3,1,1,2,true,true,true,false|6,1,5,5,true,true,true,false|3,2,3,3,6,true
// @exit: 0

enum E { A, B, C, D }
enum W { W0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, W12, W13, W14, W15, W16, W17, W18, W19, W20, W21, W22, W23, W24, W25, W26, W27, W28, W29, W30, W31, W32, W33, W34, W35, W36, W37, W38, W39 }
enum H { X0, X1, X2, X3, X4, X5, X6, X7, X8, X9, X10, X11, X12, X13, X14, X15, X16, X17, X18, X19, X20, X21, X22, X23, X24, X25, X26, X27, X28, X29, X30, X31, X32, X33, X34, X35, X36, X37, X38, X39, X40, X41, X42, X43, X44, X45, X46, X47, X48, X49, X50, X51, X52, X53, X54, X55, X56, X57, X58, X59, X60, X61, X62, X63, X64, X65, X66, X67, X68, X69, X70, X71, X72, X73, X74, X75, X76, X77, X78, X79, X80, X81, X82, X83, X84, X85, X86, X87, X88, X89, X90, X91, X92, X93, X94, X95, X96, X97, X98, X99 }

function main(): void {
	const s: BitSet<E> = E.A | E.C;
	const t: BitSet<E> = E.C | E.D;
	const sub = (0 as BitSet<E>).incl(E.C);
	const small = `${s.union(t).size()},${s.intersection(t).size()},${s.difference(t).size()},${s.symmetricDifference(t).size()},${sub.isSubsetOf(s)},${s.isSupersetOf(sub)},${s.isDisjointFrom((0 as BitSet<E>).incl(E.B))},${s.isDisjointFrom(t)}`;

	const ws: BitSet<W> = W.W1 | W.W39;
	const wt: BitSet<W> = W.W39 | W.W2;
	const wsub = (0 as BitSet<W>).incl(W.W39);
	const wide = `${ws.union(wt).size()},${ws.intersection(wt).size()},${ws.difference(wt).size()},${ws.symmetricDifference(wt).size()},${wsub.isSubsetOf(ws)},${ws.isSupersetOf(wsub)},${ws.isDisjointFrom((0 as BitSet<W>).incl(W.W0))},${ws.isDisjointFrom(wt)}`;

	const z = 0 as BitSet<H>;
	const a = z.incl(H.X0).incl(H.X7).incl(H.X8).incl(H.X63).incl(H.X64).incl(H.X99);
	const b = z.incl(H.X99);
	const arr = `${a.union(b).size()},${a.intersection(b).size()},${a.difference(b).size()},${a.symmetricDifference(b).size()},${b.isSubsetOf(a)},${a.isSupersetOf(b)},${a.isDisjointFrom(z.incl(H.X1))},${a.isDisjointFrom(b)}`;

	const u = s.union(t).union(sub);
	const chained = s.union(t).difference(sub).incl(E.D);
	const wchained = ws.union(wt).difference(wsub).incl(W.W0);
	const achained = a.union(b).difference(z.incl(H.X0)).incl(H.X1);
	console.log(`${small}|${wide}|${arr}|${u.size()},${chained.size()},${s.union(t).size()},${wchained.size()},${achained.size()},${a.union(b).isSubsetOf(a)}`);
}
main();
