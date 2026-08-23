# The simulation

There is a lot to be said about this program, and I don't want to do it rn to be honest.

## TODO: 
[x] It's absolutely overkill to use a heap for users. Is a stack, and having a good draw strategy (chekc the actual time) will be crazy fast according to an LLM hacky code.
[x] Remove the guard at propagatePost: that check is super expensive and happend per every follower, as well as being redundant with the check in `handleAction` proper check. This is backed up by `perf` as the most important improvement.
[ ] CalendarQueue or succedaneous.
[ ] Change all `AutoHashMaps` with `Set` in the library i contributed. That will be perfect.
[ ] Memory Pool for the UserTimelines. It is definetly not hurting performance. Probably would make sense to wait for 0.17.0 to do that.
