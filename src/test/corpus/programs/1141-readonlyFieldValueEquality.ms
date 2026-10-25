// @stdout: field=true,false,true nested=true,false,true top=true,false,true mixed=true,true,false vec=true,true,false deep=true,false,true,false member=true,false nullable=true,false,true,true,false
// note: `==` and `!=` read both sides, so a `Readonly` view compares like the mutable value: a read-only Vec field, a read-only struct field holding a Vec, a read-only struct at top level, a view against a mutable value in either order, a bare read-only Vec, Vecs of Vecs and of structs under a view, the view a class field holds, and a nullable struct field reached through a view.

struct Curve { times: Vec<float32>; }
struct Track { curve: Readonly<Curve>; }
struct Plain { curve: Curve; }
struct Times { xs: Readonly<Vec<float32>>; }
struct Grid { rows: Readonly<Vec<Vec<int32>>>; }
struct Point { v: Vec<int32>; }
struct Cloud { ps: Readonly<Vec<Point>>; }
struct Skin { joints: Vec<int32>; }
struct Mesh { skin: Skin | null; }
struct Meshes { all: Readonly<Vec<Mesh>>; }
class Holder {
	curve: Readonly<Curve>;
	constructor(c: Curve) { this.curve = c; }
}

const t1: Times = { xs: [1.0] };
const t2: Times = { xs: [1.0] };
const t3: Times = { xs: [2.0] };
const field = `${t1 == t2},${t1 == t3},${t1 != t3}`;

const k1: Track = { curve: { times: [1.0, 2.0] } };
const k2: Track = { curve: { times: [1.0, 2.0] } };
const k3: Track = { curve: { times: [1.0] } };
const nested = `${k1 == k2},${k1 == k3},${k1 != k3}`;

const p1: Readonly<Plain> = { curve: { times: [1.0] } };
const p2: Readonly<Plain> = { curve: { times: [1.0] } };
const p3: Readonly<Plain> = { curve: { times: [3.0] } };
const top = `${p1 == p2},${p1 == p3},${p1 != p3}`;

const m: Plain = { curve: { times: [1.0] } };
const mixed = `${p1 == m},${m == p1},${m != p1}`;

const rv: Readonly<Vec<int32>> = [1, 2];
const mv: Vec<int32> = [1, 2];
const vec = `${rv == mv},${mv == rv},${rv != mv}`;

const g1: Grid = { rows: [[1], [2, 3]] };
const g2: Grid = { rows: [[1], [2, 3]] };
const g3: Grid = { rows: [[1], [2]] };
const c1: Cloud = { ps: [{ v: [1] }] };
const c2: Cloud = { ps: [{ v: [1] }] };
const c3: Cloud = { ps: [{ v: [2] }] };
const deep = `${g1 == g2},${g1 == g3},${c1 == c2},${c1 == c3}`;

const h1 = new Holder({ times: [1.0] });
const h2 = new Holder({ times: [1.0] });
const h3 = new Holder({ times: [4.0] });
const member = `${h1.curve == h2.curve},${h1.curve == h3.curve}`;

const s1: Meshes = { all: [{ skin: { joints: [1] } }, { skin: null }] };
const s2: Meshes = { all: [{ skin: { joints: [1] } }, { skin: null }] };
const s3: Meshes = { all: [{ skin: { joints: [2] } }, { skin: null }] };
const mesh: Mesh = { skin: { joints: [1] } };
const view: Readonly<Mesh> = mesh;
const nullable = `${s1 == s2},${s1 == s3},${s1 != s3},${view.skin == mesh.skin},${view.skin == null}`;

console.log(`field=${field} nested=${nested} top=${top} mixed=${mixed} vec=${vec} deep=${deep} member=${member} nullable=${nullable}`);
