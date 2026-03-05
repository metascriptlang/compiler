; MetaScript outline queries for Zed
; Populates the code outline / symbol list in the sidebar

(function_declaration
  name: (_) @name) @item

(class_declaration
  name: (_) @name) @item

(interface_declaration
  name: (_) @name) @item

(enum_declaration
  name: (_) @name) @item

(method_declaration
  name: (_) @name) @item

(macro_declaration
  name: (identifier) @name) @item

(type_alias_declaration
  name: (_) @name) @item

(variable_declaration
  name: (identifier) @name) @item

(test_declaration
  name: (string) @name) @item
