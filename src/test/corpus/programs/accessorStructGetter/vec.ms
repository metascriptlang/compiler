export struct Vec2 { x: float32; y: float32; }

export struct Vec4 {
	x: float32;
	y: float32;
	get xy(): Vec2 { return { x: this.x, y: this.y }; }
	z: float32;
	w: float32;
	get yx(): Vec2 { return { x: this.y, y: this.x }; }
	get zw(): Vec2 { return { x: this.z, y: this.w }; }
}
