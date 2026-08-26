# jemalloc (prebuilt static lib)

The archive is a 30 MB build artifact and is **not** committed to git.
Put it in this directory under the versioned name so `build.zig` can find it:

    libjemalloc-5.3.1-144-ge36a0fa5.a

`build.zig` checks for exactly that filename and fails with a clear error if it
is missing, so the version is enforced by the filename.

## Regenerate

From a jemalloc checkout (this repo pins `5.3.1-144-ge36a0fa5`):

    ./autogen.sh --enable-static --disable-shared --with-jemalloc-prefix= --disable-cxx
    make -j$(nproc)
    cp lib/libjemalloc.a <this-dir>/libjemalloc-5.3.1-144-ge36a0fa5.a

`--with-jemalloc-prefix=` makes jemalloc export plain `malloc`/`free`/`realloc`/…
so linking the archive overrides glibc's allocator.
