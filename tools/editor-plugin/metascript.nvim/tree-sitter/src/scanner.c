// External scanner for Metascript tree-sitter grammar
// Disambiguates '<' as type arguments opener vs less-than comparison
// Same approach as tree-sitter-typescript

#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <string.h>

enum TokenType {
  TYPE_ARGS_OPEN, // '<' that starts type arguments (followed by types and '>(')
};

// Skip whitespace and comments
static void skip_ws(TSLexer *lexer) {
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
         lexer->lookahead == '\n' || lexer->lookahead == '\r') {
    lexer->advance(lexer, true);
  }
}

// Check if a character can start an identifier
static bool is_ident_start(int32_t c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$';
}

// Check if a character can continue an identifier
static bool is_ident_char(int32_t c) {
  return is_ident_start(c) || (c >= '0' && c <= '9');
}

// Scan forward after '<' to see if this is type_arguments: <Type>(
// Returns true if we find balanced content ending with '>' followed by '('
static bool scan_type_args_after_lt(TSLexer *lexer) {
  int depth = 1;
  bool saw_content = false;

  while (depth > 0) {
    skip_ws(lexer);

    int32_t c = lexer->lookahead;

    if (c == 0) return false; // EOF
    if (c == ';' || c == '{' || c == '}') return false; // Statement boundary — not type args
    if (c == '=' && depth == 1) return false; // Assignment — not type args

    if (c == '<') {
      depth++;
      lexer->advance(lexer, false);
    } else if (c == '>') {
      depth--;
      if (depth == 0) {
        // Found matching '>' — check if followed by '('
        lexer->advance(lexer, false);
        skip_ws(lexer);
        return lexer->lookahead == '(';
      }
      lexer->advance(lexer, false);
    } else if (is_ident_start(c)) {
      saw_content = true;
      // Skip identifier
      while (is_ident_char(lexer->lookahead)) {
        lexer->advance(lexer, false);
      }
      // Allow dots in type names (e.g., Foo.Bar)
      // Allow commas between type args
      // Allow [] for array types
    } else if (c == ',') {
      lexer->advance(lexer, false);
    } else if (c == '[') {
      lexer->advance(lexer, false);
      skip_ws(lexer);
      // Optional number for sized arrays
      while (lexer->lookahead >= '0' && lexer->lookahead <= '9') {
        lexer->advance(lexer, false);
      }
      skip_ws(lexer);
      if (lexer->lookahead == ']') {
        lexer->advance(lexer, false);
      } else {
        return false;
      }
    } else if (c == '.') {
      lexer->advance(lexer, false);
    } else if (c == '|') {
      // Union types: Result<string | null>
      lexer->advance(lexer, false);
    } else {
      // Unexpected character — not type args
      return false;
    }
  }

  return false;
}

void *tree_sitter_metascript_external_scanner_create(void) {
  return NULL;
}

void tree_sitter_metascript_external_scanner_destroy(void *payload) {
}

unsigned tree_sitter_metascript_external_scanner_serialize(void *payload, char *buffer) {
  return 0;
}

void tree_sitter_metascript_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
}

bool tree_sitter_metascript_external_scanner_scan(
  void *payload, TSLexer *lexer, const bool *valid_symbols
) {
  if (!valid_symbols[TYPE_ARGS_OPEN]) return false;

  skip_ws(lexer);

  if (lexer->lookahead != '<') return false;

  // Advance past '<' and mark it as the token
  lexer->advance(lexer, false);
  lexer->mark_end(lexer);

  // Look ahead to determine if this '<' starts type arguments
  if (scan_type_args_after_lt(lexer)) {
    lexer->result_symbol = TYPE_ARGS_OPEN;
    return true;
  }

  return false;
}
