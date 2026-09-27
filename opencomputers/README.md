# Swarminer for OpenComputers

This is the OpenComputers version of Swarminer. It works like the
ComputerCraft version in the main [README](../README.md). A master robot
flies to the work site and places worker robots. Each worker mines its own
strip, emptying its inventory into a *dump* ender chest. It also restocks
from a *fuel* ender chest wherever it is.

| File         | Runs on       | Purpose |
|--------------|---------------|---------|
| `master.lua` | master robot  | Flies to the site, places and switches on the workers, hands out jobs, shows a status screen |
| `worker.lua` | worker robots | Mines one strip, unloads into the dump chest, and takes coal and pickaxes from the fuel chest |

## How this differs from the ComputerCraft version

- **Energy instead of fuel.** Robots run on energy. A worker with a
  **generator upgrade** takes coal or charcoal from the fuel ender chest and
  burns it. Without a generator, the robot waits for solar upgrades or a
  charger to top it up.
- **Tools wear out.** When a worker's pickaxe is nearly worn out, it takes a
  new one from the fuel ender chest and equips it. The worn one goes into the
  dump chest. **Keep spare pickaxes on the fuel frequency** as well as fuel.
- **No GPS.** OpenComputers has no built-in GPS. When you run `master dig`,
  you tell the master where it is and which way it faces. It then tracks
  its position itself and saves it after every move. Next time, it asks
  only to confirm the position it remembers.
- **Switching workers on.** A robot cannot switch another robot on
  directly. `worker install` sets a *wake message* on the worker's network
  card, and the master sends that message after placing the worker. If the
  worker does not start within 20 seconds, the master asks you to switch it
  on yourself.
- **Finding which way a worker faces.** The worker looks around, the master
  steps out of its block for a moment, and the worker looks again. The side
  that opened up is where the master was.
- **Wireless range.** A tier 2 wireless card reaches 400 blocks (by default).
  Workers farther away than that keep mining, but their status does not
  reach the master and they will not hear a recall.

## Building the robots

**Workers** are assembled in the Robot Assembler. Each worker needs:

- a tier 2 or tier 3 case, CPU, memory, hard disk with OpenOS, and the Lua
  BIOS EEPROM;
- a screen and keyboard (needed to type `worker install` once);
- a **wireless network card** (tier 2 for the longest range);
- an **inventory controller upgrade** (required);
- at least one **inventory upgrade** (more upgrades give more room for
  cargo);
- a **generator upgrade** (strongly recommended);
- a **battery upgrade** (recommended).

Give each worker a pickaxe in its tool slot.

The **master** needs the same parts, plus:

- a **screen and keyboard**, for the status screen;
- a pickaxe, used only to clear its parking spot at the work site;
- at least two inventory upgrades if it is to carry many workers.

## Installing

On each worker (with an internet card, or copy the file over on a floppy
disk):

```
wget https://raw.githubusercontent.com/naverene/swarminer/master/opencomputers/worker.lua worker.lua
worker install
```

`worker install` copies the program to `/home/bin`, makes it start when the
robot boots, and sets the wake message. A robot keeps its hard disk contents
when it is broken, so you can then pick the worker up.

On the master:

```
wget https://raw.githubusercontent.com/naverene/swarminer/master/opencomputers/master.lua master.lua
```

## Loading

In a robot with N inventory slots:

| Robot   | Slots 1 … N-2 | Slot N-1 | Slot N |
|---------|---------------|----------|--------|
| Master  | worker robots, with at least one slot left empty | dump ender chests (one per worker) | fuel ender chests (one per worker, plus one for itself) |
| Worker  | mined items (the master hands over the chests) | dump ender chest | fuel ender chest |

Put coal or charcoal **and spare pickaxes** on the fuel frequency, and
connect the dump frequency to your storage system.

## Running

```
master dig <x> <z> <sizeX> <sizeZ> [topY] [bottomY|bedrock] [workers]
```

The command and its questions are the same as in the ComputerCraft
version, with one extra question at the start: the master's own position
and facing.

```
Master's position and facing (x y z north|south|east|west)? 120 64 -35 north
Highest block Y in the work area (include any trees to remove)? 92
Lowest Y to mine down to? (Enter = bedrock) 12
How many workers? (carrying 6, Enter = 6)
```

- **Position:** read it from the F3 screen. It is the block the master
  occupies.
- **Start under open sky.** The master flies at `CRUISE_Y` (default 200)
  and never breaks anything on the way. It goes over obstacles, or around
  them if it cannot go over.
- **Parking:** it parks one block west of the area's corner, just above the
  highest block, facing east. It then deploys the workers.
- **Workers by hand:** you can ask for more workers than the master
  carries. For each extra worker, it asks you to place one in front of it
  (with both chests loaded) and switch it on.

To deploy where the master stands, use `master <width> <length> <depth>
[workers]`. It works as in the ComputerCraft version.

The status screen, `master monitor` and `master recall` also work as in the
ComputerCraft version.

## Restarts

OpenComputers normally keeps programs running through chunk unloads and
server restarts, so robots carry on where they were. A robot that actually
reboots also resumes: the worker saves its job and position after every
move. If the reboot happened in the middle of a move, the worker cannot
tell whether that move completed. It assumes the move did not happen and
prints a warning. If that assumption is wrong, the rest of its strip is
offset by one block.

## Settings

| File         | Setting                       | Default   | Meaning |
|--------------|-------------------------------|-----------|---------|
| `master.lua` | `CRUISE_Y`                    | 200       | The lowest height at which the master flies (use about 130 before Minecraft 1.18) |
| both         | `ENERGY_LOW`, `ENERGY_RESUME` | 0.3, 0.6  | When a robot refuels its generator, and how full it must be before it carries on |
| `worker.lua` | `TOOL_LOW`                    | 0.05      | The durability below which a worker takes a new pickaxe |
| `worker.lua` | `FUEL_PATTERNS`               | coal, coke, blaze_rod | The item names that count as fuel |

## Not yet confirmed in game

These programs were checked against a mock of the OpenComputers API, not in
Minecraft. Each of the following has a fallback, but please check them in a
test world:

1. **Can a robot place a robot?** If it cannot, the master asks you to place
   each worker by hand.
2. **Does the wake message survive the worker being broken and placed
   again?** If it does not, the master asks you to switch each worker on.
3. **Can the master drop items into a worker's inventory?** If it cannot,
   load each worker's two chests yourself (slots N-1 and N) before it is
   deployed. The worker then tells the master it already has them.
4. **Does a chest broken by a robot go into the selected slot?** If it does
   not, the worker searches its inventory for the chest and moves it back.
