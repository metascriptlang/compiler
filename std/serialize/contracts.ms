// SERIALIZE — Optional capability menu
//
// Format libraries opt into capabilities by exporting an instance of the
// matching interface. Cross-format tools constrain on the interface they
// need; format authors choose which capabilities to implement based on
// format nature. Schema-bound formats (Protobuf, Avro) deliberately omit
// untyped tree access; tools that need it won't accept those formats.
//
// See docs/SERIALIZE.md §X for the full capability matrix and rationale.

// ===== UntypedTree<V> — schema-less tree access =====
//
// Capability: parse raw input into a format-specific Value tree, then
// access fields dynamically via the `getDynamicField` protocol (`v.foo.bar`).
//
// REQUIRED FOR THE V TYPE:
//   - opt into `getDynamicField` protocol (extension method)
//   - provide accessor methods (`asString`, `asInt32`, `asNumber`, `asBoolean`)
//
// Implemented by:
//   - JSON   (JsonValue)         — std/serialize/json
//   - TOML   (TomlValue)         — std/serialize/toml (planned)
//   - YAML   (YamlValue)         — future
//   - BSON   (BsonValue)         — future
//
// NOT implemented by (schema-bound):
//   - Protobuf, Cap'n Proto, FlatBuffers, Apache Avro
export interface UntypedTree<V> {
	parseValue: (input: string) => Result<V, string>;
}
