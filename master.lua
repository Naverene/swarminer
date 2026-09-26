--[[
  Swarminer master (CC:Tweaked mining turtle with a wireless or ender modem).

  Inventory layout of the master:
    slots 1-14  worker turtles (labelled, with worker.lua installed); leave
                one slot empty if the master should refuel itself for travel
    slot  15    dump ender chests  (one per worker, all the same colours)
    slot  16    fuel ender chests  (one per worker, all the same colours)

  Usage:
    master dig <x> <y> <z> <sizeX> <sizeZ> <depth> [workers]
        Travel (by GPS) to the area whose top north-west corner block is
        x y z, then deploy. The area covers x..x+sizeX-1, z..z+sizeZ-1 and
        the layers y down to y-depth+1 (depth 0 = until bedrock).
    master <width> <length> <depth> [workers]
        Deploy right here: the area starts in the block in front of the
        master and extends <length> blocks forward and <width> blocks to its
        right, from the layer below the master down <depth> layers.
    master gps <x> <y> <z> <north|south|east|west> [height]
        Build a GPS constellation above the master. Give the master's own
        coordinates and facing (from the F3 screen). It needs 4 computers
        with gpshost.lua installed and 4 wireless or ender modems. The hosts
        are built around y=<height> (default 240).
    master monitor      reattach to a running job
    master recall       call every worker back

  The area is split into strips along the width (the Z axis for "dig"),
  one strip per worker.
]]

local PROTOCOL        = "swarminer"
local STATE_FILE      = "/.swarminer_master"
local DUMP_CHEST_SLOT = 15
local FUEL_CHEST_SLOT = 16
local HELLO_TIMEOUT   = 15  -- seconds for a placed worker to boot and say hello
local LEAVE_TIMEOUT   = 120 -- seconds for a worker to clear the spawn block
local CRUISE_ABOVE    = 6   -- travel this far above the higher of start and destination
local MAX_Y           = 318 -- highest level the master will climb to while travelling
local FUEL_MARGIN     = 100 -- spare fuel required on top of the travel estimate

local args = { ... }

local job      -- { width, length, depth, origin }
local workers = {} -- { id, x0, x1, phase, msg, fuel, progress, y }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function usage()
  print("Usage:")
  print("  master gps <x> <y> <z> <facing> [height]")
  print("  master dig <x> <y> <z> <sizeX> <sizeZ> <depth> [workers]")
  print("  master <width> <length> <depth> [workers]")
  print("  master monitor")
  print("  master recall")
  print("depth 0 = dig until bedrock")
end

local function save()
  local f = fs.open(STATE_FILE, "w")
  f.write(textutils.serialize({ job = job, workers = workers }))
  f.close()
end

local function load()
  if not fs.exists(STATE_FILE) then return false end
  local f = fs.open(STATE_FILE, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  if type(data) ~= "table" then return false end
  job, workers = data.job, data.workers
  return true
end

local function openModem()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then error("No wireless modem attached", 0) end
  rednet.open(peripheral.getName(modem))
end

local function isTurtleItem(slot)
  local d = turtle.getItemDetail(slot)
  return d ~= nil and d.name:find("^computercraft:turtle") ~= nil
end

local function findWorker(id)
  for _, w in ipairs(workers) do
    if w.id == id then return w end
  end
end

local function handle(id, msg)
  if type(msg) ~= "table" then return end
  local w = findWorker(id)
  if not w then return end
  if msg.type == "status" then
    w.phase, w.msg, w.fuel, w.progress, w.y = msg.phase, msg.msg, msg.fuel, msg.progress, msg.y
  elseif msg.type == "hello" and msg.resume then
    w.msg = "restarted, resuming"
  end
end

-- Receives messages until pred(id, msg) is true or the timeout runs out.
local function waitFor(pred, timeout)
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTOCOL, math.max(0.05, deadline - os.clock()))
    if id then
      handle(id, msg)
      if pred(id, msg) then return true end
    end
  end
  return false
end

local function waitUntil(cond, timeout)
  local deadline = os.clock() + timeout
  while not cond() do
    if os.clock() >= deadline then return false end
    waitFor(function() return false end, 1)
  end
  return true
end

---------------------------------------------------------------------------
-- Travel (GPS)
---------------------------------------------------------------------------

-- World headings: 0 = east (+x), 1 = south (+z), 2 = west (-x), 3 = north (-z).
local WX = { [0] = 1, 0, -1, 0 }
local WZ = { [0] = 0, 1, 0, -1 }
local nav -- { x, y, z, h } in world coordinates

local STEP = {
  fwd  = { move = turtle.forward, detect = turtle.detect, dig = turtle.dig,
           attack = turtle.attack, inspect = turtle.inspect },
  up   = { move = turtle.up, detect = turtle.detectUp, dig = turtle.digUp,
           attack = turtle.attackUp, inspect = turtle.inspectUp },
  down = { move = turtle.down, detect = turtle.detectDown, dig = turtle.digDown,
           attack = turtle.attackDown, inspect = turtle.inspectDown },
}

local function locate()
  local x, y, z = gps.locate(5)
  if not x then
    error("No GPS signal. Build GPS hosts with 'master gps' or move into range.", 0)
  end
  return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
end

-- Tops up the master's fuel from one of its fuel ender chests. Needs one
-- empty slot among 1-14 to pull fuel into.
local function refuelMaster(need)
  local level = turtle.getFuelLevel()
  if level == "unlimited" or level >= need then return true end
  if need > turtle.getFuelLimit() then return false end
  local slot
  for s = 1, 14 do
    if turtle.getItemCount(s) == 0 then slot = s break end
  end
  if not slot or turtle.getItemCount(FUEL_CHEST_SLOT) == 0 then return false end
  turtle.select(FUEL_CHEST_SLOT)
  if turtle.detectUp() then turtle.digUp() end
  if not turtle.placeUp() then return false end
  turtle.select(slot)
  while turtle.getFuelLevel() < need do
    if turtle.getItemCount(slot) == 0 and not turtle.suckUp() then break end
    if not turtle.refuel(1) then break end
  end
  if turtle.getItemCount(slot) > 0 then turtle.dropUp() end
  turtle.select(FUEL_CHEST_SLOT)
  turtle.digUp()
  turtle.select(1)
  return turtle.getFuelLevel() >= need
end

-- Moves one block, digging through anything breakable. Returns false if the
-- way is blocked by an unbreakable block or the world's height limits.
local function step(dir)
  local a = STEP[dir]
  local level = turtle.getFuelLevel()
  if level ~= "unlimited" and level < FUEL_MARGIN then
    -- Detours used more than estimated: top up in mid-journey if possible.
    refuelMaster(FUEL_MARGIN * 5)
  end
  while true do
    local ok, err = a.move()
    if ok then
      if dir == "up" then nav.y = nav.y + 1
      elseif dir == "down" then nav.y = nav.y - 1
      else nav.x, nav.z = nav.x + WX[nav.h], nav.z + WZ[nav.h] end
      return true
    end
    if err == "Out of fuel" then error("The master ran out of fuel while travelling.", 0) end
    if a.detect() then
      local found, d = a.inspect()
      if found and d.name:find("^computercraft:turtle") then
        sleep(1)
      elseif not a.dig() then
        return false
      end
    elseif err and (err:find("^Too") or err:find("leave the world")) then
      return false
    elseif not a.attack() then
      sleep(0.5)
    end
  end
end

local function turnTo(h)
  while nav.h ~= h do
    if (h - nav.h) % 4 == 3 then
      turtle.turnLeft()
      nav.h = (nav.h + 3) % 4
    else
      turtle.turnRight()
      nav.h = (nav.h + 1) % 4
    end
  end
end

-- Finds the master's position and facing by moving one block and asking GPS again.
local function findHeading()
  local x, y, z = locate()
  nav = { x = x, y = y, z = z }
  for pass = 1, 2 do
    for _ = 1, 4 do
      if pass == 2 then turtle.dig() end
      if turtle.forward() then
        local nx, _, nz = locate()
        for h = 0, 3 do
          if WX[h] == nx - x and WZ[h] == nz - z then nav.h = h end
        end
        if not nav.h then error("GPS returned an inconsistent position.", 0) end
        if not turtle.back() then nav.x, nav.z = nx, nz end
        return
      end
      turtle.turnRight()
    end
  end
  error("Cannot work out which way the master is facing: it cannot move.", 0)
end

-- Climbs to a cruising height, flies across, then digs down to the target.
-- Unless `noGps` is set, the arrival point is checked against GPS.
local function travelTo(tx, ty, tz, noGps)
  local cruise = math.min(MAX_Y, math.max(nav.y, ty) + CRUISE_ABOVE)
  local need = math.abs(tx - nav.x) + math.abs(tz - nav.z)
    + math.abs(cruise - nav.y) + math.abs(cruise - ty) + FUEL_MARGIN
  if not refuelMaster(need) then
    error(("The master needs %d fuel to travel and has %s. Refuel it, or leave one of "
      .. "slots 1-14 empty so it can refuel from a fuel ender chest."):format(
        need, tostring(turtle.getFuelLevel())), 0)
  end

  print(("Travelling from %d %d %d to %d %d %d"):format(nav.x, nav.y, nav.z, tx, ty, tz))
  while nav.y < cruise and step("up") do end
  local function blocked()
    error(("Path blocked at %d %d %d"):format(nav.x, nav.y, nav.z), 0)
  end
  -- Steps sideways (or back) when both ahead and above are unbreakable.
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
    -- Dig through obstacles; climb over anything unbreakable.
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
  -- Something unbreakable directly above the destination cannot be worked around.
  while nav.y > ty do if not step("down") then blocked() end end
  while nav.y < ty do if not step("up") then blocked() end end
  if noGps then return end

  local x, y, z = locate()
  if x ~= tx or y ~= ty or z ~= tz then
    error(("Arrived at %d %d %d instead of %d %d %d."):format(x, y, z, tx, ty, tz), 0)
  end
end

---------------------------------------------------------------------------
-- Building a GPS constellation
---------------------------------------------------------------------------

-- Four hosts: three level with the centre and one raised, so they are not
-- all in one plane (GPS needs that to give a single answer). The column
-- above the master's start is left clear so it can fly straight back down.
local GPS_SPACING = 6
local GPS_OFFSETS = {
  { GPS_SPACING, 0, 0 }, { -GPS_SPACING, 0, 0 }, { 0, 0, GPS_SPACING },
  { 0, GPS_SPACING, -GPS_SPACING },
}
local FACINGS = { east = 0, south = 1, west = 2, north = 3 }

local function findSlot(pattern, exclude)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name:find(pattern) and not (exclude and exclude[s]) then return s end
  end
end

-- Places one host computer at (x, y, z) with a modem on top of it and radios
-- it its coordinates. The computer must already have gpshost.lua installed.
local function buildHost(x, y, z, computerSlot, modemSlot)
  travelTo(x, y + 1, z, true)
  if turtle.detectDown() and not turtle.digDown() then
    error(("Cannot clear the block at %d %d %d"):format(x, y, z), 0)
  end
  turtle.select(computerSlot)
  if not turtle.placeDown() then error("Could not place a GPS computer.", 0) end
  local id = peripheral.call("bottom", "getID")
  peripheral.call("bottom", "turnOn")

  -- A modem placed into the gap above the computer attaches to its top.
  if not step("up") then error("Cannot move above the GPS computer.", 0) end
  turtle.select(modemSlot)
  if not turtle.placeDown() then error("Could not place a modem on the GPS computer.", 0) end
  turtle.select(1)

  for _ = 1, 30 do
    rednet.send(id, { type = "gps_setup", x = x, y = y, z = z }, PROTOCOL)
    local sid, msg = rednet.receive(PROTOCOL, 1)
    if sid == id and type(msg) == "table" and msg.type == "gps_ack" then
      print(("GPS host #%d running at %d %d %d"):format(id, x, y, z))
      return
    end
  end
  error(("GPS computer #%d did not answer. Run 'gpshost install' on it first."):format(id), 0)
end

local function buildGps(sx, sy, sz, facing, cy)
  local computers, modems = {}, 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name:find("^computercraft:computer") then computers[#computers + 1] = s end
    if d and d.name:find("^computercraft:wireless_modem") then modems = modems + d.count end
  end
  if #computers < #GPS_OFFSETS or modems < #GPS_OFFSETS then
    printError(("Need %d computers (with gpshost installed) and %d wireless or ender modems."):format(
      #GPS_OFFSETS, #GPS_OFFSETS))
    return
  end

  nav = { x = sx, y = sy, z = sz, h = facing }
  local need = 2 * math.abs(cy - sy) + 12 * GPS_SPACING + 8 * CRUISE_ABOVE + FUEL_MARGIN
  if not refuelMaster(need) then
    printError(("The master needs %d fuel and has %s. Refuel it, or give it a fuel ender "
      .. "chest in slot %d and an empty slot."):format(need, tostring(turtle.getFuelLevel()), FUEL_CHEST_SLOT))
    return
  end

  print(("Building GPS hosts around %d %d %d"):format(sx, cy, sz))
  for i, o in ipairs(GPS_OFFSETS) do
    local modemSlot = findSlot("^computercraft:wireless_modem")
    buildHost(sx + o[1], cy + o[2], sz + o[3], computers[i], modemSlot)
  end

  print("Returning to the starting point")
  travelTo(sx, sy, sz, true)
  turnTo(facing)
  sleep(1)
  local x, y, z = gps.locate(5)
  if x and math.floor(x + 0.5) == sx and math.floor(y + 0.5) == sy and math.floor(z + 0.5) == sz then
    print("GPS works: the master is at " .. sx .. " " .. sy .. " " .. sz)
  elseif x then
    printError(("GPS answers %d %d %d, but the master should be at %d %d %d. Check the coordinates "
      .. "you entered."):format(x, y, z, sx, sy, sz))
  else
    printError("The GPS hosts are built, but GPS does not answer yet.")
  end
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

-- Works out how many workers to send and which strip each one gets.
local function plan(width, length, depth, wanted)
  local turtleSlots = {}
  for s = 1, 14 do
    if isTurtleItem(s) then turtleSlots[#turtleSlots + 1] = s end
  end
  local n = math.min(#turtleSlots, turtle.getItemCount(FUEL_CHEST_SLOT),
    turtle.getItemCount(DUMP_CHEST_SLOT), width, wanted or math.huge)
  if n < 1 then
    printError("Need worker turtles in slots 1-14, dump ender chests in slot "
      .. DUMP_CHEST_SLOT .. " and fuel ender chests in slot " .. FUEL_CHEST_SLOT .. ".")
    return nil
  end
  local strips = splitStrips(width, n)
  print(("Deploying %d worker(s), strips of %d-%d blocks, depth %s"):format(
    n, strips[n].x1 - strips[n].x0 + 1, strips[1].x1 - strips[1].x0 + 1,
    depth > 0 and depth or "to bedrock"))
  return {
    width = width, length = length, depth = depth,
    strips = strips, turtleSlots = turtleSlots,
  }
end

local function confirm()
  write("Start? (y/n) ")
  return read():lower():sub(1, 1) == "y"
end

local function deploy(p)
  local length, depth, strips, turtleSlots = p.length, p.depth, p.strips, p.turtleSlots
  local n = #strips
  job = { width = p.width, length = length, depth = depth, origin = p.origin }
  workers = {}
  -- Farthest strip first, so no worker ever has to pass another in the lane.
  for i = n, 1, -1 do
    local strip = strips[i]

    while turtle.detect() do
      local ok, d = turtle.inspect()
      if ok and d.name:find("^computercraft:turtle") then
        print("Waiting for the previous worker to move away...")
        waitFor(function() return false end, 2)
      elseif not turtle.dig() then
        printError("Cannot clear the block in front of the master.")
        return false
      end
    end

    turtle.select(turtleSlots[i])
    if not turtle.place() then
      printError("Could not place a worker turtle.")
      return false
    end

    local id
    for _ = 1, 20 do
      if peripheral.getType("front") == "turtle" then
        id = peripheral.call("front", "getID")
        break
      end
      sleep(0.1)
    end
    if not id then
      printError("Placed worker is not responding as a peripheral.")
      return false
    end

    -- Fuel chest first, then dump chest: the worker sorts them in that order.
    turtle.select(FUEL_CHEST_SLOT)
    turtle.drop(1)
    turtle.select(DUMP_CHEST_SLOT)
    turtle.drop(1)
    turtle.select(1)

    peripheral.call("front", "turnOn")
    if p.origin then
      print(("Worker #%d -> z %d..%d"):format(id, p.origin.z + strip.x0, p.origin.z + strip.x1))
    else
      print(("Worker #%d -> x %d..%d"):format(id, strip.x0, strip.x1))
    end
    local hello = waitFor(function(sid, msg)
      return sid == id and type(msg) == "table" and msg.type == "hello"
    end, HELLO_TIMEOUT)
    if not hello then
      printError(("Worker #%d did not answer. Run 'worker install' on it first."):format(id))
      return false
    end

    rednet.send(id, {
      type = "job", x0 = strip.x0, x1 = strip.x1, length = length, depth = depth,
    }, PROTOCOL)
    workers[#workers + 1] = { id = id, x0 = strip.x0, x1 = strip.x1, phase = "starting", msg = "" }
    save()

    if not waitUntil(function() return not turtle.detect() end, LEAVE_TIMEOUT) then
      printError(("Worker #%d has not left the spawn block."):format(id))
      return false
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Monitoring
---------------------------------------------------------------------------

local function draw()
  local w, h = term.getSize()
  term.clear()
  term.setCursorPos(1, 1)
  print(("Swarminer %dx%dx%s  %d workers"):format(
    job.width, job.length, job.depth > 0 and job.depth or "B", #workers))
  local done = 0
  for i, wk in ipairs(workers) do
    if wk.phase == "done" then done = done + 1 end
    if i <= h - 3 then
      local pct = wk.progress and ("%3d%%"):format(math.floor(wk.progress * 100)) or "   ?"
      local line = ("#%-3d %3d-%-3d %-6s %s %5s %s"):format(
        wk.id, wk.x0, wk.x1, (wk.phase or "?"):sub(1, 6), pct, tostring(wk.fuel or "?"), wk.msg or "")
      print(line:sub(1, w))
    end
  end
  term.setCursorPos(1, h)
  term.write(("%d/%d done  [R]ecall  [Q]uit"):format(done, #workers))
  return done == #workers
end

local function recall()
  for _, w in ipairs(workers) do
    rednet.send(w.id, { type = "recall" }, PROTOCOL)
  end
end

local function monitor()
  local function receiver()
    local timer = os.startTimer(1)
    while true do
      local ev, a, b, c = os.pullEvent()
      if ev == "rednet_message" and c == PROTOCOL then
        handle(a, b)
        save()
      elseif ev == "timer" and a == timer then
        if draw() then return end
        timer = os.startTimer(1)
      end
    end
  end
  local function keyHandler()
    while true do
      local _, ch = os.pullEvent("char")
      ch = ch:lower()
      if ch == "r" then
        recall()
      elseif ch == "q" then
        return
      end
    end
  end
  parallel.waitForAny(receiver, keyHandler)
  draw()
  term.setCursorPos(1, select(2, term.getSize()))
  print()
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------

if not turtle then
  error("The master must be a turtle so it can place the workers.", 0)
end
openModem()

if args[1] == "monitor" or args[1] == "recall" then
  if not load() then
    printError("No saved job found.")
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

local function finish(ok)
  if ok then
    monitor()
  elseif #workers > 0 then
    print("Deployment stopped; " .. #workers .. " worker(s) are already running.")
    print("Use 'master monitor' or 'master recall'.")
  end
end

if args[1] == "gps" then
  local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
  local facing = args[5] and FACINGS[args[5]:lower()]
  local height = tonumber(args[6]) or 240
  if not (x and y and z and facing) then
    usage()
    return
  end
  print(("Master at %d %d %d facing %s; GPS hosts will be built around y=%d."):format(
    x, y, z, args[5]:lower(), height))
  if confirm() then buildGps(math.floor(x), math.floor(y), math.floor(z), facing, math.floor(height)) end
  return
end

if args[1] == "dig" then
  local n = {}
  for i = 2, 8 do n[i - 1] = tonumber(args[i]) end
  local x, y, z, sizeX, sizeZ, depth, wanted = n[1], n[2], n[3], n[4], n[5], n[6], n[7]
  if not (x and y and z and sizeX and sizeZ and depth) or sizeX < 1 or sizeZ < 1 or depth < 0 then
    usage()
    return
  end
  x, y, z = math.floor(x), math.floor(y), math.floor(z)
  sizeX, sizeZ, depth = math.floor(sizeX), math.floor(sizeZ), math.floor(depth)

  -- Facing east, "forward" is +x and "right" is +z, so the relative area
  -- (length forward, width to the right) lines up with the world axes.
  print(("Area x %d..%d, z %d..%d, y %d down to %s"):format(
    x, x + sizeX - 1, z, z + sizeZ - 1, y, depth > 0 and (y - depth + 1) or "bedrock"))
  local p = plan(sizeZ, sizeX, depth, wanted)
  if not p or not confirm() then return end
  p.origin = { x = x, y = y, z = z }

  -- A little fuel is needed just to find out which way we are facing.
  refuelMaster(FUEL_MARGIN)
  findHeading()
  travelTo(x - 1, y + 1, z)
  turnTo(0)
  print("Arrived. Deploying workers.")
  finish(deploy(p))
  return
end

local width, length, depth = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
local wanted = tonumber(args[4])
if not (width and length and depth) or width < 1 or length < 1 or depth < 0 then
  usage()
  return
end

local p = plan(math.floor(width), math.floor(length), math.floor(depth), wanted)
if p and confirm() then
  finish(deploy(p))
end
