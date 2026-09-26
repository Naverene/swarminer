--[[
  Swarminer worker (CC:Tweaked mining turtle with a wireless modem).

  The master turtle places this turtle in front of itself, hands it two
  ender chests and switches it on. The worker then mines its assigned strip
  of the area, emptying its inventory into the dump ender chest and taking
  fuel from the fuel ender chest wherever it happens to be, so it never has
  to travel back to the surface for either.

  One-time setup on every worker:  worker install
  (copies this program to startup.lua and labels the turtle; a labelled
  turtle keeps its files when it is broken and placed again).

  Coordinates are relative to the master, which sits at (0, 0, 0):
    +z = the direction the master faces, +x = the master's right, +y = up.
  The area is x = 0..width-1, z = 1..length, y = -1..-depth, i.e. the
  layers below the master's level, starting in the block in front of it.
]]

local PROTOCOL        = "swarminer"
local STATE_FILE      = "/.swarminer_worker"
local DUMP_SLOT       = 15   -- ender chest that receives mined items
local FUEL_SLOT       = 16   -- ender chest that supplies fuel
local LAST_CARGO_SLOT = 14   -- slots 1..14 hold mined items
local MIN_FUEL        = 200  -- refuel when the fuel level falls below this
local REFUEL_TARGET   = 5000 -- refuel up to this level (capped at the fuel limit)
local STATUS_INTERVAL = 5    -- seconds between status reports to the master
local RESUME_WAIT     = 6    -- seconds to wait for a new job before resuming a saved one

local args = { ... }

if args[1] == "install" then
  local self = "/" .. shell.getRunningProgram()
  if self ~= "/startup.lua" then
    if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
    fs.copy(self, "/startup.lua")
  end
  if fs.exists("/startup") then
    printError("Warning: /startup also exists and may run instead of startup.lua.")
  end
  if not os.getComputerLabel() then
    os.setComputerLabel("swarm-worker-" .. os.getComputerID())
  end
  print("Installed as startup.lua. Label: " .. os.getComputerLabel())
  print("You can now break this turtle and load it into the master.")
  return
end

-- Heading 0..3 = +z, +x, -z, -x (turning right adds one).
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

local ACT = {
  fwd = {
    move = turtle.forward, dig = turtle.dig, detect = turtle.detect, inspect = turtle.inspect,
    attack = turtle.attack, place = turtle.place, drop = turtle.drop, suck = turtle.suck,
  },
  up = {
    move = turtle.up, dig = turtle.digUp, detect = turtle.detectUp, inspect = turtle.inspectUp,
    attack = turtle.attackUp, place = turtle.placeUp, drop = turtle.dropUp, suck = turtle.suckUp,
  },
  down = {
    move = turtle.down, dig = turtle.digDown, detect = turtle.detectDown, inspect = turtle.inspectDown,
    attack = turtle.attackDown, place = turtle.placeDown, drop = turtle.dropDown, suck = turtle.suckDown,
  },
}

local FALLING = {
  ["minecraft:gravel"] = true, ["minecraft:sand"] = true, ["minecraft:red_sand"] = true,
  ["minecraft:suspicious_gravel"] = true, ["minecraft:suspicious_sand"] = true,
}

local state   -- persisted job and position, see startJob()
local status = "starting"

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------

local function save()
  local tmp = STATE_FILE .. ".tmp"
  local f = fs.open(tmp, "w")
  f.write(textutils.serialize(state))
  f.close()
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  fs.move(tmp, STATE_FILE)
end

local function load()
  for _, path in ipairs({ STATE_FILE, STATE_FILE .. ".tmp" }) do
    if fs.exists(path) then
      local f = fs.open(path, "r")
      local data = textutils.unserialize(f.readAll())
      f.close()
      if type(data) == "table" then return data end
    end
  end
end

---------------------------------------------------------------------------
-- Reporting
---------------------------------------------------------------------------

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
  if not (state and state.master) then return end
  rednet.send(state.master, {
    type = "status", phase = state.phase, msg = status,
    x = state.x, y = state.y, z = state.z,
    fuel = turtle.getFuelLevel(), progress = progress(),
  }, PROTOCOL)
end

local function setStatus(s)
  if s ~= status then
    status = s
    print(s)
    sendStatus()
  end
end

---------------------------------------------------------------------------
-- Inventory helpers
---------------------------------------------------------------------------

local function isTurtle(a)
  local ok, d = a.inspect()
  return ok and d.name:find("^computercraft:turtle") ~= nil
end

local function isEnderChest(slot)
  local d = turtle.getItemDetail(slot)
  return d ~= nil and d.name:find("ender") ~= nil
end

local function firstEmpty()
  for s = 1, LAST_CARGO_SLOT do
    if turtle.getItemCount(s) == 0 then return s end
  end
end

local function hasCargo()
  for s = 1, LAST_CARGO_SLOT do
    if turtle.getItemCount(s) > 0 then return true end
  end
  return false
end

-- Places the ender chest from `slot` above or below the turtle (never to the
-- side, where it could end up in a neighbouring worker's strip). The side is
-- written to disk before placing, so a restart can pick the chest back up.
local function placeChest(slot)
  while true do
    for _, side in ipairs({ "up", "down" }) do
      local a = ACT[side]
      if not a.detect() then
        turtle.select(slot)
        state.chest = { slot = slot, side = side }
        save()
        if a.place() then return side end
        state.chest = nil
        save()
      end
    end
    -- Both sides are solid: clear one of them and try again.
    local cleared = false
    for _, side in ipairs({ "up", "down" }) do
      local a = ACT[side]
      if not cleared and a.detect() and not isTurtle(a) and a.dig() then cleared = true end
    end
    if not cleared then sleep(1) end
  end
end

local function pickUpChest()
  local c = state.chest
  local a = ACT[c.side]
  turtle.select(c.slot)
  if a.detect() and not isTurtle(a) then a.dig() end
  if turtle.getItemCount(c.slot) == 0 then
    -- The chest went into another slot (or the dig happened before a restart).
    for s = 1, LAST_CARGO_SLOT do
      if isEnderChest(s) then
        turtle.select(s)
        turtle.transferTo(c.slot)
        break
      end
    end
  end
  state.chest = nil
  save()
  turtle.select(1)
end

local function dump()
  local prev = status
  setStatus("unloading")
  local a = ACT[placeChest(DUMP_SLOT)]
  for s = 1, LAST_CARGO_SLOT do
    turtle.select(s)
    while turtle.getItemCount(s) > 0 do
      if not a.drop() then
        setStatus("dump chest full, waiting")
        sleep(5)
      end
    end
  end
  pickUpChest()
  setStatus(prev)
end

local function checkInventory()
  if not firstEmpty() then dump() end
end

local function refuel()
  if turtle.getFuelLevel() == "unlimited" then return end
  local target = math.min(REFUEL_TARGET, turtle.getFuelLimit())
  local slot = firstEmpty()
  if not slot then
    dump()
    slot = firstEmpty()
  end
  local prev = status
  setStatus("refuelling")
  local a = ACT[placeChest(FUEL_SLOT)]
  turtle.select(slot)
  while turtle.getFuelLevel() < target do
    if turtle.getItemCount(slot) == 0 and not a.suck() then
      if turtle.getFuelLevel() >= MIN_FUEL then break end
      setStatus("fuel chest empty, waiting")
      sleep(10)
    elseif turtle.getItemCount(slot) > 0 and not turtle.refuel(1) then
      -- Not burnable (or an empty bucket): leave it as cargo, use another slot.
      slot = firstEmpty()
      if not slot then break end
      turtle.select(slot)
    end
  end
  -- Put unused fuel back so it is not dumped with the cargo.
  if slot and turtle.getItemCount(slot) > 0 and turtle.refuel(0) then a.drop() end
  pickUpChest()
  setStatus(prev)
end

local function ensureFuel()
  local level = turtle.getFuelLevel()
  if level == "unlimited" or level >= MIN_FUEL then return end
  refuel()
  while turtle.getFuelLevel() == 0 do
    setStatus("out of fuel")
    sleep(10)
    refuel()
  end
end

---------------------------------------------------------------------------
-- Movement (every move and turn is saved so a restart knows where we are)
---------------------------------------------------------------------------

local function turnRight()
  turtle.turnRight()
  state.h = (state.h + 1) % 4
  save()
end

local function turnLeft()
  turtle.turnLeft()
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

-- A move costs exactly one fuel, so recording the fuel level before moving
-- tells a restarted turtle whether the interrupted move actually happened.
local function rawMove(dir)
  local dx, dy, dz = 0, 0, 0
  if dir == "up" then dy = 1
  elseif dir == "down" then dy = -1
  else dx, dz = DX[state.h], DZ[state.h] end
  state.pending = { dx = dx, dy = dy, dz = dz, fuel = turtle.getFuelLevel() }
  save()
  local ok = ACT[dir].move()
  if ok then
    state.x, state.y, state.z = state.x + dx, state.y + dy, state.z + dz
  end
  state.pending = nil
  save()
  return ok
end

-- Moves one block, digging and attacking as needed. Waits for other turtles
-- to get out of the way. Returns false only for unbreakable blocks.
local function tryMove(dir)
  local a = ACT[dir]
  while true do
    if a.detect() then
      if isTurtle(a) then
        sleep(1)
      elseif a.dig() then
        checkInventory()
      else
        return false
      end
    else
      ensureFuel()
      if rawMove(dir) then return true end
      if not a.attack() then sleep(0.2) end
    end
  end
end

-- Digs the block above or below without moving; keeps going while gravel
-- or sand keeps falling into the space.
local function clear(dir)
  local a = ACT[dir]
  while a.detect() do
    local ok, d = a.inspect()
    if ok and d.name:find("^computercraft:turtle") then return false end
    if not a.dig() then return false end
    checkInventory()
    if ok and FALLING[d.name] and dir ~= "down" then sleep(0.4) end
  end
  return true
end

-- Moves vertically first, then along z, then along x. With the travel lane at
-- y = 0, z = 1 this keeps every worker inside its own strip on the way back.
local function goTo(x, y, z)
  while state.y < y do if not tryMove("up") then return false end end
  while state.y > y do if not tryMove("down") then return false end end
  if state.z ~= z then
    face(state.z < z and 0 or 2)
    while state.z ~= z do if not tryMove("fwd") then return false end end
  end
  if state.x ~= x then
    face(state.x < x and 1 or 3)
    while state.x ~= x do if not tryMove("fwd") then return false end end
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

-- Each pass runs along the middle of three layers and digs the layers above
-- and below it as it goes, like the built-in excavate program.
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
      if state.phase ~= "mine" then return end
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
    if not goTo(j.x0, 0, 1) then
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
    if not goTo(j.x0, 0, 1) then
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

local function comms()
  local timer = os.startTimer(STATUS_INTERVAL)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      sendStatus()
      timer = os.startTimer(STATUS_INTERVAL)
    elseif ev == "rednet_message" and c == PROTOCOL and a == state.master
        and type(b) == "table" and b.type == "recall" then
      if state.phase == "travel" or state.phase == "mine" then
        state.phase = "return"
        save()
        print("Recalled by master")
      end
    end
  end
end

---------------------------------------------------------------------------
-- Start-up
---------------------------------------------------------------------------

-- The master is the turtle directly behind us; which side it is on tells us
-- which way we are facing in the master's coordinate system.
local SIDE_OFFSET = { front = 0, right = 1, back = 2, left = 3 }

local function detectHeading(masterId)
  for side, off in pairs(SIDE_OFFSET) do
    if peripheral.getType(side) == "turtle" then
      local ok, id = pcall(peripheral.call, side, "getID")
      if ok and id == masterId then return (2 - off) % 4 end
    end
  end
end

-- The master drops the fuel chest first and the dump chest second.
local function sortChests()
  for s = 1, LAST_CARGO_SLOT do
    if isEnderChest(s) then
      turtle.select(s)
      if turtle.getItemCount(FUEL_SLOT) == 0 then
        turtle.transferTo(FUEL_SLOT)
      elseif turtle.getItemCount(DUMP_SLOT) == 0 then
        turtle.transferTo(DUMP_SLOT)
      end
    end
  end
  turtle.select(1)
  return turtle.getItemCount(FUEL_SLOT) > 0 and turtle.getItemCount(DUMP_SLOT) > 0
end

local function waitForJob(timeout)
  local deadline = timeout and os.clock() + timeout
  while true do
    rednet.broadcast({ type = "hello", resume = timeout ~= nil }, PROTOCOL)
    local id, msg = rednet.receive(PROTOCOL, 2)
    if id and type(msg) == "table" and msg.type == "job" then return id, msg end
    if deadline and os.clock() >= deadline then return nil end
  end
end

local function fail(msg)
  status = "error: " .. msg
  sendStatus()
  error(msg, 0)
end

local function startJob(masterId, job)
  state = {
    master = masterId,
    job = { x0 = job.x0, x1 = job.x1, length = job.length, depth = job.depth },
    x = 0, y = 0, z = 1,
    phase = "travel", nextLayer = 0,
  }
  local h = detectHeading(masterId)
  if not h then fail("master turtle not found next to me") end
  state.h = h
  if not sortChests() then
    fail("need ender chests in slot " .. FUEL_SLOT .. " (fuel) and " .. DUMP_SLOT .. " (dump)")
  end
  save()
  print(("Job: x %d..%d, length %d, depth %s"):format(
    job.x0, job.x1, job.length, job.depth > 0 and job.depth or "to bedrock"))
end

local function main()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then error("No wireless modem attached", 0) end
  rednet.open(peripheral.getName(modem))

  state = load()
  if state and state.phase ~= "done" then
    -- Finish anything interrupted by a restart before doing anything else.
    if state.pending then
      local p, now = state.pending, turtle.getFuelLevel()
      if type(p.fuel) == "number" and type(now) == "number" and now < p.fuel then
        state.x, state.y, state.z = state.x + p.dx, state.y + p.dy, state.z + p.dz
      end
      state.pending = nil
      save()
    end
    if state.chest then pickUpChest() end
    -- If a master just placed us for a new job it answers now; otherwise resume.
    print("Saved job found, checking for a new one...")
    local id, job = waitForJob(RESUME_WAIT)
    if id then
      startJob(id, job)
    else
      print("Resuming saved job")
    end
  else
    print("Waiting for a job from the master...")
    startJob(waitForJob())
  end

  sendStatus()
  parallel.waitForAny(work, comms)
  sendStatus()
end

main()
