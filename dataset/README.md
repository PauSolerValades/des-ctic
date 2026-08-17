# Dataset Creation

This project handles dataset creation to analyze the simulation outputs. The following document describes the contents, which not all might be rellevant for anything but we are trying to be exhaustive.

## Project structure

To create the datasets, we use DuckDB. The `main.go` program just compiles executables to substitute the names of the files in the queries, which are a template. In the case of the cascades, the go program does not use DuckDB, but computes the structural virality with code, and writes it as parquet files.

## Datasets

This section defines all 9 dataset outputs, with each own metric and stuff.


### Run Metrics

Global per-run metrics. Mirrors the `SimMetrics` structure from the simulation for validation.
One row per run.

Features:
- run_id (pk)
- total_posts_created
- total_reposts
- total_likes
- total_ignores
- total_interactions: reposts + likes + ignores
- conversion_rate: (reposts + likes) / interactions
- total_sessions
- total_boredom_ends: session ends with backlog = 0
- total_max_duration_ends: session ends with backlog > 0
- total_swaps: timeline swaps
- duration: simulation duration

### Users Dataset

Per-user aggregates built from sessions.parquet and the raw traces. One row per user per run.

Features:
- run_id (pk)
- user_id (pk)
- num_sessions
- total_reposts
- total_likes
- total_actions: reposts + likes
- total_posts_created
- total_swaps: how many times the timeline was refreshed
- avg_session_length
- total_online_time: sum of all session durations
- boredom_ended_sessions: how many sessions ended with an empty backlog


### Sessions Dataset

One row per session. Timestamps, duration, and per-session action counts.

Features:
- run_id (pk)
- user_id (pk)
- session_num (pk): session index per user within a run
- start_time
- end_time
- duration: end_time - start_time
- ended_by_boredom: true if the session ended with an empty backlog
- total_actions: likes + reposts + ignores during this session
- total_likes
- total_reposts
- total_ignores


### Post Metrics

Per-post metric breakdown.

Features:
- run_id (pk)
- post_id (pk)
- author_id: user_id from creation event
- total_reposts
- total_likes
- total_ignores
- conversion_rate: (reposts + likes) / (reposts + likes + ignores)

### Raw Post Lifetime Analysis Dataset

This is the dataset that will be used to generate the real lifetime post dataset, with aggregated metrics.

Features:
- run_id (pk)
- post_id (pk)
- author_id: user_id from the creation event
- post_creation_time
- reposter_id: user_id of who reposted the post.
- parent_id (pk): where the reposted id received the post. 
- propagated_time: when the post arrived to the reposter_id queue
- repost_time: when the repost over post_id was performed.
- sitting_in_timeline: how much time the post_id was in a timeline before being reposted (repost_time - propagated_time)
- global_gap: (time of the last repost of this post disregarding parent_id) - (time of the current repost). NULL for the first repost of the post.
- topology_gap: (time of the last repost coming from parent_id) - (time of the current repost). NULL for the first repost from each parent.

### Post Lifetime Dataset 
Computation of the normal aggregated metrics of post lifetime analysis. This is obtained from the global_gap metric from the upper dataset, so it's technically not raw.

Features:
- run_id (pk)
- post_id (pk)
- author_id
- creation_time
- last_repost
- T_50: time from creation to getting the 50% of total reposts.
- T_95: time from creation to getting the 95% of total reposts.
- T_99: time from creation to getting the 99% of total reposts.
- time_to_peak: time from creation to the maximum concentration of reposts per peak 

### Cascade Dataset
About cascade general metrics we can measure the following:
- run_id
- post_id
- cascade_depth
- cascade_size (cardinal)
- max_out_degree:
- structural_virality

We can arrive further with dataset cascade anaylsis if we start dissecting the cascade. Consider the following repost cascade for a single post:

```
        [R]                     depth 0 (root)
       /  |  \
      A   B   C                 depth 1
     / \  |   |
    D   E F   G                 depth 2
   / \     |   |
  H   I    J   K                depth 3 (leaves)
```

Each node is a repost event. Edges point from parent to child (who reposted from whom). Leaves (H, I, E, J, K) are users who received the post but never reposted it.

#### Broadcast Group Analysis

We define a groadcast group as the set of all reposts that share the same `parent_id`. It captures a single node broadcasting to its audience and measures how fast that audience picks up the content. In essence, is a subtree analysis of the cascade tree.

In the graph above, the broadcast groups are:

| parent | children | size | topology_gaps |
|--------|----------|------|---------------|
| R      | A, B, C  | 3    | A→B, B→C      |
| A      | D, E     | 2    | D→E           |
| B      | F        | 1    | *(no gaps)*   |
| C      | G        | 1    | *(no gaps)*   |
| D      | H, I     | 2    | H→I           |
| F      | J        | 1    | *(no gaps)*   |
| G      | K        | 1    | *(no gaps)*   |

Only groups with ≥2 children produce meaningful topology gaps. A group of size 1 contributes no gap signal.

Features:
- Broadcast speed: mean topology_gap. Does this user have a fast or slow audience?
- Broadcast decay: do gaps grow over time within the group? Later children taking longer suggests the parent's reach is dying locally. This is a clean "speed to death" signal: same parent, same audience, only time is changing.
- Broadcast size: number of children per parent. Combines with speed to identify superspreaders (large + fast) vs dead branches (small + slow).

Dataset schema (one row per broadcast group):
- run_id (pk)
- post_id (pk): this is the cascade_id
- parent_id (pk): this is the parent within the cascade
- broadcast_size: number of children
- mean_topology_gap
- median_topology_gap
- topology_gap_trend: slope of gaps over time (positive = slowing down / decaying)
- first_child_time: repost time of first child
- last_child_time: repost time of last child
- *(optional)* subtree_size: total nodes in the subtree rooted at this parent (including the parent). Useful for weighting broadcast groups by their contribution to the cascade.
- *(optional)* subtree_structural_virality: structural virality computed on the full subtree rooted at this parent. Comparing this to the cascade-level SV reveals *where* the cascade became viral — a parent whose subtree_SV ≫ cascade_SV is the catalyst branch.

Computing `subtree_size` and `subtree_structural_virality` for every node simultaneously is an O(n) single post-order traversal over the cascade tree (see edge-contribution DP in implementation notes).

#### Root-to-Leaf Path Analysis

We can define root-to-leaf path as a full chain from the original post (root) to a user who never reposted it (a leaf). It captures end-to-end traversal of information through the social graph. This is natural to wonder considering the variable topology_gap, which the path can be reconstructed with access to the topology.

In the graph above, the paths are:

| path            | depth | total time       |
|-----------------|-------|------------------|
| R → A → D → H   | 3     | t(H) − t(R)     |
| R → A → D → I   | 3     | t(I) − t(R)     |
| R → A → E       | 2     | t(E) − t(R)     |
| R → B → F → J   | 3     | t(J) − t(R)     |
| R → C → G → K   | 3     | t(K) − t(R)     |

Measure per path:
- Traversal speed: total time / depth. Normalizes for comparability across paths of different lengths.
- Inter-hop trend: do gaps between hops grow along the path? (deceleration = dying branch).
- Depth vs. speed correlation: do deeper paths propagate faster or slower?

Features:
- run_id (pk)
- post_id (pk)
- leaf_user_id: which user finishes the path
- path_depth
- path_total_time: t(leaf) − t(root)
- traversal_speed: path_total_time / path_depth
- hop_gaps: ordered list of inter-hop times along the path
- gap_trend: slope of hop gaps (positive = deceleration toward leaf)

_Caution_: root-to-leaf paths are not independent, unlike broadcast groups which don't share data. Every parent's broadcast pattern is measured once. Paths can be reconstructed from broadcast groups, but not the reverse.
## TODO:

Know architecutre fixes for DuckDB based cascade generation:
- Techincally every script needs different files. If instead of go we used the zig build system to create different executables with different inputs, every file could be more adapted. It's not convenience, but a pipeline reproducibility thing, as in:
 - users needs session.parquet to execute.
 - not all traces are needed everywhere.
 - cascades should be not there anywhere at all.

Known potential optimizations for cascades:
- This is absolutely sequential: despite every cascade being sorted in the cascade.ssv, they are all loaded into memory (oof) and then processed. the propoer way would involve:
 1. First pass: detect in which lines of the file the cascades finishes.
 2. Create n workers that receive the cascades, and send the results back as channels.
 3. Have three dedicated workers writing to every different type of dataset (3 different ones)
