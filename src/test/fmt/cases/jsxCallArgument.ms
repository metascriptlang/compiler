import { assertFmtContains, assertFmtIdempotent } from "../roundtrip";

const attr = "params={P.of(\"I\", { getId: (params: IP | null): string => params === null ? \"\" : params.id.toString() })}";
const firstArg = "function mount(): void {\n\trender(<A r={r}>\n\t\t<B>\n\t\t\t<C n=\"I\" c={B}\n\t\t\t\t" + attr + " />\n\t\t</B>\n\t</A>, mockHost(), root);\n}\n";
const nested = "function mount(): void {\n\trender(element(<A>\n\t\t<C " + attr + " />\n\t</A>));\n}\n";
const property = "const x = {\n\tchildren: element(<>\n\t\t<C " + attr + " />\n\t</>, 1),\n};\n";

test "fmt: a JSX call argument written on several lines breaks the arguments out on the first pass" {
	assert assertFmtContains(firstArg, "\trender(\n\t\t<A r={r}>");
	assert assertFmtIdempotent(firstArg);
}

test "fmt: a several-line JSX element or fragment inside a nested call or a property is stable" {
	assert assertFmtIdempotent(nested);
	assert assertFmtIdempotent(property);
}
