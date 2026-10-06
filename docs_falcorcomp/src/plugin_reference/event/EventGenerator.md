# Event generation (`EventGenerator`)

This render pass turns the brightness change $\Delta L$ of each frame into events: the output is the signed number
of events per pixel, positive where the brightness rose by multiples of the threshold $C$, negative where it fell.

- `probabilistic`: $\lfloor |\Delta L| / C \rfloor$ events, plus one more with probability equal to the remaining
  fraction, with the sign of $\Delta L$. A real sensor's reference brightness is unknown, so its distance to the
  next threshold is modeled as uniform; then a change $\Delta L$ crosses $|\Delta L| / C$ thresholds on average, and
  frames are independent. Each pixel and frame draws its own random number.
- `accumulate`: each pixel keeps $L - L_\mathrm{ref}$, the brightness since its last event. Every frame adds
  $\Delta L$, emits $n = \operatorname{trunc}((L - L_\mathrm{ref}) / C)$ events and moves $L_\mathrm{ref}$ by $nC$.
  Errors in $\Delta L$ add up over time in this mode.

With an [`EventDifference`](EventDifference.md) that averages several executions per frame (`subframes`), events
are generated once, when the frame completes; the executions in between output no events. Each generator follows the
`EventDifference` that feeds it, so several chains can share a graph. Accumulate the output over executions for an
event image of a time window, or turn it into an event list (pixel, frame, polarity) in Python. A non-finite
$\Delta L$ (NaN or infinity) makes no events and does not enter the accumulated brightness.

## Parameters

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `mode`
  - string
  - `probabilistic` or `accumulate`. (Default: `probabilistic`)
* - `threshold`
  - float
  - Event threshold $C$ on $\Delta L$; real sensors have 0.1 to 0.5. (Default: `0.2`)
* - `seed`
  - integer
  - Offsets the random numbers of `probabilistic`. (Default: `0`)
```

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `deltaL` (input)
  - Brightness change of the frame, from [`EventDifference`](EventDifference.md) or [`EventSVGF`](EventSVGF.md).
* - `events` (output)
  - Signed event count of the last frame, R32Float.
```

From Python: `reset()` clears the per-pixel state of `accumulate` and restarts the random numbers.

## Example

```python
graph.create_pass("Events", "EventGenerator", {"mode": "probabilistic", "threshold": 0.2})
graph.add_edge("Difference.deltaL", "Events.deltaL")
graph.mark_output("Events.events")
```
