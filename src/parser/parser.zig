const std = @import("std");
const lex = @import("../lexer/lexer.zig");
const Token = lex.Token;
const TokenKind = lex.TokenKind;

pub const Expr = union(enum) {
    number: f64,
    boolean: bool,
    string: []const u8,
    variable: []const u8,

    unary: struct {
        op: TokenKind,
        operand: *Expr,
    },

    binary: struct {
        op: TokenKind,
        left: *Expr,
        right: *Expr,
    },

    assign: struct {
        name: []const u8,
        value: *Expr,
    },

    call: struct {
        callee: *Expr,
        args: []*Expr,
    },
};

pub const Stmt = union(enum) {
    expr_stmt: *Expr,
    block: []Stmt,

    if_stmt: struct {
        condition: *Expr,
        then_branch: *Stmt,
        else_branch: ?*Stmt,
    },

    let_stmt: struct {
        name: []const u8,
        initializer: *Expr,
    },

    ret_stmt: *Expr,

    fn_decl: FnDecl,
};

pub const FnDecl = struct {
    name: []const u8,
    params: [][]const u8,
    body: *Stmt,
};

fn infixBindingPower(kind: TokenKind) ?struct { left: u8, right: u8 } {
    return switch (kind) {
        .pipe_pipe => .{ .left = 1, .right = 2 },
        .amp_amp => .{ .left = 3, .right = 4 },
        .eq_eq, .bang_eq => .{ .left = 5, .right = 6 },
        .lt, .lt_eq, .gt, .gt_eq => .{ .left = 7, .right = 8 },
        .plus, .minus => .{ .left = 9, .right = 10 },
        .star, .slash => .{ .left = 11, .right = 12 },
        else => null,
    };
}

fn prefixBindingPower(kind: TokenKind) ?u8 {
    return switch (kind) {
        .minus, .bang => 13,
        else => null,
    };
}

pub const ParserError = error{
    UnexpectedToken,
    BadNumber,
    OutOfMemory,
};

pub const Diagnostic = struct {
    message: []const u8,
    line: usize,
    lexeme: []const u8,
    expected: ?TokenKind = null,
};

pub const Parser = struct {
    lexer: *lex.Lexer,
    alloc: std.mem.Allocator,
    current: Token,
    diagnostic: ?Diagnostic = null,

    pub fn init(alloc: std.mem.Allocator, lexer: *lex.Lexer) Parser {
        var p = Parser{ .lexer = lexer, .alloc = alloc, .current = undefined };
        p.current = lexer.next();
        return p;
    }

    fn advance(self: *Parser) Token {
        const tok = self.current;
        self.current = self.lexer.next();
        return tok;
    }

    fn fail(self: *Parser, message: []const u8, expected: ?TokenKind, err: ParserError) ParserError {
        self.diagnostic = .{
            .message = message,
            .line = self.current.line,
            .lexeme = self.current.lexeme,
            .expected = expected,
        };
        return err;
    }

    fn expect(self: *Parser, kind: TokenKind) ParserError!Token {
        if (self.current.kind != kind) {
            return self.fail("unexpected token", kind, ParserError.UnexpectedToken);
        }
        return self.advance();
    }

    fn alloc_expr(self: *Parser, e: Expr) ParserError!*Expr {
        const ptr = try self.alloc.create(Expr);
        ptr.* = e;
        return ptr;
    }

    fn alloc_stmt(self: *Parser, s: Stmt) !*Stmt {
        const ptr = try self.alloc.create(Stmt);
        ptr.* = s;
        return ptr;
    }

    pub fn parseProgram(self: *Parser) ParserError!Stmt {
        var stmts = try std.ArrayList(Stmt).initCapacity(self.alloc, 0);
        while (self.current.kind != .eof) {
            try stmts.append(self.alloc, try self.parseStmt());
        }

        return .{ .block = try stmts.toOwnedSlice(self.alloc) };
    }

    pub fn parseExpr(self: *Parser) !*Expr {
        const expr = try self.parseBindingPower(0);

        if (self.current.kind == .eq) {
            _ = self.advance();

            const name = switch (expr.*) {
                .variable => |v| v,
                else => return self.fail("invalid assignment", null, ParserError.UnexpectedToken),
            };

            const value = try self.parseExpr();
            return self.alloc_expr(.{ .assign = .{ .name = name, .value = value } });
        }

        return expr;
    }

    pub fn parseStmt(self: *Parser) ParserError!Stmt {
        return switch (self.current.kind) {
            .lbrace => self.parseBlock(),
            .kw_if => self.parseIf(),
            .kw_let => self.parseLet(),
            .kw_return => self.parseReturn(),
            .kw_func => self.parseFnDecl(),
            else => self.parseExprStmt(),
        };
    }

    fn parseBlock(self: *Parser) ParserError!Stmt {
        _ = try self.expect(.lbrace);

        var stmts = try std.ArrayList(Stmt).initCapacity(self.alloc, 0);
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            try stmts.append(self.alloc, try self.parseStmt());
        }
        _ = try self.expect(.rbrace);

        return .{ .block = try stmts.toOwnedSlice(self.alloc) };
    }

    fn parseIf(self: *Parser) ParserError!Stmt {
        _ = try self.expect(.kw_if);
        _ = try self.expect(.lparen);
        const cond = try self.parseExpr();
        _ = try self.expect(.rparen);

        const then_branch = try self.alloc_stmt(try self.parseStmt());

        var else_branch: ?*Stmt = null;
        if (self.current.kind == .kw_else) {
            _ = self.advance();
            else_branch = try self.alloc_stmt(try self.parseStmt());
        }

        return .{ .if_stmt = .{ .condition = cond, .then_branch = then_branch, .else_branch = else_branch } };
    }

    fn parseLet(self: *Parser) ParserError!Stmt {
        _ = try self.expect(.kw_let);
        const name = try self.expect(.identifier);
        _ = try self.expect(.eq);
        const initializer = try self.parseExpr();
        _ = try self.expect(.semicolon);

        return .{ .let_stmt = .{ .name = name.lexeme, .initializer = initializer } };
    }

    fn parseReturn(self: *Parser) ParserError!Stmt {
        _ = try self.expect(.kw_return);
        const expr = try self.parseExpr();
        _ = try self.expect(.semicolon);

        return .{ .ret_stmt = expr };
    }

    fn parseFnDecl(self: *Parser) ParserError!Stmt {
        _ = try self.expect(.kw_func);
        const name = try self.expect(.identifier);
        _ = try self.expect(.lparen);

        var params = try std.ArrayList([]const u8).initCapacity(self.alloc, 5);
        if (self.current.kind != .rparen) {
            while (true) {
                const param = try self.expect(.identifier);
                try params.append(self.alloc, param.lexeme);
                if (self.current.kind != .comma) break;
                _ = self.advance();
            }
        }
        _ = try self.expect(.rparen);

        const body = try self.alloc_stmt(try self.parseBlock());

        return .{ .fn_decl = .{
            .name = name.lexeme,
            .params = try params.toOwnedSlice(self.alloc),
            .body = body,
        } };
    }

    fn parseExprStmt(self: *Parser) ParserError!Stmt {
        const expr = try self.parseExpr();
        _ = try self.expect(.semicolon);
        return .{ .expr_stmt = expr };
    }

    fn parseCall(self: *Parser) ParserError!*Expr {
        var expr = try self.parseAtom();

        while (self.current.kind == .lparen) {
            _ = self.advance();

            var args = try std.ArrayList(*Expr).initCapacity(self.alloc, 5);

            if (self.current.kind != .rparen) {
                while (true) {
                    try args.append(self.alloc, try self.parseExpr());
                    if (self.current.kind != .comma) break;
                    _ = self.advance();
                }
            }
            _ = try self.expect(.rparen);

            expr = try self.alloc_expr(.{ .call = .{ .callee = expr, .args = try args.toOwnedSlice(self.alloc) } });
        }

        return expr;
    }

    fn parseBindingPower(self: *Parser, min_bp: u8) ParserError!*Expr {
        var left = try self.parsePrefix();

        while (true) {
            const op = self.current.kind;
            const bp = infixBindingPower(op) orelse break;

            if (bp.left < min_bp) break;

            _ = self.advance();
            const right = try self.parseBindingPower(bp.right);

            left = try self.alloc_expr(.{ .binary = .{ .op = op, .left = left, .right = right } });
        }

        return left;
    }

    fn parsePrefix(self: *Parser) ParserError!*Expr {
        if (prefixBindingPower(self.current.kind)) |bp| {
            const op = self.advance().kind;
            const operand = try self.parseBindingPower(bp);
            return self.alloc_expr(.{ .unary = .{ .op = op, .operand = operand } });
        }
        return self.parseCall();
    }

    fn parseAtom(self: *Parser) ParserError!*Expr {
        const tok = self.current;
        return switch (tok.kind) {
            .number => blk: {
                _ = self.advance();
                const value = std.fmt.parseFloat(f64, tok.lexeme) catch return ParserError.BadNumber;
                break :blk self.alloc_expr(.{ .number = value });
            },
            .string => blk: {
                _ = self.advance();
                break :blk self.alloc_expr(.{ .string = tok.lexeme });
            },
            .kw_true => blk: {
                _ = self.advance();
                break :blk self.alloc_expr(.{ .boolean = true });
            },
            .kw_false => blk: {
                _ = self.advance();
                break :blk self.alloc_expr(.{ .boolean = false });
            },
            .identifier => blk: {
                _ = self.advance();
                break :blk self.alloc_expr(.{ .variable = tok.lexeme });
            },
            .lparen => blk: {
                _ = self.advance();
                const inner = try self.parseBindingPower(0);
                _ = try self.expect(.rparen);
                break :blk inner;
            },
            else => ParserError.UnexpectedToken,
        };
    }
};
