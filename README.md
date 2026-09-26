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
- **Master:** a wireless turtle. A pickaxe is optional; it is only needed if
  the block in front of the master must be cleared.
- **Workers:** wireless mining turtles (pickaxe and wireless modem).
- GPS is **not** required. All coordinates are relative to the master.

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

## Running

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

## Restarts and chunk loading

Every worker saves its job and position to disk after each move. If a worker
restarts (for example, after a chunk unload or a server restart), it resumes
where it stopped. To check whether an interrupted move actually happened, the
worker compares its fuel level with the level it saved before the move. It
also picks up any ender chest that was still placed when it stopped.

Unloaded chunks still stop the turtles. For large areas, keep the area
chunk-loaded (for example, with a chunk-loader mod or a player nearby) so
that the workers do not stop partway through.

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
