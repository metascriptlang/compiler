// Parked at inbox card 2026-09-27-branded-string-inequality.md

type EntityId = string & { __brand: "EntityId" };

test "branded strings: aliases share identity while operations use the base representation" {
	for (const value of ["", "k", "entity:seven"]) {
		const id = value as EntityId;
		assert id != (value + "!") as EntityId;
	}
}
