--[[
  Swarminer worker for OpenComputers (a robot).

  Required: a pickaxe (or better) in the tool slot, a wireless network card,
  an inventory controller upgrade and at least one inventory upgrade.
  Recommended: a generator upgrade (so it can burn coal from the fuel ender
  chest) and a battery upgrade. Without a generator the robot relies on
  solar upgrades or chargers and simply waits for energy.

  Slots: the last slot holds the fuel ender chest, the one before it the
  dump ender chest; every other slot is for mined items. The fuel chest's
  frequency should hold coal/charcoal (for the generator) and spare
  pickaxes (the robot equips a new one when its tool is nearly worn out).

  One-time setup:  worker install
  (copies this program to /home/bin, starts it from /home/.shrc on boot and
  sets the network card's wake message so the master can switch it on).

  Coordinates are relative to the master, which sits at (0, 0, 0):
    +z = the direction the master faces, +x = the master's right, +y = up.
  The area is x = 0..width-1, z = 1..length, y = -1..-depth.
]]

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local robot = require("robot")
local serialization = require("serialization")
local sides = require("sides")

local PORT            = 4250
local WAKE_MESSAGE    = "swarminer_wake"
local STATE_FILE      = "/home/.swarminer_worker"
local ENERGY_LOW      = 0.3   -- top up the generator below this fraction of max energy
local ENERGY_RESUME   = 0.6   -- when recharging, carry on above this fraction
local TOOL_LOW        = 0.05  -- replace the tool below this durability
local STATUS_INTERVAL = 5     -- seconds between status reports to the master
local RESUME_WAIT     = 6     -- seconds to wait for a new job before resuming a saved one
local FUEL_PATTERNS   = { "coal", "coke", "blaze_rod" } -- fuel names ("ore" is excluded)

local args = { ... }

local modem = component.isAvailable("modem") and component.modem
local ic = component.isAvailable("inventory_controller") and component.inventory_controller
local generator = component.isAvailable("generator") and component.generator

if args[1] == "install" then
  local src = os.getenv("_")
  if not src or not filesystem.exists(src) then
    io.stderr:write("Run this as 'worker install' from the folder it was saved in.\n")
    return
  end
  filesystem.makeDirectory("/home/bin")
  if filesystem.canonical(src) ~= "/home/bin/worker.lua" then
    filesystem.remove("/home/bin/worker.lua")
    filesystem.copy(src, "/home/bin/worker.lua")
  end
  local shrc = ""
  local f = io.open("/home/.shrc", "r")
  if f then shrc = f:read("*a") f:close() end
  if not shrc:find("worker", 1, true) then
    f = io.open("/home/.shrc", "a")
    f:write("worker\n")
    f:close()
  end
  if modem then modem.setWakeMessage(WAKE_MESSAGE, true) end
  print("Installed. The worker now starts when the robot boots.")
  print("You can break this robot (it keeps its files) and load it into the master.")
  return
end

if not modem or not modem.isWireless() then error("A wireless network card is required", 0) end
if not ic then error("An inventory controller upgrade is required", 0) end

local SIZE = robot.inventorySize()
local FUEL_SLOT = SIZE
local DUMP_SLOT = SIZE - 1
local LAST_CARGO_SLOT = SIZE - 2
if LAST_CARGO_SLOT < 4 then error("Add an inventory upgrade to this robot", 0) end

-- Heading 0..3 = +z, +x, -z, -x (turning right adds one).
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

local ACT = {
  fwd = { move = robot.forward, detect = robot.detect, swing = robot.swing, place = robot.place,
          drop = robot.drop, side = sides.front },
  up = { move = robot.up, detect = robot.detectUp, swing = robot.swingUp, place = robot.placeUp,
         drop = robot.dropUp, side = sides.up },
  down = { move = robot.down, detect = robot.detectDown, swing = robot.swingDown,
           place = robot.placeDown, drop = robot.dropDown, side = sides.down },
}

local state -- persisted job and position, see startJob()
local status = "starting"
local lastStatus = 0

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------

local function save()
  local tmp = STATE_FILE .. ".tmp"
  local f = io.open(tmp, "w")
  f:write(serialization.serialize(state))
  f:close()
  filesystem.remove(STATE_FILE)
  filesystem.rename(tmp, STATE_FILE)
end

local function load()
  for _, path in ipairs({ STATE_FILE, STATE_FILE .. ".tmp" }) do
    local f = io.open(path, "r")
    if f then
      local data = serialization.unserialize(f:read("*a"))
      f:close()
      if type(data) == "table" then return data end
    end
  end
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------

local function send(to, msg)
  modem.send(to, PORT, serialization.serialize(msg))
end

local function decode(data)
  if type(data) ~= "string" then return nil end
  local ok, msg = pcall(serialization.unserialize, data)
  if ok and type(msg) == "table" then return msg end
end

-- Waits for a message of the given type (from `from`, if set).
local function receive(msgType, from, timeout)
  local deadline = timeout and computer.uptime() + timeout
  while true do
    local left = deadline and deadline - computer.uptime()
    if left and left <= 0 then return nil end
    local ev, _, sender, port, _, data = event.pull(left or math.huge, "modem_message")
    if ev and port == PORT and (not from or sender == from) then
      local msg = decode(data)
      if msg and msg.type == msgType then return sender, msg end
    end
  end
end

local function progress()
  local j = state and state.job
  if not j or j.depth <= 0 then return nil end
  if state.phase == "return" or state.phase == "done" then return 1 end
  local done = state.nextLayer
  local p = state.pass
  if p then
    local layers = (p.down and p.m + 1 or p.m) - p.first + 1
    local cells = (j.x1 - j.x0 + 1) * j.length
    done = p.first + layers * (p.i - 1) / cells
  end
  return math.min(1, done / j.depth)
end

local function sendStatus()
  lastStatus = computer.uptime()
  if not (state and state.master) then return end
  send(state.master, {
    type = "status", phase = state.phase, msg = status,
    x = state.x, y = state.y, z = state.z,
    energy = math.floor(100 * computer.energy() / computer.maxEnergy()),
    progress = progress(),
  })
end

local function setStatus(s)
  if s ~= status then
    status = s
    print(s)
    sendStatus()
  end
end

-- Handles messages that arrived while working (recall) and sends a status
-- report every few seconds. Called often from the work loop.
local function checkMessages()
  while true do
    local ev, _, sender, port, _, data = event.pull(0, "modem_message")
    if not ev then break end
    local msg = port == PORT and sender == state.master and decode(data)
    if msg and msg.type == "recall" and (state.phase == "travel" or state.phase == "mine") then
      state.phase = "return"
      save()
      print("Recalled by master")
    end
  end
  if computer.uptime() - lastStatus >= STATUS_INTERVAL then sendStatus() end
end

---------------------------------------------------------------------------
-- Inventory helpers
---------------------------------------------------------------------------

local function itemName(slot)
  local stack = ic.getStackInInternalSlot(slot)
  return stack and stack.name or nil
end

local function isEnderChest(slot)
  local name = itemName(slot)
  return name ~= nil and name:lower():find("ender") ~= nil
end

local function isFuel(name)
  name = name:lower()
  if name:find("ore") then return false end
  for _, pattern in ipairs(FUEL_PATTERNS) do
    if name:find(pattern, 1, true) then return true end
  end
  return false
end

local function firstEmpty()
  for s = 1, LAST_CARGO_SLOT do
    if robot.count(s) == 0 then return s end
  end
end

local function hasCargo()
  for s = 1, LAST_CARGO_SLOT do
    if robot.count(s) > 0 then return true end
  end
  return false
end

-- Places the ender chest from `slot` above or below the robot (never to the
-- side, where it could end up in a neighbouring worker's strip). The side is
-- saved before placing, so a restart can pick the chest back up.
local function placeChest(slot)
  while true do
    for _, dir in ipairs({ "up", "down" }) do
      local a = ACT[dir]
      if not a.detect() then
        robot.select(slot)
        state.chest = { slot = slot, dir = dir }
        save()
        if a.place() then return dir end
        state.chest = nil
        save()
      end
    end
    -- Both sides are solid: clear one of them and try again.
    if not (ACT.up.swing() or ACT.down.swing()) then os.sleep(1) end
  end
end

local function pickUpChest()
  local c = state.chest
  local a = ACT[c.dir]
  robot.select(c.slot)
  if a.detect() then a.swing() end
  if robot.count(c.slot) == 0 then
    -- The chest went into another slot (or was picked up before a restart).
    for s = 1, LAST_CARGO_SLOT do
      if isEnderChest(s) then
        robot.select(s)
        robot.transferTo(c.slot)
        break
      end
    end
  end
  state.chest = nil
  save()
  robot.select(1)
end

local function dump()
  local prev = status
  setStatus("unloading")
  local a = ACT[placeChest(DUMP_SLOT)]
  for s = 1, LAST_CARGO_SLOT do
    robot.select(s)
    while robot.count(s) > 0 do
      if not a.drop() then
        setStatus("dump chest full, waiting")
        os.sleep(5)
      end
    end
  end
  pickUpChest()
  setStatus(prev)
end

local function checkInventory()
  if not firstEmpty() then dump() end
end

local function toolWorn()
  local durability, reason = robot.durability()
  if durability then return durability < TOOL_LOW end
  return reason == "no tool"
end

-- Opens the fuel chest to top up the generator and/or swap in a new pickaxe.
local function service(wantFuel, wantTool)
  if not firstEmpty() then dump() end
  local slot = firstEmpty()
  local prev = status
  setStatus("restocking")
  local a = ACT[placeChest(FUEL_SLOT)]
  local size = ic.getInventorySize(a.side) or 0
  robot.select(slot)

  if wantFuel and generator then
    local want = 64 - generator.count()
    for i = 1, size do
      if want <= 0 then break end
      local stack = ic.getStackInSlot(a.side, i)
      if stack and isFuel(stack.name) then
        ic.suckFromSlot(a.side, i, want)
        local n = robot.count(slot)
        if n > 0 and generator.insert(n) then want = want - n end
        if robot.count(slot) > 0 then a.drop() end -- whatever did not fit goes back
      end
    end
  end

  if wantTool then
    for i = 1, size do
      local stack = ic.getStackInSlot(a.side, i)
      if stack and stack.name:lower():find("pickaxe") then
        ic.suckFromSlot(a.side, i, 1)
        -- The worn tool lands in this slot and is dumped with the cargo.
        if robot.count(slot) > 0 then ic.equip() end
        break
      end
    end
  end

  pickUpChest()
  setStatus(prev)
end

local function energyFraction()
  return computer.energy() / computer.maxEnergy()
end

local function ensureEnergy()
  if energyFraction() >= ENERGY_LOW then return end
  if generator and generator.count() < 16 then service(true, false) end
  local prev = status
  setStatus("recharging")
  while energyFraction() < ENERGY_RESUME do
    if generator and generator.count() == 0 then
      service(true, false)
      if generator.count() == 0 then setStatus("fuel chest empty, waiting") end
    end
    os.sleep(5)
    checkMessages()
  end
  setStatus(prev)
end

local function ensureTool()
  while toolWorn() do
    service(false, true)
    if toolWorn() then
      setStatus("no spare pickaxe in the fuel chest, waiting")
      os.sleep(10)
      checkMessages()
    end
  end
end

---------------------------------------------------------------------------
-- Movement (every move and turn is saved so a restart knows where we are)
---------------------------------------------------------------------------

local function turnRight()
  robot.turnRight()
  state.h = (state.h + 1) % 4
  save()
end

local function turnLeft()
  robot.turnLeft()
  state.h = (state.h + 3) % 4
  save()
end

local function face(h)
  local diff = (h - state.h) % 4
  if diff == 3 then
    turnLeft()
  else
    for _ = 1, diff do turnRight() end
  end
end

-- The intended move is saved first. OpenComputers normally keeps programs
-- running across chunk unloads, so a move is only ever interrupted by a real
-- reboot; the move is then assumed not to have happened.
local function rawMove(dir)
  local dx, dy, dz = 0, 0, 0
  if dir == "up" then dy = 1
  elseif dir == "down" then dy = -1
  else dx, dz = DX[state.h], DZ[state.h] end
  state.pending = true
  save()
  local ok = ACT[dir].move()
  if ok then
    state.x, state.y, state.z = state.x + dx, state.y + dy, state.z + dz
  end
  state.pending = nil
  save()
  return ok
end

-- Moves one block, breaking blocks and attacking mobs in the way. In the
-- travel lane (`cautious`), a solid block is first given a few seconds to
-- move, since it may be another robot. Returns false for unbreakable blocks.
local function tryMove(dir, cautious)
  local a = ACT[dir]
  local waited = 0
  while true do
    ensureEnergy()
    if rawMove(dir) then return true end
    local blocked, kind = a.detect()
    if kind == "entity" then
      if not a.swing() then os.sleep(0.5) end
    elseif blocked then
      if cautious and waited < 3 then
        waited = waited + 1
        os.sleep(1)
      elseif a.swing() then
        checkInventory()
      else
        return false
      end
    else
      os.sleep(0.2)
    end
  end
end

-- Breaks the block above or below without moving. Every layer above the one
-- being cleared is already empty, so nothing can fall into the space later.
local function clear(dir)
  local a = ACT[dir]
  while true do
    local blocked, kind = a.detect()
    if not blocked or kind ~= "solid" then return true end
    if not a.swing() then return false end
    checkInventory()
  end
end

-- Moves vertically first, then along z, then along x. With the travel lane at
-- y = 0, z = 1 this keeps every worker inside its own strip on the way back.
local function goTo(x, y, z, cautious)
  while state.y < y do if not tryMove("up", cautious) then return false end end
  while state.y > y do if not tryMove("down", cautious) then return false end end
  if state.z ~= z then
    face(state.z < z and 0 or 2)
    while state.z ~= z do if not tryMove("fwd", cautious) then return false end end
  end
  if state.x ~= x then
    face(state.x < x and 1 or 3)
    while state.x ~= x do if not tryMove("fwd", cautious) then return false end end
  end
  return true
end

---------------------------------------------------------------------------
-- Mining
---------------------------------------------------------------------------

-- Cell `i` of a snake-pattern pass over the strip that starts in corner (sx, sz).
local function cellAt(p, i)
  local j = state.job
  local col = math.floor((i - 1) / j.length)
  local row = (i - 1) % j.length
  local x = (p.sx == j.x0) and (j.x0 + col) or (j.x1 - col)
  local forward = (p.sz == 1) == (col % 2 == 0)
  local z = forward and (1 + row) or (j.length - row)
  return x, z
end

-- Each pass runs along the middle of three layers and clears the layers
-- above and below it as it goes, like excavate.
local function mine()
  local j = state.job
  local maxK = (j.depth > 0) and (j.depth - 1) or math.huge
  local cells = (j.x1 - j.x0 + 1) * j.length
  while state.phase == "mine" do
    local p = state.pass
    if not p then
      if state.nextLayer > maxK then return end
      local m = math.min(state.nextLayer + 1, maxK)
      p = {
        first = state.nextLayer, m = m,
        up = m > state.nextLayer, down = m + 1 <= maxK,
        sx = state.x, sz = state.z, i = 1,
      }
      state.pass = p
      save()
    end
    setStatus("mining y=" .. (-1 - p.m))
    while state.y > -1 - p.m do
      if not tryMove("down") then return end -- bedrock
    end
    while p.i <= cells do
      checkMessages()
      if state.phase ~= "mine" then return end
      ensureTool()
      local x, z = cellAt(p, p.i)
      if not goTo(x, state.y, z) then return end -- unbreakable block
      if p.up then clear("up") end
      if p.down then clear("down") end
      p.i = p.i + 1
      save()
    end
    state.nextLayer = p.m + 2
    state.pass = nil
    save()
  end
end

local function work()
  local j = state.job
  if state.phase == "travel" then
    setStatus("travelling to strip")
    if not goTo(j.x0, 0, 1, true) then
      setStatus("stuck: lane blocked")
      return
    end
    if state.phase == "travel" then state.phase = "mine" end
    save()
  end
  if state.phase == "mine" then
    mine()
    state.phase = "return"
    save()
  end
  if state.phase == "return" then
    state.pass = nil
    setStatus("returning")
    if not goTo(j.x0, 0, 1, true) then
      setStatus("stuck: path home blocked")
      return
    end
    face(0)
    if hasCargo() then dump() end
    state.phase = "done"
    save()
    setStatus("done")
  end
end

---------------------------------------------------------------------------
-- Start-up
---------------------------------------------------------------------------

local function scan()
  local solid = {}
  for i = 0, 3 do
    local blocked, kind = robot.detect()
    solid[i] = blocked and kind == "solid"
    robot.turnRight()
  end
  return solid
end

-- Works out which way we face relative to the master: we look around, the
-- master steps out of its block, we look again. The side that opened up is
-- where the master was, i.e. heading 2 (-z).
local function findHeading(master)
  for _ = 1, 3 do
    local before = scan()
    send(master, { type = "probe_ready" })
    if receive("probe_moved", master, 30) then
      local after = scan()
      send(master, { type = "probe_done" })
      local found, count = nil, 0
      for i = 0, 3 do
        if before[i] and not after[i] then found, count = i, count + 1 end
      end
      if count == 1 then return (2 - found) % 4 end
    end
  end
end

-- The master hands over the fuel chest, then the dump chest, one at a time,
-- so each can be moved into the right slot as it arrives.
local function takeChest(master, targetSlot)
  if not receive("chest", master, 30) then return false end
  for s = 1, LAST_CARGO_SLOT do
    if robot.count(s) > 0 and isEnderChest(s) then
      robot.select(s)
      robot.transferTo(targetSlot)
      break
    end
  end
  robot.select(1)
  send(master, { type = "chest_ok" })
  return robot.count(targetSlot) > 0
end

local function waitForJob(timeout)
  local deadline = timeout and computer.uptime() + timeout
  while true do
    modem.broadcast(PORT, serialization.serialize({
      type = "hello", resume = timeout ~= nil,
      hasChests = robot.count(FUEL_SLOT) > 0 and robot.count(DUMP_SLOT) > 0,
    }))
    local sender, msg = receive("job", nil, 2)
    if sender then return sender, msg end
    if deadline and computer.uptime() >= deadline then return nil end
  end
end

local function fail(msg)
  status = "error: " .. msg
  sendStatus()
  error(msg, 0)
end

local function startJob(master, job)
  state = {
    master = master,
    job = { x0 = job.x0, x1 = job.x1, length = job.length, depth = job.depth },
    x = 0, y = 0, z = 1,
    phase = "travel", nextLayer = 0,
  }
  if job.giveChests then
    if not takeChest(master, FUEL_SLOT) or not takeChest(master, DUMP_SLOT) then
      fail("did not receive both ender chests")
    end
  end
  if robot.count(FUEL_SLOT) == 0 or robot.count(DUMP_SLOT) == 0 then
    fail("need ender chests in slot " .. FUEL_SLOT .. " (fuel) and " .. DUMP_SLOT .. " (dump)")
  end
  local h = findHeading(master)
  if not h then fail("could not find the master next to me") end
  -- scan() turns a full circle, so we face the same way as when we started.
  state.h = h
  save()
  print(("Job: x %d..%d, length %d, depth %s"):format(
    job.x0, job.x1, job.length, job.depth > 0 and job.depth or "to bedrock"))
end

local function main()
  modem.open(PORT)
  modem.setStrength(math.huge)

  state = load()
  if state and state.phase ~= "done" then
    if state.pending then
      print("Warning: restarted during a move; assuming the move did not happen.")
      state.pending = nil
      save()
    end
    if state.chest then pickUpChest() end
    -- If a master just placed us for a new job it answers now; otherwise resume.
    print("Saved job found, checking for a new one...")
    local master, job = waitForJob(RESUME_WAIT)
    if master then
      startJob(master, job)
    else
      print("Resuming saved job")
    end
  else
    print("Waiting for a job from the master...")
    startJob(waitForJob())
  end

  sendStatus()
  work()
  sendStatus()
end

main()
