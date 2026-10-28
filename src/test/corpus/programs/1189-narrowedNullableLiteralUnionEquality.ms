// @stdout: plain=other three null a
// @stdout: once=other three null a
// @stdout: twice=other three null a
// @stdout: flip=other three null a
function plain(own: "a" | int32 | null): string {
	if (own === 3) return "three";
	if (own === null) return "null";
	if (own === "a") return "a";
	return "other";
}

function once(own: "a" | int32 | null): string {
	if (own === null) return "null";
	if (own === 3) return "three";
	if (own === "a") return "a";
	return "other";
}

function twice(own: "a" | int32 | null): string {
	if (own === null) return "null";
	if (own === "a") return "a";
	if (own === 3) return "three";
	return "other";
}

function flip(own: "a" | int32 | null): string {
	if (own === null) return "null";
	if (own === "a") return "a";
	if (3 === own) return "three";
	return "other";
}

console.log(`plain=${plain(1)} ${plain(3)} ${plain(null)} ${plain("a")}`);
console.log(`once=${once(1)} ${once(3)} ${once(null)} ${once("a")}`);
console.log(`twice=${twice(1)} ${twice(3)} ${twice(null)} ${twice("a")}`);
console.log(`flip=${flip(1)} ${flip(3)} ${flip(null)} ${flip("a")}`);
