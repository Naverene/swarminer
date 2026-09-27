--[[
  Swarminer master for OpenComputers (a robot).

  Required: a wireless network card, an inventory controller upgrade, at least
  one inventory upgrade, and a screen and keyboard. Recommended: a pickaxe
  (to clear its parking spot), a generator upgrade and a battery upgrade.

  Inventory layout (N = the robot's inventory size):
    slots 1..N-2  worker robots (with worker.lua installed); keep at least one
                  slot empty so the master can take fuel for itself
    slot  N-1     dump ender chests (one per worker, all the same colours)
    slot  N       fuel ender chests (one per worker, all the same colours)

  Usage:
    master dig <x> <z> <sizeX> <sizeZ> [topY] [bottomY|bedrock] [workers]
        Fly (at CRUISE_Y or higher, without breaking anything) to the area
        x..x+sizeX-1, z..z+sizeZ-1 and deploy there. The area is mined from
        topY (its highest block) down to bottomY. Anything left off the
        command line is asked for, including where the master is now (it
        remembers its position after that).
    master <width> <length> <depth> [workers]
        Deploy right here: the area starts in the block in front of the
        master and extends <length> blocks forward and <width> blocks to its
        right, from the layer below the master down <depth> layers (0 =
        until bedrock).
    master monitor      reattach to a running job
    master recall       call every worker back
]]

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local robot = require("robot")
local serialization = require("serialization")
local sides = require("sides")
local term = require("term")

local PORT          = 4250
local WAKE_MESSAGE  = "swarminer_wake"
local STATE_FILE    = "/home/.swarminer_master"
local NAV_FILE      = "/home/.swarminer_nav"
local WAKE_TIMEOUT  = 20   -- seconds before asking the player to switch a worker on
local LEAVE_TIMEOUT = 120  -- seconds for a worker to clear the spawn block
local CRUISE_Y      = 200  -- fly at least this high when travelling (use ~130 before 1.18)
local MAX_Y         = 250  -- highest level the master will climb to while travelling
local ENERGY_LOW    = 0.3  -- top up the generator below this fraction of max energy
local ENERGY_RESUME = 0.6  -- when recharging, carry on above this fraction

local args = { ... }

local modem = component.isAvailable("modem") and component.modem
local ic = component.isAvailable("inventory_controller") and component.inventory_controller
local generator = component.isAvailable("generator") and component.generator
if not modem or not modem.isWireless() then error("A wireless network card is required", 0) end
if not ic then error("An inventory controller upgrade is required", 0) end

local SIZE = robot.inventorySize()
local FUEL_CHEST_SLOT = SIZE
local DUMP_CHEST_SLOT = SIZE - 1
local LAST_ROBOT_SLOT = SIZE - 2

local function printError(msg) io.stderr:write(msg .. "\n") end

local job      -- { width, length, depth, origin }
local workers = {} -- { address, x0, x1, phase, msg, energy, progress, y }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function usage()
  print("Usage:")
  print("  master dig <x> <z> <sizeX> <sizeZ> [topY] [bottomY|bedrock] [workers]")
  print("  master <width> <length> <depth> [workers]")
  print("  master monitor")
  print("  master recall")
end

local function writeFile(path, data)
  local f = io.open(path, "w")
  f:write(serialization.serialize(data))
  f:close()
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = serialization.unserialize(f:read("*a"))
  f:close()
  return type(data) == "table" and data or nil
end

local function save() writeFile(STATE_FILE, { job = job, workers = workers }) end

local function load()
  local data = readFile(STATE_FILE)
  if not data then return false end
  job, workers = data.job, data.workers
  return true
end

local function send(to, msg) modem.send(to, PORT, serialization.serialize(msg)) end

local function decode(data)
  if type(data) ~= "string" then return nil end
  local ok, msg = pcall(serialization.unserialize, data)
  if ok and type(msg) == "table" then return msg end
end

local function findWorker(address)
  for _, w in ipairs(workers) do
    if w.address == address then return w end
  end
end

local function handle(sender, msg)
  local w = findWorker(sender)
  if not w or not msg then return end
  if msg.type == "status" then
    w.phase, w.msg, w.energy, w.progress, w.y = msg.phase, msg.msg, msg.energy, msg.progress, msg.y
  elseif msg.type == "hello" and msg.resume then
    w.msg = "restarted, resuming"
  end
end

-- Receives messages until pred(sender, msg, distance) is true or the timeout
-- runs out. Every message is also passed to handle().
local function waitFor(pred, timeout)
  local deadline = computer.uptime() + timeout
  while computer.uptime() < deadline do
    local ev, _, sender, port, distance, data =
      event.pull(deadline - computer.uptime(), "modem_message")
    if ev and port == PORT then
      local msg = decode(data)
      handle(sender, msg)
      if msg and pred(sender, msg, distance) then return sender, msg end
    end
  end
end

local function waitForType(from, msgType, timeout)
  return waitFor(function(sender, msg) return sender == from and msg.type == msgType end, timeout)
end

local function itemName(slot)
  local stack = ic.getStackInInternalSlot(slot)
  return stack and stack.name:lower() or nil
end

local function firstEmpty()
  for s = 1, LAST_ROBOT_SLOT do
    if robot.count(s) == 0 then return s end
  end
end

---------------------------------------------------------------------------
-- Energy
---------------------------------------------------------------------------

-- Places a fuel ender chest in an empty space above or below (never
-- breaking anything for it) and feeds the generator from it.
local function refuelGenerator()
  if not generator then return false end
  local slot = firstEmpty()
  if not slot or robot.count(FUEL_CHEST_SLOT) == 0 then return false end
  local place, drop, swing, side
  if not robot.detectUp() then
    place, drop, swing, side = robot.placeUp, robot.dropUp, robot.swingUp, sides.up
  elseif not robot.detectDown() then
    place, drop, swing, side = robot.placeDown, robot.dropDown, robot.swingDown, sides.down
  else
    return false
  end
  robot.select(FUEL_CHEST_SLOT)
  if not place() then return false end
  robot.select(slot)
  local want = 64 - generator.count()
  for i = 1, ic.getInventorySize(side) or 0 do
    if want <= 0 then break end
    local stack = ic.getStackInSlot(side, i)
    local name = stack and stack.name:lower()
    if name and (name:find("coal", 1, true) or name:find("coke", 1, true)) and not name:find("ore") then
      ic.suckFromSlot(side, i, want)
      local n = robot.count(slot)
      if n > 0 and generator.insert(n) then want = want - n end
      if robot.count(slot) > 0 then drop() end
    end
  end
  robot.select(FUEL_CHEST_SLOT)
  swing()
  robot.select(1)
  return true
end

local function ensureEnergy()
  if computer.energy() / computer.maxEnergy() >= ENERGY_LOW then return end
  if generator and generator.count() < 16 then refuelGenerator() end
  print("Recharging...")
  while computer.energy() / computer.maxEnergy() < ENERGY_RESUME do
    if generator and generator.count() == 0 and not refuelGenerator() then
      print("No fuel for the generator: waiting for solar power or a charger.")
    end
    os.sleep(5)
  end
end

---------------------------------------------------------------------------
-- Travel (dead reckoning from the position the player gives)
---------------------------------------------------------------------------

-- World headings: 0 = east (+x), 1 = south (+z), 2 = west (-x), 3 = north (-z).
local WX = { [0] = 1, 0, -1, 0 }
local WZ = { [0] = 0, 1, 0, -1 }
local FACINGS = { east = 0, south = 1, west = 2, north = 3 }
local FACING_NAMES = { [0] = "east", "south", "west", "north" }
local nav -- { x, y, z, h } in world coordinates, saved after every move

local STEP = {
  fwd  = { move = robot.forward, detect = robot.detect, swing = robot.swing },
  up   = { move = robot.up, detect = robot.detectUp, swing = robot.swingUp },
  down = { move = robot.down, detect = robot.detectDown, swing = robot.swingDown },
}

-- Moves one block. Only breaks blocks when `dig` is set; otherwise anything
-- solid counts as blocked (after giving it a moment, in case it is a robot).
-- Mobs are attacked. Returns false if blocked.
local function step(dir, dig)
  local a = STEP[dir]
  local waited = 0
  while true do
    ensureEnergy()
    if a.move() then
      if dir == "up" then nav.y = nav.y + 1
      elseif dir == "down" then nav.y = nav.y - 1
      else nav.x, nav.z = nav.x + WX[nav.h], nav.z + WZ[nav.h] end
      writeFile(NAV_FILE, nav)
      return true
    end
    local blocked, kind = a.detect()
    if kind == "entity" then
      if not a.swing() then os.sleep(0.5) end
    elseif blocked then
      if waited < 2 then
        waited = waited + 1
        os.sleep(1)
      elseif not (dig and a.swing()) then
        return false
      end
    elseif dir == "up" and nav.y >= MAX_Y then
      return false
    else
      os.sleep(0.2)
    end
  end
end

local function turnTo(h)
  while nav.h ~= h do
    if (h - nav.h) % 4 == 3 then
      robot.turnLeft()
      nav.h = (nav.h + 3) % 4
    else
      robot.turnRight()
      nav.h = (nav.h + 1) % 4
    end
    writeFile(NAV_FILE, nav)
  end
end

-- Goes straight up without breaking anything. If something is in the way it
-- comes back down and stops: the master must start under open sky.
local function ascend(height)
  local startY = nav.y
  while nav.y < height do
    if not step("up") then
      local stuckAt = nav.y
      while nav.y > startY and step("down") do end
      error(("Something is above the master at y=%d. Place it under open sky."):format(stuckAt + 1), 0)
    end
  end
end

-- Flies to (tx, ty, tz) at cruising height without breaking anything, then
-- comes straight down; only that final descent may break blocks.
local function travelTo(tx, ty, tz)
  local cruise = math.min(MAX_Y, math.max(CRUISE_Y, nav.y, ty))
  print(("Travelling from %d %d %d to %d %d %d"):format(nav.x, nav.y, nav.z, tx, ty, tz))
  ascend(cruise)
  local function blocked()
    error(("Path blocked at %d %d %d"):format(nav.x, nav.y, nav.z), 0)
  end
  local function sidestep()
    local h = nav.h
    for _, turn in ipairs({ 1, 3, 2 }) do
      turnTo((h + turn) % 4)
      if step("fwd") then return true end
    end
    return false
  end
  local function distance() return math.abs(tx - nav.x) + math.abs(tz - nav.z) end
  local best, detours, prefer = distance(), 0, nil
  while nav.x ~= tx or nav.z ~= tz do
    -- After a sidestep, keep trying the blocked axis so we go around the
    -- obstacle instead of stepping straight back.
    local axis
    if prefer == "z" and nav.z ~= tz then axis = "z"
    elseif nav.x ~= tx then axis = "x"
    else axis = "z" end
    if axis == "x" then
      turnTo(nav.x < tx and 0 or 2)
    else
      turnTo(nav.z < tz and 1 or 3)
    end
    if step("fwd") then
      prefer = nil
    elseif not step("up") then
      if not sidestep() then blocked() end
      prefer = axis
      detours = detours + 1
    end
    if distance() < best then
      best, detours = distance(), 0
    elseif detours > 64 then
      blocked()
    end
  end
  while nav.y > ty do if not step("down", true) then blocked() end end
  while nav.y < ty do if not step("up", true) then blocked() end end
end

---------------------------------------------------------------------------
-- Deployment
---------------------------------------------------------------------------

local function splitStrips(width, n)
  local strips, x = {}, 0
  local base, extra = math.floor(width / n), width % n
  for i = 1, n do
    local w = base + (i <= extra and 1 or 0)
    strips[i] = { x0 = x, x1 = x + w - 1 }
    x = x + w
  end
  return strips
end

local function robotSlots()
  local slots = {}
  for s = 1, LAST_ROBOT_SLOT do
    local name = itemName(s)
    if name and name:find("robot", 1, true) then slots[#slots + 1] = s end
  end
  return slots
end

local function confirm()
  io.write("Start? (y/n) ")
  return (io.read() or ""):lower():sub(1, 1) == "y"
end

local function askNumber(question, given, allowBlank)
  if given then return math.floor(given) end
  while true do
    io.write(question .. " ")
    local answer = io.read() or ""
    if answer == "" and allowBlank then return nil end
    if tonumber(answer) then return math.floor(tonumber(answer)) end
    print("Please enter a number.")
  end
end

-- Workers carried by the master are placed automatically; beyond those the
-- player can place more by hand, each with its two ender chests loaded.
local function askWorkers(given, width)
  if given then return math.min(math.floor(given), width) end
  local carried = math.min(#robotSlots(), robot.count(FUEL_CHEST_SLOT), robot.count(DUMP_CHEST_SLOT))
  local default = math.max(1, math.min(carried, width))
  while true do
    io.write(("How many workers? (carrying %d, Enter = %d) "):format(carried, default))
    local answer = io.read() or ""
    if answer == "" then return default end
    local n = tonumber(answer)
    if n and n >= 1 then return math.min(math.floor(n), width) end
  end
end

local function plan(width, length, depth, n)
  local strips = splitStrips(width, n)
  print(("Deploying %d worker(s), strips of %d-%d blocks, depth %s"):format(
    n, strips[n].x1 - strips[n].x0 + 1, strips[1].x1 - strips[1].x0 + 1,
    depth > 0 and depth or "to bedrock"))
  return { width = width, length = length, depth = depth, strips = strips }
end

-- Steps out of the master's block and back, so the worker in front can see
-- which of its sides opened up (that is how it learns which way it faces).
local function stepAside()
  if not robot.detectUp() and robot.up() then return robot.down end
  if not robot.detectDown() and robot.down() then return robot.up end
  if robot.back() then return robot.forward end
end

local function probe(address)
  for _ = 1, 3 do
    if not waitForType(address, "probe_ready", 30) then return false end
    local comeBack = stepAside()
    if not comeBack then
      printError("The master has no room to step aside (above, below or behind).")
      return false
    end
    send(address, { type = "probe_moved" })
    local ok = waitForType(address, "probe_done", 30)
    while not comeBack() do os.sleep(1) end
    if ok then return true end
  end
  return false
end

local function giveChest(address, slot)
  robot.select(slot)
  local ok = robot.drop(1)
  robot.select(1)
  send(address, { type = "chest" })
  return ok and waitForType(address, "chest_ok", 30) ~= nil
end

local function deploy(p)
  job = { width = p.width, length = p.length, depth = p.depth, origin = p.origin }
  workers = {}
  local strips = p.strips
  -- Farthest strip first, so no worker ever has to pass another in the lane.
  for i = #strips, 1, -1 do
    local strip = strips[i]

    -- The spawn block is in the air above the work area; if something is
    -- there, give it a moment (it may be the previous worker leaving).
    for _ = 1, 10 do
      if not robot.detect() then break end
      os.sleep(1)
    end
    if robot.detect() and not robot.swing() then
      printError("Cannot clear the block in front of the master.")
      return false
    end

    local slots = robotSlots()
    local placed = false
    if #slots > 0 and robot.count(FUEL_CHEST_SLOT) > 0 and robot.count(DUMP_CHEST_SLOT) > 0 then
      robot.select(slots[1])
      placed = robot.place()
      robot.select(1)
    end
    if placed then
      os.sleep(0.5)
      modem.broadcast(PORT, WAKE_MESSAGE)
    else
      print("Place a worker robot (with both ender chests loaded) in front")
      print("of the master and switch it on.")
    end

    -- The worker in front is the one about 1 block away.
    local nextWake = computer.uptime() + WAKE_TIMEOUT
    local address, hello
    repeat
      address, hello = waitFor(function(_, msg, distance)
        return msg.type == "hello" and distance and distance <= 1.5
      end, 5)
      if not address and placed and computer.uptime() >= nextWake then
        print("The worker has not started by itself: please switch it on.")
        nextWake = math.huge
      end
    until address

    local giveChests = not hello.hasChests
    send(address, {
      type = "job", x0 = strip.x0, x1 = strip.x1, length = p.length, depth = p.depth,
      giveChests = giveChests,
    })
    if giveChests then
      if not giveChest(address, FUEL_CHEST_SLOT) or not giveChest(address, DUMP_CHEST_SLOT) then
        printError("Could not hand the ender chests to the worker.")
        return false
      end
    end
    if not probe(address) then
      printError("The worker could not work out which way it faces.")
      return false
    end

    workers[#workers + 1] = { address = address, x0 = strip.x0, x1 = strip.x1, phase = "starting", msg = "" }
    save()
    print(("Worker %s -> strip %d..%d"):format(address:sub(1, 8), strip.x0, strip.x1))

    local deadline = computer.uptime() + LEAVE_TIMEOUT
    while robot.detect() do
      if computer.uptime() >= deadline then
        printError("The worker has not left the spawn block.")
        return false
      end
      waitFor(function() return false end, 1)
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Monitoring
---------------------------------------------------------------------------

local function draw()
  local w, h = term.getViewport()
  term.clear()
  print(("Swarminer %dx%dx%s  %d workers"):format(
    job.width, job.length, job.depth > 0 and job.depth or "B", #workers))
  local done = 0
  for i, wk in ipairs(workers) do
    if wk.phase == "done" then done = done + 1 end
    if i <= h - 3 then
      local pct = wk.progress and ("%3d%%"):format(math.floor(wk.progress * 100)) or "   ?"
      local line = ("%s %3d-%-3d %-6s %s %3s%% %s"):format(wk.address:sub(1, 4), wk.x0, wk.x1,
        (wk.phase or "?"):sub(1, 6), pct, tostring(wk.energy or "?"), wk.msg or "")
      print(line:sub(1, w))
    end
  end
  io.write(("%d/%d done  [R]ecall  [Q]uit"):format(done, #workers))
  return done == #workers
end

local function recall()
  for _, w in ipairs(workers) do send(w.address, { type = "recall" }) end
end

local function monitor()
  local nextDraw = 0
  while true do
    if computer.uptime() >= nextDraw then
      if draw() then break end
      nextDraw = computer.uptime() + 1
    end
    local ev, _, a, b, _, data = event.pull(1)
    if ev == "modem_message" and b == PORT then
      handle(a, decode(data))
      save()
    elseif ev == "key_down" then
      local ch = string.char(math.max(0, math.min(255, a or 0))):lower()
      if ch == "r" then recall() elseif ch == "q" then break end
    elseif ev == "interrupted" then
      break
    end
  end
  print()
end

local function finish(ok)
  if ok then
    monitor()
  elseif #workers > 0 then
    print("Deployment stopped; " .. #workers .. " worker(s) are already running.")
    print("Use 'master monitor' or 'master recall'.")
  end
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------

modem.open(PORT)
modem.setStrength(math.huge)

if args[1] == "monitor" or args[1] == "recall" then
  if not load() then
    io.stderr:write("No saved job found.\n")
    return
  end
  if args[1] == "recall" then
    recall()
    print("Recall sent to " .. #workers .. " worker(s).")
  else
    monitor()
  end
  return
end

if args[1] == "dig" then
  local x, z, sizeX, sizeZ = tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
  if not (x and z and sizeX and sizeZ) or sizeX < 1 or sizeZ < 1
      or (args[6] and not tonumber(args[6]))
      or (args[7] and args[7] ~= "bedrock" and not tonumber(args[7])) then
    usage()
    return
  end
  x, z, sizeX, sizeZ = math.floor(x), math.floor(z), math.floor(sizeX), math.floor(sizeZ)

  -- Where is the master now? It remembers its last known position.
  nav = readFile(NAV_FILE)
  if nav then
    io.write(("Is the master at %d %d %d facing %s? (y/n) "):format(
      nav.x, nav.y, nav.z, FACING_NAMES[nav.h]))
    if (io.read() or ""):lower():sub(1, 1) ~= "y" then nav = nil end
  end
  while not nav do
    io.write("Master's position and facing (x y z north|south|east|west)? ")
    local px, py, pz, facing = (io.read() or ""):match("(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%a+)")
    if px and FACINGS[facing:lower()] then
      nav = { x = tonumber(px), y = tonumber(py), z = tonumber(pz), h = FACINGS[facing:lower()] }
      writeFile(NAV_FILE, nav)
    else
      print("For example: 120 64 -35 north")
    end
  end

  local top = askNumber("Highest block Y in the work area (include any trees to remove)?",
    tonumber(args[6]))
  local bottom
  if args[7] then
    bottom = tonumber(args[7]) and math.floor(tonumber(args[7]))
  else
    bottom = askNumber("Lowest Y to mine down to? (Enter = bedrock)", nil, true)
  end
  if bottom and bottom > top then
    io.stderr:write("The lowest Y must not be above the highest.\n")
    return
  end
  local depth = bottom and (top - bottom + 1) or 0
  local n = askWorkers(tonumber(args[8]), sizeZ)

  -- Facing east, "forward" is +x and "right" is +z, so the relative area
  -- (length forward, width to the right) lines up with the world axes.
  print(("Area x %d..%d, z %d..%d, y %d down to %s"):format(
    x, x + sizeX - 1, z, z + sizeZ - 1, top, bottom or "bedrock"))
  local p = plan(sizeZ, sizeX, depth, n)
  if not confirm() then return end
  p.origin = { x = x, y = top, z = z }

  -- Park one block west of the area's corner, just above its highest block.
  travelTo(x - 1, top + 1, z)
  turnTo(0)
  print("Arrived. Deploying workers.")
  finish(deploy(p))
  return
end

local width, length, depth = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
if not (width and length and depth) or width < 1 or length < 1 or depth < 0 then
  usage()
  return
end
width, length, depth = math.floor(width), math.floor(length), math.floor(depth)

local p = plan(width, length, depth, askWorkers(tonumber(args[4]), width))
if confirm() then
  finish(deploy(p))
end
