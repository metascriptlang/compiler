import { cborValueOf, cborValueToStruct } from "std/serialize/cbor";

interface CborIdentityChild { n: int32; label: string; }
interface CborIdentityParent { child: CborIdentityChild; children: CborIdentityChild[]; }
function _cborArrayOfStructs<T>(arr: T[]): unknown { throw new Error("caller encoder captured"); }
function _cborToStructArray<T>(value: unknown, witness: T | null): T[] { throw new Error("caller decoder captured"); }

test "CBOR nested type identity: a macro binds its private array helper from its declaring module" {
	const original: CborIdentityParent = {
		child: { n: 7, label: "a" },
		children: [{ n: 9, label: "b" }],
	};
	const value = cborValueOf(original);
	const decoded: CborIdentityParent = cborValueToStruct(value, null as CborIdentityParent | null);
	assert decoded.child.n == 7 && decoded.child.label == "a";
	assert decoded.children.length == 1 && decoded.children[0].n == 9 && decoded.children[0].label == "b";
}

enum CborIdentityShade { Light, Dark }
interface CborIdentityArrays { shades: CborIdentityShade[]; numbers: int32[]; }

test "CBOR nested type identity: enum and integer arrays retain their checked element kinds" {
	const original: CborIdentityArrays = { shades: [CborIdentityShade.Dark, CborIdentityShade.Light], numbers: [3, 5] };
	const value = cborValueOf(original);
	const decoded: CborIdentityArrays = cborValueToStruct(value, null as CborIdentityArrays | null);
	assert decoded.shades.length == 2 && decoded.shades[0] == CborIdentityShade.Dark && decoded.shades[1] == CborIdentityShade.Light;
	assert decoded.numbers.length == 2 && decoded.numbers[0] == 3 && decoded.numbers[1] == 5;
}
