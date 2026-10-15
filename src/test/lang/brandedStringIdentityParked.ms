// Parked at inbox card 2026-10-15-branded-string-inequality-fails-clang.md

type EntityId = string & { __brand: "EntityId" };

test "branded strings: aliases share identity while operations use the base representation" {
	for (const value of ["", "k", "entity:seven"]) {
		const id = value as EntityId;
		assert id != (value + "!") as EntityId;
	}
}
