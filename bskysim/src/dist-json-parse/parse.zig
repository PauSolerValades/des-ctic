const std = @import("std");
const Io = std.Io;
const Scanner = std.json.Scanner;
const Token = std.json.Token;
const Allocator = std.mem.Allocator;

const stats = @import("distributions");
const ContDist = stats.NonNegativeContinuousDistribution;
const CDist = stats.ContinuousDistribution;
const DiscDist = stats.DiscreteDistribution;

const Precision = @import("../config.zig").Precision;
const DataType = @import("../config.zig").DataType;

const pcdist = @import("cont-parsers.zig");
const pddist = @import("disc-parsers.zig");

pub const ParseError = error{
    UnknownDistribution,
    UnknownParameter,
    MissingField,
    InvalidInterval,
    InvalidField,
};

pub const JsonScannerError = error{
    UnexpectedToken,
    SyntaxError,
    UnexpectedEndOfInput,
    BufferUnderrun,
    OutOfMemory,
};

pub fn parseNonNegativeContinuousDist(scanner: *Scanner, stderr: *Io.Writer, param_name: []const u8) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!ContDist(Precision) {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    const name_tok = try scanner.next();
    if (name_tok != Token.string) return error.UnexpectedToken;

    const Tag = std.meta.Tag(ContDist(Precision));
    const tag = std.meta.stringToEnum(Tag, name_tok.string) orelse {
        try stderr.print("unknown continuous distribution: '{s}'\n", .{name_tok.string});
        return error.UnknownDistribution;
    };

    const dist = switch (tag) {
        .exponential => try pcdist.parseExponential(ContDist(Precision), scanner, stderr),
        .pareto => try pcdist.parsePareto(ContDist(Precision), scanner, stderr),
        .uniform => try pcdist.parseUniform(ContDist(Precision), scanner, param_name, stderr),
        .constant => try pcdist.parseConstant(ContDist(Precision), scanner, param_name, stderr),
        .lognormal => try pcdist.parseLognormal(ContDist(Precision), scanner, stderr),
        .weibull => try pcdist.parseWeibull(ContDist(Precision), scanner, stderr),
        .gamma => try pcdist.parseGamma(ContDist(Precision), scanner, stderr),
        .gpareto => try pcdist.parseGeneralizedPareto(ContDist(Precision), scanner, stderr),
    };

    if (try scanner.next() != Token.object_end) return error.UnexpectedToken;
    return dist;
}

pub fn parseContinuousDist(scanner: *Scanner, stderr: *Io.Writer, param_name: []const u8) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!CDist(Precision) {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    const name_tok = try scanner.next();
    if (name_tok != Token.string) return error.UnexpectedToken;

    const Tag = std.meta.Tag(CDist(Precision));
    const tag = std.meta.stringToEnum(Tag, name_tok.string) orelse {
        try stderr.print("unknown continuous distribution: '{s}'\n", .{name_tok.string});
        return error.UnknownDistribution;
    };

    const dist = switch (tag) {
        .exponential => try pcdist.parseExponential(CDist, scanner, stderr),
        .pareto => try pcdist.parsePareto(CDist, scanner, stderr),
        .uniform => try pcdist.parseUniform(CDist, scanner, param_name, stderr),
        .constant => try pcdist.parseConstant(CDist, scanner, param_name, stderr),
        .normal => dist: {
            const d = try pcdist.parseNormal(CDist, scanner, stderr);
            try stderr.print("parameter '{s}' could be negative, as 'normal' is not strictly positive\n", .{param_name});
            break :dist d;
        },
    };

    if (try scanner.next() != Token.object_end) return error.UnexpectedToken;
    return dist;
}

// this is very very cool but i am not interested on this. It MUST be a categorical, therefore we can directly call
// parse categorical
pub fn parseDiscreteDist(gpa: Allocator, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{WriteFailed})!DiscDist(Precision, DataType) {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    const name_tok = try scanner.next();
    if (name_tok != Token.string) return error.UnexpectedToken;

    const Tag = std.meta.Tag(DiscDist(Precision, DataType));
    const tag = std.meta.stringToEnum(Tag, name_tok.string) orelse {
        try stderr.print("unknown discrete distribution: '{s}'\n", .{name_tok.string});
        return error.UnknownDistribution;
    };

    const dist = switch (tag) {
        .categorical => try pddist.parseCategorical(gpa, scanner, stderr),
        .constant => return error.UnknownDistribution,
        .ecdf => return error.UnknownDistribution,
    };

    if (try scanner.next() != Token.object_end) return error.UnexpectedToken;
    return dist;
}

pub fn readKeyNumber(scanner: *Scanner, comptime T: type) (JsonScannerError || error{InvalidCharacter})!T {
    const tok = try scanner.next();
    if (tok != Token.number) return error.UnexpectedToken;
    return try std.fmt.parseFloat(T, tok.number);
}

pub fn readKeyBool(scanner: *Scanner) JsonScannerError!bool {
    const tok = try scanner.next();
    return switch (tok) {
        .true => true,
        .false => false,
        else => error.UnexpectedToken,
    };
}

pub fn readKeyString(gpa: Allocator, scanner: *Scanner) (JsonScannerError || Allocator.Error)![]u8 {
    const tok = try scanner.next();
    if (tok != Token.string) return error.UnexpectedToken;
    return try gpa.dupe(u8, tok.string);
}

const Action = @import("../entities.zig").Action;
pub fn parseUserPolicyCategorical(gpa: std.mem.Allocator, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!stats.Categorical(Precision, Action) {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;
    var weights: std.ArrayList(Precision) = .empty;
    defer weights.deinit(gpa);
    var data: std.ArrayList(Action) = .empty;
    defer data.deinit(gpa);

    var parsed_weights = false;
    var parsed_data = false;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        if (std.mem.eql(u8, tok.string, "weights")) {
            if (try scanner.next() != Token.array_begin) return error.UnexpectedToken;
            while (true) {
                const el = try scanner.next();
                if (el == Token.array_end) break;
                const w = try std.fmt.parseFloat(Precision, el.number);
                try weights.append(gpa, w);
            }
            parsed_weights = true;
        } else if (std.mem.eql(u8, tok.string, "data")) {
            if (try scanner.next() != Token.array_begin) return error.UnexpectedToken;
            while (true) {
                const el = try scanner.next();
                if (el == Token.array_end) break;
                if (el != Token.string) return error.UnexpectedToken;

                const action = std.meta.stringToEnum(Action, el.string) orelse {
                    try stderr.print("invalid action: '{s}'\n", .{el.string});
                    return error.InvalidField;
                };
                try data.append(gpa, action);
            }
            parsed_data = true;
        } else {
            try stderr.print("categorical: unknown param '{s}'\n", .{tok.string});
            return error.UnknownParameter;
        }
    }

    if (!parsed_weights or !parsed_data) {
        try stderr.print("user_policy: missing required field (need 'weights' and 'data')\n", .{});
        return error.MissingField;
    }

    const weights_dup = try gpa.dupe(Precision, weights.items);
    errdefer gpa.free(weights_dup);
    const data_dup = try gpa.dupe(Action, data.items);
    errdefer gpa.free(data_dup);

    return try stats.Categorical(Precision, Action).init(gpa, weights_dup, data_dup);
}
