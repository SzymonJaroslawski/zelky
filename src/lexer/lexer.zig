const std = @import("std");

pub const TokenKind = enum {
    number,
    identifier,
    string,

    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_func,
    kw_return,
    kw_let,
    kw_true,
    kw_false,

    plus,
    minus,
    star,
    slash,
    lparen,
    rparen,
    lbrace,
    rbrace,
    comma,
    semicolon,

    eq,
    eq_eq,
    bang,
    bang_eq,
    lt,
    lt_eq, // <=
    gt,
    gt_eq, // >=
    amp_amp,
    pipe_pipe,

    eof,
    invalid,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: usize,
};

const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "for", .kw_for },
    .{ "func", .kw_func },
    .{ "return", .kw_return },
    .{ "let", .kw_let },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
});

pub const Lexer = struct {
    source: []const u8,
    start: usize = 0,
    current: usize = 0,
    line: usize = 1,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();
        self.start = self.current;

        if (self.isAtEnd()) return self.makeToken(.eof);

        const c = self.advance();

        if (std.ascii.isDigit(c)) return self.number();
        if (isAlpha(c)) return self.identifierOrKeyword();

        return switch (c) {
            '+' => self.makeToken(.plus),
            '-' => self.makeToken(.minus),
            '*' => self.makeToken(.star),
            '/' => self.makeToken(.slash),
            '(' => self.makeToken(.lparen),
            ')' => self.makeToken(.rparen),
            '{' => self.makeToken(.lbrace),
            '}' => self.makeToken(.rbrace),
            ',' => self.makeToken(.comma),
            ';' => self.makeToken(.semicolon),

            '=' => self.makeToken(if (self.match('=')) .eq_eq else .eq),
            '!' => self.makeToken(if (self.match('=')) .bang_eq else .bang),
            '<' => self.makeToken(if (self.match('=')) .lt_eq else .lt),
            '>' => self.makeToken(if (self.match('=')) .gt_eq else .gt),
            '&' => self.makeToken(if (self.match('&')) .amp_amp else .invalid),
            '|' => self.makeToken(if (self.match('|')) .pipe_pipe else .invalid),

            '"' => self.string(),

            else => self.makeToken(.invalid),
        };
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.current >= self.source.len;
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.current];
        self.current += 1;
        return c;
    }

    fn peek(self: *Lexer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *Lexer) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;
        self.current += 1;
        return true;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', '\r' => _ = self.advance(),
                '\n' => {
                    self.line += 1;
                    _ = self.advance();
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        while (self.peek() != '\n' and !self.isAtEnd()) {
                            _ = self.advance();
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn number(self: *Lexer) Token {
        while (std.ascii.isDigit(self.peek())) _ = self.advance();

        if (self.peek() == '.' and std.ascii.isDigit(self.peekNext())) {
            _ = self.advance(); // consume '.'
            while (std.ascii.isDigit(self.peek())) _ = self.advance();
        }

        return self.makeToken(.number);
    }

    fn identifierOrKeyword(self: *Lexer) Token {
        while (isAlphaNumeric(self.peek())) _ = self.advance();

        const text = self.source[self.start..self.current];
        if (keywords.get(text)) |kind| {
            return self.makeToken(kind);
        }

        return self.makeToken(.identifier);
    }

    fn string(self: *Lexer) Token {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') {
                self.line += 1;
            } else if (self.peek() == '\\' and self.peekNext() != 0) {
                _ = self.advance(); // Skip backslash
            }
            _ = self.advance();
        }

        if (self.isAtEnd()) {
            return self.makeToken(.invalid);
        }

        _ = self.advance(); // Closing quote
        return self.makeToken(.string);
    }

    fn makeToken(self: *Lexer, kind: TokenKind) Token {
        return .{
            .kind = kind,
            .lexeme = self.source[self.start..self.current],
            .line = self.line,
        };
    }

    fn isAlpha(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isAlphaNumeric(c: u8) bool {
        return isAlpha(c) or std.ascii.isDigit(c);
    }
};
