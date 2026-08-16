# Construct Cascades 

All the important metrics of the simulation are computed from the post cascades $T$. This Zig program has the creation, action and propagate trace binary files and converts them into a single space separated values file with all the cascades from all the runs from the same simulation.

Objective: make the creation of a dataset to analyze not read directly from the traces. So this is just an step of the pipeline.

## Architecture

The amount of traces can get very large and contain multiple runs, therefore the naive approach ---load all traces in memory and parse them to obtain the traces--- has been discarded. This project is divided in two parts:

**From `.bin` to `.ssv`**

Read all the traces from the input folder, and find out how many replications of the simulation are in the folder. In a single run, the creation trace is opened and reads the binary with the size of the `ObjectTrace` imported from the simulation directly as an external module in the build system. Then, the `post_id` is hashed and the result modulus number of buckets, and written as an `.ssv` file. This same process is performed with the Propagation and Action (just the reposts) traces. 

Of course, the buffer for each writer are heap allocated.

**Merge Buckets**

Due to the nice ording trace properties, it is very easy to actually to merge the contents of the buckets.

The structure of a given bucket is contiguous and the following:
1. All post_id creations that ended up in this bucket from all the runs.
2. All propagations, analogous.
3. All reposts, analogous.

From within each group, every entry is time sorted from smaller to biggest, therefore the procedure to obtain all the cascades sorted in ascendent order is to create a hashmap with key `bytes(hash_id) << 32 | bytes(post_id)` and an ArrayList as value to append the actual data. Once all the data is in the arraylist, we sort all the _keys_ of the buffer, as they essentially are unique due to multipliying the `run_id` time $2^32$ + `post_id`, and will give us the cascades in order.

## TODO:

I build this with the pretension to parallelize it, and it's very parallelizeable. I did not do it rn because it's not necessary, it process the 10K dataset in my laptop in under 5s. Also, I did not even bother looking into memory management (eg, with a Arena this is probably going to be much faster, as well as I am sure some Io can have improvements)


