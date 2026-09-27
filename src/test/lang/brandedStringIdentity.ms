type EntityId = string & { __brand: "EntityId" };
type EntityAlias = string & { __brand: "EntityId" };

function text(value: string): string { return value; }
function entity(value: EntityId): string { return value as string; }

test "branded strings: aliases share identity while operations use the base representation" {
	for (const value of ["", "k", "entity:seven"]) {
		const id = value as EntityId;
		const alias = value as EntityAlias;
		assert text(id) == value;
		assert entity(alias) == value;
		assert id.length == value.length;
		assert id == alias;
		assert id != (value + "!") as EntityId;
	}
}
