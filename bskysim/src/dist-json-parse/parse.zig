const std = @import("std");
const Io = std.Io;
const Scanner = std.json.Scanner;
const Token = std.json.Token;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const stats = @import("distributions");
const NNContDist = stats.NonNegativeContinuousDistribution;
const ContDist = stats.ContinuousDistribution;
const DiscDist = stats.DiscreteDistribution;

const DistTag = std.meta.Tag(NNContDist(f32));
const Action = @import("../entities.zig").Action;

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

pub fn parseNonNegativeContinuousDist(scanner: *Scanner, stderr: *Io.Writer, param_name: []const u8) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!NNContDist(f32) {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    const name_tok = try scanner.next();
    if (name_tok != Token.string) return error.UnexpectedToken;

    const Tag = std.meta.Tag(NNContDist(f32));
    const tag = std.meta.stringToEnum(Tag, name_tok.string) orelse {
        try stderr.print("unknown continuous distribution: '{s}'\n", .{name_tok.string});
        return error.UnknownDistribution;
    };

    const dist = switch (tag) {
        .exponential => try pcdist.parseExponential(NNContDist(f32), scanner, stderr),
        .pareto => try pcdist.parsePareto(NNContDist(f32), scanner, stderr),
        .uniform => try pcdist.parseUniform(NNContDist(f32), scanner, param_name, stderr),
        .constant => try pcdist.parseConstant(NNContDist(f32), scanner, param_name, stderr),
        .lognormal => try pcdist.parseLognormal(NNContDist(f32), scanner, stderr),
        .weibull => try pcdist.parseWeibull(NNContDist(f32), scanner, stderr),
        .gamma => try pcdist.parseGamma(NNContDist(f32), scanner, stderr),
        .gpareto => try pcdist.parseGeneralizedPareto(NNContDist(f32), scanner, stderr),
    };

    if (try scanner.next() != Token.object_end) return error.UnexpectedToken;
    return dist;
}

pub fn parseContinuousDist(scanner: *Scanner, stderr: *Io.Writer, param_name: []const u8) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!ContDist(f32) {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    const name_tok = try scanner.next();
    if (name_tok != Token.string) return error.UnexpectedToken;

    const Tag = std.meta.Tag(ContDist(f32));
    const tag = std.meta.stringToEnum(Tag, name_tok.string) orelse {
        try stderr.print("unknown continuous distribution: '{s}'\n", .{name_tok.string});
        return error.UnknownDistribution;
    };

    const dist = switch (tag) {
        .exponential => try pcdist.parseExponential(ContDist, scanner, stderr),
        .pareto => try pcdist.parsePareto(ContDist, scanner, stderr),
        .uniform => try pcdist.parseUniform(ContDist, scanner, param_name, stderr),
        .constant => try pcdist.parseConstant(ContDist, scanner, param_name, stderr),
        .normal => dist: {
            const d = try pcdist.parseNormal(ContDist, scanner, stderr);
            try stderr.print("parameter '{s}' could be negative, as 'normal' is not strictly positive\n", .{param_name});
            break :dist d;
        },
    };

    if (try scanner.next() != Token.object_end) return error.UnexpectedToken;
    return dist;
}

// This distribution is not used. and if it were, we would need the typed to be inferred. This is action as life is tought
// this is very very cool but i am not interested on this. It MUST be a categorical, therefore we can directly call
// parse categorical
// pub fn parseDiscreteDist(gpa: Allocator, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{WriteFailed})!DiscDist(f32, usize) {
//     if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

//     const name_tok = try scanner.next();
//     if (name_tok != Token.string) return error.UnexpectedToken;

//     const Tag = std.meta.Tag(DiscDist(f32, usize));
//     const tag = std.meta.stringToEnum(Tag, name_tok.string) orelse {
//         try stderr.print("unknown discrete distribution: '{s}'\n", .{name_tok.string});
//         return error.UnknownDistribution;
//     };

//     const dist = switch (tag) {
//         .categorical => try pddist.parseCategorical(gpa, scanner, stderr),
//         .constant => return error.UnknownDistribution,
//         .ecdf => return error.UnknownDistribution,
//     };

//     if (try scanner.next() != Token.object_end) return error.UnexpectedToken;
//     return dist;
// }

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

pub fn parseUserPolicyCategorical(gpa: std.mem.Allocator, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!stats.Categorical(f32, Action) {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;
    var weights: std.ArrayList(f32) = .empty;
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
                const w = try std.fmt.parseFloat(f32, el.number);
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

    const weights_dup = try gpa.dupe(f32, weights.items);
    errdefer gpa.free(weights_dup);
    const data_dup = try gpa.dupe(Action, data.items);
    errdefer gpa.free(data_dup);

    return try stats.Categorical(f32, Action).init(gpa, weights_dup, data_dup);
}

pub fn readDistTag(scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{WriteFailed})!DistTag {
    const tok = try scanner.next();
    if (tok != Token.string) return error.UnexpectedToken;
    return std.meta.stringToEnum(DistTag, tok.string) orelse {
        try stderr.print("users: unknown distribution tag '{s}'\n", .{tok.string});
        return error.UnknownDistribution;
    };
}

