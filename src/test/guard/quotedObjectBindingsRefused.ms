// GUARD-CHECK-FAIL Property 'missing' does not exist on type
// GUARD-CHECK-FAIL Property 'map' does not exist on type
// GUARD-JS

interface QuotedBindingSource {
	x: string;
}
const src: QuotedBindingSource = { x: "ok" };
const wrongSource = { x: 7 };
const { x: okay }: QuotedBindingSource = src;
const { missing: missing } = src; // GUARD-REFUSED
const { map: wrongReceiver } = src; // GUARD-REFUSED
const { x: wrongType }: { x: string } = wrongSource; // GUARD-REFUSED
const { missing: missingTyped }: { x: string } = src; // GUARD-REFUSED
function wrongParameter({ "missing": value }: QuotedBindingSource): void {} // GUARD-REFUSED
for (const { missing: loopValue } of [src]) {} // GUARD-REFUSED
console.log(okay, missing, wrongReceiver, wrongType, missingTyped);
