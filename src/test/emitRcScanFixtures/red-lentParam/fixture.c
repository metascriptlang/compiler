struct Decl__fixture {
	msStringArray* params;
};
msString header__fixture(msStringArray* paramNames_p0) {
	msStringArray* names_1_;
	(names_1_ = paramNames_p0);
	msIncref(names_1_);
	msDecref(names_1_);
}
void emitModuleJob__fixturecompileOms_u0(void) {
	Decl__fixture* d = 0;
	header__fixture((*d).params);
}
