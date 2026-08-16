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

const Precision = @import("../SimConfig.zig").Precision;
const UserConf = @import("../SimConfig.zig").UserConf;
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

pub fn parseNonNegativeContinuousDist(scanner: *Scanner, stderr: *Io.Writer, param_name: []const u8) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!NNContDist(Precision) {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    const name_tok = try scanner.next();
    if (name_tok != Token.string) return error.UnexpectedToken;

    const Tag = std.meta.Tag(NNContDist(Precision));
    const tag = std.meta.stringToEnum(Tag, name_tok.string) orelse {
        try stderr.print("unknown continuous distribution: '{s}'\n", .{name_tok.string});
        return error.UnknownDistribution;
    };

    const dist = switch (tag) {
        .exponential => try pcdist.parseExponential(NNContDist(Precision), scanner, stderr),
        .pareto => try pcdist.parsePareto(NNContDist(Precision), scanner, stderr),
        .uniform => try pcdist.parseUniform(NNContDist(Precision), scanner, param_name, stderr),
        .constant => try pcdist.parseConstant(NNContDist(Precision), scanner, param_name, stderr),
        .lognormal => try pcdist.parseLognormal(NNContDist(Precision), scanner, stderr),
        .weibull => try pcdist.parseWeibull(NNContDist(Precision), scanner, stderr),
        .gamma => try pcdist.parseGamma(NNContDist(Precision), scanner, stderr),
        .gpareto => try pcdist.parseGeneralizedPareto(NNContDist(Precision), scanner, stderr),
    };

    if (try scanner.next() != Token.object_end) return error.UnexpectedToken;
    return dist;
}

pub fn parseContinuousDist(scanner: *Scanner, stderr: *Io.Writer, param_name: []const u8) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!ContDist(Precision) {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    const name_tok = try scanner.next();
    if (name_tok != Token.string) return error.UnexpectedToken;

    const Tag = std.meta.Tag(ContDist(Precision));
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
// pub fn parseDiscreteDist(gpa: Allocator, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{WriteFailed})!DiscDist(Precision, usize) {
//     if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

//     const name_tok = try scanner.next();
//     if (name_tok != Token.string) return error.UnexpectedToken;

//     const Tag = std.meta.Tag(DiscDist(Precision, usize));
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

fn readDistTag(scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{WriteFailed})!DistTag {
    const tok = try scanner.next();
    if (tok != Token.string) return error.UnexpectedToken;
    return std.meta.stringToEnum(DistTag, tok.string) orelse {
        try stderr.print("users: unknown distribution tag '{s}'\n", .{tok.string});
        return error.UnknownDistribution;
    };
}

const Field = blk: {
    const fields = @typeInfo(UserConf).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    var vals: [fields.len]u8 = undefined;
    for (fields, 0..) |f, i| {
        names[i] = f.name;
        vals[i] = i;
    }
    break :blk @Enum(u8, .exhaustive, &names, &vals);
};

pub fn parseUsers(gpa: Allocator, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })![]UserConf {
    if (try scanner.next() != Token.array_begin) return error.UnexpectedToken;

    var users: ArrayList(UserConf) = .empty;
    defer users.deinit(gpa);

    var index: usize = 1;
    while (true) {
        const tok = try scanner.next();
        if (tok == Token.array_end) break;
        if (tok != Token.object_begin) return error.UnexpectedToken;

        var user: UserConf = undefined;
        const num_fields: usize = @typeInfo(Field).@"enum".fields.len;
        var have: std.StaticBitSet(num_fields) = .empty;

        while (true) {
            const key = try scanner.next();
            if (key == Token.object_end) break;
            if (key != Token.string) return error.UnexpectedToken;

            const field = std.meta.stringToEnum(Field, key.string) orelse {
                try stderr.print("Parameter '{s}' is not an valid user parameter\n", .{key.string});
                return error.UnknownParameter;
            };
            have.set(@intFromEnum(field));

            switch (field) {
                .session_duration => user.session_duration = try readDistTag(scanner, stderr),
                .inter_session_time => user.inter_session_time = try readDistTag(scanner, stderr),
                .session_params_path => user.session_params_path = try readKeyString(gpa, scanner),
                .gap_params_path => user.gap_params_path = try readKeyString(gpa, scanner),
                .ecdf_post_creation_path => user.ecdf_post_creation_path = try readKeyString(gpa, scanner),
                .ecdf_offset_creation_path => user.ecdf_offset_creation_path = try readKeyString(gpa, scanner),
                .probability => user.probability = try readKeyNumber(scanner, Precision),
            }
        }

        if (have.count() != num_fields) {
            inline for (@typeInfo(Field).@"enum".fields) |f| {
                if (!have.isSet(f.value)) try stderr.print("missing field '{s}' in item {d}\n", .{ f.name, index });
            }
            return error.MissingField;
        }
        try users.append(gpa, user);
        index += 1;
    }

    return users.toOwnedSlice(gpa);
}
