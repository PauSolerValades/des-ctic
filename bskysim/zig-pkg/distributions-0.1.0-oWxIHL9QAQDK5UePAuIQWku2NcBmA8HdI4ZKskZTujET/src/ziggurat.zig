/// Iplementation of the ziggurat algorithm translating it from rand_dist from Rust
const std = @import("std");
const assert = std.debug.assert;
const Random = std.Random;
const Table = @import("tables.zig").Table;

// inline tells the compiler that *const fn(f64) f64 is not a funciton pointer, but to generate a different function per type!kk
pub inline fn ziggurat(
    comptime Precision: type,
    rng: Random, 
    comptime table: *const Table(Precision), 
    comptime pdf: *const fn(Precision) Precision, 
    comptime zeroCase: *const fn(Random, Precision) Precision, 
    symmetric: bool
) Precision {
    assert(Precision == f64 or Precision == f32);

    const Uint = if (Precision == f64) u64 else u32;
    const mantissa_shift = if (Precision == f64) 12 else 9;
    
    const exp_0: Uint = if (Precision == f64) 0x3FF0000000000000 else 0x3F800000;
    const exp_1: Uint = if (Precision == f64) 0x4000000000000000 else 0x40000000;
    
    const offset = 1.0 - std.math.floatEps(Precision) / 2.0;
    
    while (true) {
        // we need two random numbers: one for the recangle (0-255) and another for the index (-1 and 1)
        // instead of two calls, we generate one number f64, we split it in the middle and then cast two 
        // numbers from there. optimal as fuck
        
        const bits = rng.int(Uint);
        
        // we extract 8 bits (0..255 = 2^8, because the table is 256 long).
        // we AND the number with 0xff = 0b 1111 1111.
        const i = @as(usize, bits) & 0xff; // number between 0 and 256

        // discard the 12 lower bits of bits. those 52 will be the mantissa of the float.
        // now we are missing 12 bits. According to IEEE754, a float is:
        // 1 bit sign (hardware will always assume it), 11 exponent and 52 mantissa.
        // If the distribution is symmetric, we want the exponent to be between 2 and 3
        // Between 2 and 3 need the coma shifted once, so 1023 + 1 = 1024, that is the following magic
        // number in hexadecimal + 52 zeroes: 0011 1111 1111 0000 0000 0000 ... zeros
        // if not, it's just 1023, which is exponent 0

        const mantissa = (bits >> mantissa_shift);
        
        const u = if (symmetric) @as(Precision, @bitCast(exp_1 | mantissa)) - 3 else @as(Precision, @bitCast(exp_0 | mantissa)) - offset;
         
        const x = u * table.x[i]; // x is our randnom number
        const test_x = if (symmetric) @abs(x) else x;

        // algebraically equivalent to |u| < x_tab[i+1]/x_tab[i] (or u < x_tab[i+1]/x_tab[i])
        if (test_x < table.x[i+1]) { // if it's inside the rectangle, we are done
            return x;
        }  
    
        // if x wasn't in the rectangle, it might be on the first recangle (special case)
        if (i==0) {
            return zeroCase(rng, u);
        }
       
        // or in a boundary
        const y_diff = table.f[i] - table.f[i+1];
        if (table.f[i+1] + (y_diff * rng.float(f64)) < pdf(x)) {
            return x;
        }
    } 
}

