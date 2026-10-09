import { Node, NodeKind, bindSym, getTypeImpl, resolveType, sameType } from "std/meta";

struct Canonical { word: uint64; }
struct Other { word: uint64; }
type Alias = Canonical;
type AliasTwice = Alias;
type Word = uint64;
type OpaqueWord = distinct uint64;
struct Holder { payload: AliasTwice; }

macro canonicalAliasesMatch(): Node {
	const canonical = bindSym("Canonical");
	const alias = bindSym("Alias");
	const nestedAlias = bindSym("AliasTwice");
	const holder = getTypeImpl(bindSym("Holder"))!;
	return {
		kind: NodeKind.BooleanLiteral,
		boolValue: sameType(alias, canonical) && sameType(canonical, alias) &&
			sameType(nestedAlias, canonical) &&
			sameType(getTypeImpl(holder.typExprFieldTypes[0]), canonical),
	};
}

macro scalarAliasesMatch(): Node {
	const word = resolveType("uint64");
	return { kind: NodeKind.BooleanLiteral, boolValue:
		sameType(bindSym("Word"), word) && sameType(word, bindSym("Word")) };
}

macro nominalBoundariesRemain(): Node {
	return { kind: NodeKind.BooleanLiteral, boolValue:
		!sameType(bindSym("Alias"), bindSym("Other")) &&
		!sameType(bindSym("OpaqueWord"), resolveType("uint64")) };
}

test "reflected record aliases keep canonical identity in both directions" {
	assert canonicalAliasesMatch();
}

test "reflected scalar aliases keep underlying identity in both directions" {
	assert scalarAliasesMatch();
}

test "reflected aliases preserve distinct and other nominal identities" {
	assert nominalBoundariesRemain();
}
