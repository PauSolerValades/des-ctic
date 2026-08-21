const std = @import("std");
const Io = std.Io;
const Scanner = std.json.Scanner;
const Token = std.json.Token;

const stats = @import("distributions");
const Interval = stats.Interval;

const ParseError = @import("parse.zig").ParseError;
const JsonScannerError = @import("parse.zig").JsonScannerError;
const readKeyNumber = @import("parse.zig").readKeyNumber;
const readKeyBool = @import("parse.zig").readKeyBool;

pub fn parseExponential(comptime Dist: type, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!Dist {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    var mean: ?f32 = null;
    var rate: ?f32 = null;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        const num = try readKeyNumber(scanner, f32);
        if (std.mem.eql(u8, tok.string, "mean")) {
            mean = num;
        } else if (std.mem.eql(u8, tok.string, "rate")) {
            rate = num;
        } else {
            try stderr.print("exponential: unknown param '{s}'\n", .{tok.string});
            return error.UnknownParameter;
        }
    }

    if (mean) |m| return Dist{ .exponential = stats.Exponential(f32).initMean(m) };
    if (rate) |r| return Dist{ .exponential = stats.Exponential(f32).init(r) };
    try stderr.print("exponential: missing required param 'mean' or 'rate'\n", .{});
    return error.MissingField;
}

pub fn parsePareto(comptime Dist: type, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!Dist {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    var shape: ?f32 = null;
    var scale: ?f32 = null;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        const num = try readKeyNumber(scanner, f32);
        if (std.mem.eql(u8, tok.string, "shape")) {
            shape = num;
        } else if (std.mem.eql(u8, tok.string, "scale")) {
            scale = num;
        } else {
            try stderr.print("pareto: unknown param '{s}'\n", .{tok.string});
            return error.UnknownParameter;
        }
    }

    if (shape == null or scale == null) {
        try stderr.print("pareto: missing required param (need 'shape' and 'scale')\n", .{});
        return error.MissingField;
    }
    return Dist{ .pareto = stats.Pareto(f32).init(shape.?, scale.?) };
}

pub fn parseUniform(comptime Dist: type, scanner: *Scanner, param_name: []const u8, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!Dist {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    var min: ?f32 = null;
    var max: ?f32 = null;
    var interval: ?Interval = null;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        if (std.mem.eql(u8, tok.string, "min")) {
            min = try readKeyNumber(scanner, f32);
            if (min.? < 0) try stderr.print("warning - min ({d}) is negative in '{s}', this could lead to negative times", .{ min.?, param_name });
        } else if (std.mem.eql(u8, tok.string, "max")) {
            max = try readKeyNumber(scanner, f32);
            if (max.? < 0) try stderr.print("warning - max ({d}, and therefore min too) is negative in '{s}', this could lead to negative times", .{ max.?, param_name });
        } else if (std.mem.eql(u8, tok.string, "interval")) {
            const s = (try scanner.next()).string;
            interval = std.meta.stringToEnum(Interval, s) orelse {
                try stderr.print("uniform: invalid interval '{s}' in '{s}'\n", .{ s, param_name });
                return error.InvalidInterval;
            };
        } else {
            try stderr.print("uniform: unknown param '{s}'\n", .{tok.string});
            return error.UnknownParameter;
        }
    }

    if (min == null or max == null or interval == null) {
        try stderr.print("uniform: missing required param (need 'min', 'max' and 'interval')\n", .{});
        return error.MissingField;
    }

    // we know here that they are definetly not null
    if (min.? > max.?) {
        try stderr.print("warning- min is bigger than max in '{s}'", .{param_name});
        return error.InvalidInterval;
    }
    return Dist{ .uniform = stats.Uniform(f32).init(min.?, max.?, interval.?) };
}

pub fn parseConstant(comptime Dist: type, scanner: *Scanner, param_name: []const u8, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!Dist {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    var value: ?f32 = null;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        if (std.mem.eql(u8, tok.string, "value")) {
            value = try readKeyNumber(scanner, f32);
            if (value.? < 0) try stderr.print("warning - value of 'constant' is negative in '{s}'", .{param_name});
        } else {
            try stderr.print("constant: unknown param '{s}' in '{s}'\n", .{ tok.string, param_name });
            return error.UnknownParameter;
        }
    }

    if (value == null) {
        try stderr.print("constant: missing required param 'value'\n", .{});
        return error.MissingField;
    }
    return Dist{ .constant = stats.Constant(f32).init(value.?) };
}

pub fn parseNormal(comptime Dist: type, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!Dist {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    var mean: ?f32 = null;
    var sd: ?f32 = null;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        const num = try readKeyNumber(scanner, f32);
        if (std.mem.eql(u8, tok.string, "mean")) {
            mean = num;
        } else if (std.mem.eql(u8, tok.string, "sd")) {
            sd = num;
        } else {
            try stderr.print("normal: unknown param '{s}'\n", .{tok.string});
            return error.UnknownParameter;
        }
    }

    if (mean == null or sd == null) {
        try stderr.print("normal: missing required param (need 'mean' and 'sd')\n", .{});
        return error.MissingField;
    }
    return Dist{ .normal = stats.Normal(f32).init(mean.?, sd.?) };
}

pub fn parseLognormal(comptime Dist: type, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!Dist {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    var meanlog: ?f32 = null;
    var sdlog: ?f32 = null;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        const num = try readKeyNumber(scanner, f32);
        if (std.mem.eql(u8, tok.string, "meanlog")) {
            meanlog = num;
        } else if (std.mem.eql(u8, tok.string, "sdlog")) {
            sdlog = num;
        } else {
            try stderr.print("lognormal: unknown param '{s}'\n", .{tok.string});
            return error.UnknownParameter;
        }
    }

    if (meanlog == null or sdlog == null) {
        try stderr.print("lognormal: missing required param (need 'meanlog' and 'sdlog')\n", .{});
        return error.MissingField;
    }
    return Dist{ .lognormal = stats.Lognormal(f32).init(meanlog.?, sdlog.?) };
}

pub fn parseWeibull(comptime Dist: type, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!Dist {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    var scale: ?f32 = null;
    var shape: ?f32 = null;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        const num = try readKeyNumber(scanner, f32);
        if (std.mem.eql(u8, tok.string, "scale")) {
            scale = num;
        } else if (std.mem.eql(u8, tok.string, "shape")) {
            shape = num;
        } else {
            try stderr.print("weibull: unknown param '{s}'\n", .{tok.string});
            return error.UnknownParameter;
        }
    }

    if (scale == null or shape == null) {
        try stderr.print("weibull: missing required param (need 'scale' and 'shape')\n", .{});
        return error.MissingField;
    }
    return Dist{ .weibull = stats.Weibull(f32).init(shape.?, scale.?) };
}

pub fn parseGamma(comptime Dist: type, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!Dist {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    var shape: ?f32 = null;
    var rate: ?f32 = null;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        const num = try readKeyNumber(scanner, f32);
        if (std.mem.eql(u8, tok.string, "shape")) {
            shape = num;
        } else if (std.mem.eql(u8, tok.string, "rate")) {
            rate = num;
        } else {
            try stderr.print("gamma: unknown param '{s}'\n", .{tok.string});
            return error.UnknownParameter;
        }
    }

    if (shape == null or rate == null) {
        try stderr.print("gamma: missing required param (need 'shape' and 'rate')\n", .{});
        return error.MissingField;
    }
    return Dist{ .gamma = stats.Gamma(f32).init(shape.?, rate.?) };
}

pub fn parseGeneralizedPareto(comptime Dist: type, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })!Dist {
    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    var location: ?f32 = null;
    var scale: ?f32 = null;
    var shape: ?f32 = null;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        const num = try readKeyNumber(scanner, f32);
        if (std.mem.eql(u8, tok.string, "location")) {
            location = num;
        } else if (std.mem.eql(u8, tok.string, "scale")) {
            scale = num;
        } else if (std.mem.eql(u8, tok.string, "shape")) {
            shape = num;
        } else {
            try stderr.print("gpareto: unknown param '{s}'\n", .{tok.string});
            return error.UnknownParameter;
        }
    }

    if (location == null or scale == null or shape == null) {
        try stderr.print("gpareto: missing required param (need 'location', 'scale' and 'shape')\n", .{});
        return error.MissingField;
    }
    return Dist{ .gpareto = stats.GeneralizedPareto(f32).init(location.?, scale.?, shape.?) };
}
