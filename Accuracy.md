# Validating accuracy

WoW classic still has the builtin profiler (CVar `scriptProfile`), so we can compare Perfy against it to see how good or bad we are.

## Notes on the builtin profiler

We can make an educated guess on how the builtin profiler probably works based on the APIs it offers:
The core reporting mechanic it provides is that it can tell you how much time a given function used (with or without including subroutines) and how often it was called.
The additional functions about reporting per AddOn or per frame are just aggregations built on top of this.

Since it accurately reports how often a function is called it must be based on tracing each call and not on sampling.
My guess is that it hooks into the Lua VM for handling the opcodes `CALL`, `TAILCALL`, and `RETURN` and then stores the elapsed time and a counter in the Lua object representing the function.
`GetFunctionCPUUsage(func, includeSubroutines)` then just returns these fields for the given function.
This is low overhead and easy to implement but does not allow you to reconstruct the entire call stack as it does not remember which function called which.
Fun fact: the reported time per function has the same granularity as `GetTimePreciseSec()` (100 ns), I don't think that is a coincidence.

Overall the builtin profiler is a bit cumbersome to use because you need the actual function object to query the results and it can't tell you anything about the relation between functions.


## Test setup

Since the builtin profiler is a bit annoying to use we need to look at something that involves only a few functions.
Whatever we are testing also needs to be reproducible because we want to run both profilers independently.
Finally, it should also be somewhat realistic.

DBM-StatusBarTimers' update logic for DBM timers fits this description.
It only has 5 relevant functions, presents a realistic workload (5% of total CPU load in the Gnomeregan example from README.md), and it is reproducible by running `/dbm test` which starts a few timers lasting 60 seconds total.


## Test results

[![FlameGraph of CPU usage](Screenshots/CPU-DBM-Test.png)](https://emmericp.github.io/Perfy/perfy-cpu-dbm-test.svg)

The functions we are looking at are the five largest in the flame graph above: `onUpdate`, `barPrototype:Update`, `DBT:UpdateBars`, `stringFromTimer`, and `AnimateEnlarge`.

The run with the builtin profiler was done without Perfy instrumentation in place and `scriptProfile` was disabled when running Perfy.
The total number of calls to all functions was identical for Perfy and the builtin profiler, and stayed identical across all runs.
It always took exactly 18176 calls to the `onUpdate` handler to run the DBM test mode with my game running at a stable 60 fps.

Each run was repeated 5 times, the table shows the average and standard deviation.

| Function              |      Builtin profiler (µs) |             Perfy (µs) | Discrepancy |
|-----------------------|---------------------------:|-----------------------:|------------:|
| `onUpdate`            |              273740 ± 0.5% |          282690 ± 0.3% |       3.3%  |
| `barPrototype:Update` |              260560 ± 0.6% |          265522 ± 0.3% |       1.9%  |
| `DBT:UpdateBars`      |               98564 ± 0.7% |           94413 ± 1.2% |       4.4%  |
| `stringFromTimer`     |               24465 ± 0.9% |           29985 ± 0.8% |      22.6%  |
| `AnimateEnlarge`      |                2916 ± 1.8% |            2992 ± 1.2% |       2.5%  |

Perfy tends to report a slightly higher CPU usage -- getting an exact match between the two results was not the goal here.
Neither Perfy nor the builtin profiler are perfect, I'm happy that these agree to within a few percent.

Two results are a bit odd an warrant further investigation (TODO):


### DBT:UpdateBars() is reported lower instead of higher

For `DBT:UpdateBars` Perfy reports a lower utilization whereas it reports a higher utilization everywhere else.
My first guess was that this is somehow related to the usage of `table.sort`, but the comparison functions are only called a total of 82 times with a runtime of 314 µs including overhead (19 µs excluding overhead).

TODO: Investigate more.
Another hypothesis is that this is related to this function can show up multiple times in a stack trace, maybe the logic to calculate total time is wrong in either Perfy or the builtin profiler.

### stringFromTimer() has a 22% discrepancy

This is a simple leaf function that formats the remaining time into a human-readable format.

```
local function stringFromTimer(t)
	if t <= DBT.Options.TDecimal then
		return ("%.1f"):format(t)
	elseif t <= 60 then
		return ("%d"):format(t)
	else
		return ("%d:%0.2d"):format(t / 60, math.fmod(t, 60))
	end
end
```

Two hypotheses to follow up on:

1. Perfy's accounting of overhead when tracing a tail call is slightly off -- it doesn't correctly attribute the function call into Perfy as overhead (see the implementation of `Perfy_Trace_Leave` in the AddOn for why this is the case).

2. Perfy sees this is a single leaf function. The builtin profiler accounts for `string.format` and `math.fmod` separately, maybe this is related.


