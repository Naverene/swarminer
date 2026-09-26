--[[
  Swarminer GPS host (CC:Tweaked computer).

  One-time setup on each of the four GPS computers:  gpshost install
  (copies this program to startup.lua and labels the computer; a labelled
  computer keeps its files when it is broken and placed again).

  When the master turtle places the computer, it turns it on, attaches a
  modem and sends the computer its coordinates. The computer saves them and
  runs "gps host" from then on, including after every restart.
]]

local PROTOCOL    = "swarminer"
local COORDS_FILE = "/.gps_coords"

local args = { ... }

if args[1] == "install" then
  local self = "/" .. shell.getRunningProgram()
  if self ~= "/startup.lua" then
    if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
    fs.copy(self, "/startup.lua")
  end
  if fs.exists(COORDS_FILE) then fs.delete(COORDS_FILE) end
  if not os.getComputerLabel() then
    os.setComputerLabel("swarm-gps-" .. os.getComputerID())
  end
  print("Installed as startup.lua. Label: " .. os.getComputerLabel())
  print("You can now break this computer and load it into the master.")
  return
end

-- The modem is attached after the computer is switched on, so wait for it.
local modem
while true do
  modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if modem then break end
  print("Waiting for a wireless modem...")
  os.pullEvent("peripheral")
end

local coords
if fs.exists(COORDS_FILE) then
  local f = fs.open(COORDS_FILE, "r")
  coords = textutils.unserialize(f.readAll())
  f.close()
end

if not coords then
  rednet.open(peripheral.getName(modem))
  print("Waiting for coordinates from the master...")
  while not coords do
    local id, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" and msg.type == "gps_setup"
        and tonumber(msg.x) and tonumber(msg.y) and tonumber(msg.z) then
      coords = { x = msg.x, y = msg.y, z = msg.z }
      local f = fs.open(COORDS_FILE, "w")
      f.write(textutils.serialize(coords))
      f.close()
      rednet.send(id, { type = "gps_ack", x = coords.x, y = coords.y, z = coords.z }, PROTOCOL)
    end
  end
  -- Keep confirming for a few seconds in case the first reply was lost.
  local deadline = os.clock() + 5
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTOCOL, deadline - os.clock())
    if type(msg) == "table" and msg.type == "gps_setup" then
      rednet.send(id, { type = "gps_ack", x = coords.x, y = coords.y, z = coords.z }, PROTOCOL)
    end
  end
  rednet.close(peripheral.getName(modem))
end

shell.run("gps", "host", tostring(coords.x), tostring(coords.y), tostring(coords.z))
