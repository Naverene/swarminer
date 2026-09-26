--[[
  Swarminer master (CC:Tweaked turtle with a wireless modem; a pickaxe is
  only needed if the block in front of it has to be cleared).

  Inventory layout of the master:
    slots 1-14  worker turtles (labelled, with worker.lua installed)
    slot  15    dump ender chests  (one per worker, all the same colours)
    slot  16    fuel ender chests  (one per worker, all the same colours)

  Usage:
    master <width> <length> <depth> [workers]   deploy workers and monitor them
    master monitor                               reattach to a running job
    master recall                                call every worker back

  The area starts in the block in front of the master and extends <length>
  blocks forward and <width> blocks to the master's right, from the layer
  below the master down <depth> layers (0 = until bedrock). It is split into
  strips along the width, one strip per worker.
]]

local PROTOCOL        = "swarminer"
local STATE_FILE      = "/.swarminer_master"
local DUMP_CHEST_SLOT = 15
local FUEL_CHEST_SLOT = 16
local HELLO_TIMEOUT   = 15  -- seconds for a placed worker to boot and say hello
local LEAVE_TIMEOUT   = 120 -- seconds for a worker to clear the spawn block

local args = { ... }

local job      -- { width, length, depth }
local workers = {} -- { id, x0, x1, phase, msg, fuel, progress, y }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function usage()
  print("Usage:")
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

local function deploy(width, length, depth, wanted)
  local turtleSlots = {}
  for s = 1, 14 do
    if isTurtleItem(s) then turtleSlots[#turtleSlots + 1] = s end
  end
  local n = math.min(#turtleSlots, turtle.getItemCount(FUEL_CHEST_SLOT),
    turtle.getItemCount(DUMP_CHEST_SLOT), width, wanted or math.huge)
  if n < 1 then
    printError("Need worker turtles in slots 1-14, dump ender chests in slot "
      .. DUMP_CHEST_SLOT .. " and fuel ender chests in slot " .. FUEL_CHEST_SLOT .. ".")
    return false
  end

  job = { width = width, length = length, depth = depth }
  local strips = splitStrips(width, n)
  print(("Area %dx%d, depth %s"):format(width, length, depth > 0 and depth or "to bedrock"))
  print(("Deploying %d worker(s), strips of %d-%d blocks"):format(
    n, strips[n].x1 - strips[n].x0 + 1, strips[1].x1 - strips[1].x0 + 1))
  write("Start? (y/n) ")
  if read():lower():sub(1, 1) ~= "y" then return false end

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
    print(("Worker #%d -> x %d..%d"):format(id, strip.x0, strip.x1))
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
      local line = ("#%-3d %2d-%-2d %-6s %s %5s %s"):format(
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

local width, length, depth = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
local wanted = tonumber(args[4])
if not (width and length and depth) or width < 1 or length < 1 or depth < 0 then
  usage()
  return
end

if deploy(math.floor(width), math.floor(length), math.floor(depth), wanted) then
  monitor()
elseif #workers > 0 then
  print("Deployment stopped; " .. #workers .. " worker(s) are already running.")
  print("Use 'master monitor' or 'master recall'.")
end
