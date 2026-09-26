# Swarminer

A swarm quarry for **CC:Tweaked**. One master turtle places worker turtles, gives
each of them two ender chests, and assigns each worker a strip of the area.
Each worker mines its strip in the same three-layers-per-pass pattern as the
built-in `excavate` program. It does not return to the surface: it empties
its inventory into a *dump* ender chest and refuels from a *fuel* ender chest
wherever it is.

| File         | Runs on        | Purpose                                            |
|--------------|----------------|----------------------------------------------------|
| `master.lua` | master turtle  | Places the workers, hands out jobs, shows a status screen |
| `worker.lua` | worker turtles | Mines one strip, dumps items and refuels through ender chests |

## Requirements

- CC:Tweaked, with the **EnderStorage** mod (or another mod whose ender chests
  work with hoppers and turtles). Vanilla ender chests do not accept items
  from turtles, so they do not work.
- **Master:** a mining turtle (pickaxe) with a wireless modem. With
  `master dig`, the pickaxe lets it dig through terrain on the way.
- **Workers:** mining turtles (pickaxe) with a wireless modem.
- **For `master dig` only:** a working GPS constellation. GPS is not needed
  when you place the master by hand; the workers never need it.
- **For large areas:** use **ender modems** on the master, on the workers and
  on the GPS hosts. An ordinary wireless modem reaches only 64 blocks (more at
  high altitude), so workers far along a 512-block area would drop out of
  contact. They would keep mining, but the status screen and recall would
  not reach them.

## One-time setup of the workers

On each worker turtle:

```
wget https://raw.githubusercontent.com/naverene/swarminer/master/worker.lua worker.lua
worker install
```

`worker install` copies the program to `startup.lua` and gives the turtle a
label. Because a labelled turtle keeps its files when it is broken, you can
now pick the worker up.

Put `master.lua` on the master turtle in the same way.

## Loading the master

| Slot  | Contents |
|-------|----------|
| 1–14  | Worker turtles, one per slot |
| 15    | Dump ender chests, one per worker, all set to your "items" colours |
| 16    | Fuel ender chests, one per worker, all set to your "fuel" colours |

Connect the item frequency to your storage system, and keep the fuel
frequency supplied with coal, charcoal, coal blocks, or another fuel.

## Mining an area at given coordinates

```
master dig <x> <y> <z> <sizeX> <sizeZ> <depth> [workers]
```

For example, `master dig 1000 64 -2000 512 512 0` mines x 1000–1511 and
z −2000 to −1489, from layer 64 down to bedrock.

- `x y z` is the top north-west corner block of the area. The area extends
  `sizeX` blocks east (+x) and `sizeZ` blocks south (+z).
- The area includes layer `y` and goes down `depth` layers. `0` means
  "until bedrock".

After you confirm, the master works out its position and facing by GPS,
climbs a few blocks above the higher of its start and destination, and
flies there. It digs through any obstacle it can, and climbs over any it
cannot. It then parks at `x-1, y+1, z` facing east and deploys the
workers. The workers' strips run north–south across the Z axis, and each
strip is `sizeX` blocks long.

The master needs fuel for the journey. Before it sets off, it checks the
distance. If it is short of fuel and one of slots 1–14 is empty, it tops up
from one of its fuel ender chests. Otherwise, it stops and tells you how
much fuel it needs.

## Mining where the master stands

Place the master on the ground at one corner of the area, facing along its
length. Then run:

```
master <width> <length> <depth> [workers]
```

- The area starts at the block in front of the master. It extends `length`
  blocks forward and `width` blocks to the master's **right**.
- Digging starts at the layer below the master and goes down `depth` layers.
  A depth of `0` means "until bedrock or another unbreakable block".
- The width is divided into one strip per worker. The number of workers is
  the smallest of: the turtles loaded, the chests loaded, the width, and the
  optional `workers` argument.

The master places the workers one at a time, starting with the farthest
strip. Each worker travels along the row in front of the master to its
strip and starts mining. After the last worker is out, the master shows a
status screen:

```
Swarminer 16x32x40  4 workers
#12  12-15 mine    37%  4211 mining y=-14
#11   8-11 mine    35%  4480 unloading
...
1/4 done  [R]ecall  [Q]uit
```

Press **R** to call every worker back, or **Q** to leave the status screen.
The workers keep mining after you leave. Use `master monitor` to open the
status screen again, and `master recall` to call the workers back from the
command line.

When a worker finishes, it returns to the top of its strip, which is on the
row in front of the master, and empties anything left in its inventory.
Collect the workers from there.

## Large areas (such as 512 × 512)

- The master holds at most 14 workers, so a 512-wide area is split into
  strips about 37 blocks wide and 512 blocks long.
- A worker takes roughly one second per column for every three layers.
  That is about five hours per three layers for a 37 × 512 strip. At that
  rate, a 512 × 512 area 60 layers deep takes several days of in-game
  running. This is an estimate, not a measurement.
- Everything the workers and the master occupy must stay chunk-loaded
  (see below). A 512 × 512 area covers 32 × 32 chunks.

## Restarts and chunk loading

Every worker saves its job and position to disk after each move. If a worker
restarts (for example, after a chunk unload or a server restart), it resumes
where it stopped. To check whether an interrupted move actually happened, the
worker compares its fuel level with the level it saved before the move. It
also picks up any ender chest that was still placed when it stopped.

Unloaded chunks still stop the turtles. For large areas, keep the area
chunk-loaded (for example, with a chunk-loader mod or a player nearby) so
that the workers do not stop partway through. This also applies to the
master's journey with `master dig`: if the master leaves the loaded chunks,
it stops until those chunks load again. If that happens, run the same
`master dig` command again after it restarts. It relocates itself by GPS
and continues the journey.

## Settings

The settings are at the top of `worker.lua`:

| Setting           | Default | Meaning |
|-------------------|---------|---------|
| `MIN_FUEL`        | 200     | Refuel when the fuel level falls below this |
| `REFUEL_TARGET`   | 5000    | Refuel up to this level (capped at the turtle's fuel limit) |
| `DUMP_SLOT`       | 15      | Slot for the dump ender chest |
| `FUEL_SLOT`       | 16      | Slot for the fuel ender chest |
| `STATUS_INTERVAL` | 5       | Seconds between status reports to the master |

## Notes

- Ender chests are always placed directly above or below the worker. They are
  never placed to the side, where they could end up in a neighbouring strip.
- If a worker meets an unbreakable block partway through a layer, it stops
  mining and returns, as `excavate` does. With `depth 0`, this normally
  happens at bedrock. To stop cleanly above bedrock, give an exact depth.
- `excavate.lua`, `altExcavate.lua`, `command-module.lua`, and
  `swarm-miner.lua` are the earlier experiments. The swarm itself does not
  use them.
