// @stdout: ne true false strict true false param true false
type EntityId = string & { __brand: "EntityId" };

function differ(a: EntityId, b: EntityId): boolean { return a !== b; }

const a = "k" as EntityId;
const b = "k!" as EntityId;
const c = ("k" + "") as EntityId;
console.log(`ne ${a != b} ${a != c} strict ${a !== b} ${a !== c} param ${differ(a, b)} ${differ(a, c)}`);
