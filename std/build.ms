export interface FmtConfig {
	printWidth?: int32;
	tabWidth?: int32;
	useTabs?: boolean;
	singleQuote?: boolean;
}

export interface BuildConfig {
	entry?: string;
	fmt?: FmtConfig;
}
