const std = @import("std");
const Scanner = std.json.Scanner;
const Token = std.json.Token;

const stats = @import("distributions");
const ContDist = stats.ContinuousDistribution;
const DiscDist = stats.DiscreteDistribution;
const Interval = stats.Interval;

const Action = @import("../entities.zig").Action;

const readKeyNumber = @import("parse.zig").readKeyNumber;
const readKeyBool = @import("parse.zig").readKeyBool;

// pub fn parseCategorical(gpa: std.mem.Allocator, scanner: *Scanner) !DiscDist(f32, DataType) {
//     if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;
//     var weights: std.ArrayList(f32) = .empty;
//     defer weights.deinit(gpa);
//     var data: std.ArrayList(DataType) = .empty;
//     defer data.deinit(gpa);
//
//     var parsed_weights = false;
//     var parsed_data = false;
//
//     while (true) {
//         const tok = try scanner.next();
//         if (tok == Token.object_end) break;
//         if (tok != Token.string) return error.UnexpectedToken;
//
//         if (std.mem.eql(u8, tok.string, "weights")) {
//             if (try scanner.next() != Token.array_begin) return error.UnexpectedToken;
//             while (true) {
//                 const el = try scanner.next();
//                 if (el == Token.array_end) break;
//                 const w = try std.fmt.parseFloat(f32, el.number);
//                 try weights.append(gpa, w);
//             }
//             parsed_weights = true;
//         } else if (std.mem.eql(u8, tok.string, "data")) {
//             if (try scanner.next() != Token.array_begin) return error.UnexpectedToken;
//             while (true) {
//                 const el = try scanner.next();
//                 if (el == Token.array_end) break;
//                 if (el != Token.string) return error.UnexpectedToken;
//
//                 const action = std.meta.stringToEnum(DataType, el.string) orelse {
//                     std.debug.print("error", .{});
//                     return error.InvalidField;
//                 };
//                 try data.append(gpa, action);
//             }
//             parsed_data = true;
//         } else {
//             std.debug.print("categorical: unknown param '{s}'\n", .{tok.string});
//             return error.UnknownParameter;
//         }
//     }
//
//     if (!parsed_weights or !parsed_data) return error.MissingField;
//
//     const weights_dup = try gpa.dupe(f32, weights.items);
//     errdefer gpa.free(weights_dup);
//     const data_dup = try gpa.dupe(DataType, data.items);
//     errdefer gpa.free(data_dup);
//
//     return DiscDist(f32, DataType){
//         .categorical = try stats.Categorical(f32, DataType).init(gpa, weights_dup, data_dup),
//     };
// }
//
