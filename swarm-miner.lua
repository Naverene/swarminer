--
-- Created by IntelliJ IDEA.
-- User: awweaver
-- Date: 12/27/2020
-- Time: 15:32
-- To change this template use File | Settings | File Templates.
--

--Wojbie's Swarm Miner Wireless Floppy Disk Instaler
--Instaler for all programs that are part of Wojbie's Swarm Miner
--Designed to be run from Floppy Disk- should not be used other way.
--Downloads all other parts if http Api is online

local tArgs = {...}

local code=
{
    startup="LXLBZK25",
    swarminer="2h1RmbAR",
    swarmstart="aFgPSyGe",
    scanner="4wgEDymE",
    cycle="7tWnxwLU",
    recovery="pPqghm6F"
}

--File Useage

local function save(A,B) local file = fs.open(tostring(A),"w") file.write(B) file.close() end
local function saveT(A,B) save(A,textutils.serialize(B)) end
local function saveTH(A,B) save(A,string.gsub(textutils.serialize(B),"},","},\r\n")) end
local function get(A) local file = fs.open(tostring(A),"r") if not file then return false end local data = file.readAll() file.close() if data then return data end end
local function getT(A) local data = get(A) if data then data = textutils.unserialize(data) end if data then return data end end


--pastebin downloads system

local function pasteget(A,B)
    if not http then
        print( "Http Api is offline" )
        printError( "Set enableAPI_http to true in ComputerCraft.cfg" )
        return false
    end
    print("Downloading "..B)
    local response = http.get("http://pastebin.com/raw.php?i="..textutils.urlEncode(A))
    if response then
        local sResponse = response.readAll()
        response.close()
        save(B,sResponse)
        print("Download Successful")
        return true

    else
        print("Download Failed")
        return false
    end
end

-- Yes/No Questions

local function yn(A)
    if not A then return false end
    local key
    write(A.."[y/n]:")
    while true do
        _,key = os.pullEvent("key")
        if key==21 then write(keys.getName(key).."\n") sleep(0.01) return true
        elseif key==49 then write(keys.getName(key).."\n") sleep(0.01) return false
        end
    end

end

--Asking for position

local function getpos()
    local temp={}
    while true do
        print("Enter data from F3 Screen")
        write("Please enter x coordinate:") temp.x=tonumber(read())
        write("Please enter y coordinate:") temp.y=tonumber(read())
        write("Please enter z coordinate:") temp.z=tonumber(read())
        if temp.x and temp.y and temp.z then
            print("x:"..temp.x.." y:"..temp.y.." z:"..temp.z)
            if yn("Are thise correct?") then break end
        end
    end
    return temp
end

---------------------------------Start of progam-----------------------------------


--Basic self-discovery
local diskPath="/"..string.gsub(shell.getRunningProgram(),"startup","")
local i,side
if diskPath=="/" then print("This program is designed to be run stright from Floppy Disk. Copy this program onto Floppy Disk before using. Terminating") return true end

for _,i in pairs(redstone.getSides()) do
    if disk.getMountPath(i) then
        if "/"..disk.getMountPath(i).."/" == diskPath then side=i break end
    end
end

print("This instaler Floppy Disk is run from \""..diskPath.."\" Directory")
if side then
    print("Its connected to "..side.." side of device")
    disk.setLabel(side,"Swarm Floppy nr:"..disk.getID(side))
else
    print("Its connected by remote drive/wired modem network")
end

--Cheacking if called argumants

if #tArgs==1 then
    if tArgs[1]=="help" or tArgs[1]=="?" then
        print("Only commands here are \"update\" and \"addzone\" ") return true
    elseif tArgs[1]=="update" then
        if not http then
            print("Http Api is offline. Please update files manualy.") return true
        else
            print("Http Api is online! Downloading latest versions.")
            sleep(1)
            for i,k in pairs(code) do
                pasteget(k,diskPath..i)
            end
            print("Download complete. Rebotting") os.reboot()  return true
        end
    elseif tArgs[1]=="addzone" then
        local order=getT(diskPath.."order.log")
        if order then
            print()
            print("Adding forbidden zone nr "..(#order.zone).." to Order File")
            print("Zone is a Cuboid defined by 2 point on oposite corners of it.")
            print("You can choose any oposite corners.")
            print("If you want to set one block as forbidden simply enter it's coord as both points.")
            print("Enter coords for point 1")
            local point1 = getpos()
            print("Enter coords for point 2")
            local point2 = getpos()
            print("Point 1 is x:"..point1.x.." y:"..point1.y.." z:"..point1.z)
            print("Point 2 is x:"..point2.x.." y:"..point2.y.." z:"..point2.z)
            print("Cuboid size will is x:"..(math.abs(point1.x-point2.x)+1).." y:"..(math.abs(point1.y-point2.y)+1).." z:"..(math.abs(point1.z-point2.z)+1))
            if not yn("Is that correct?") then print("Canceling") return false end
            order.zone[#order.zone+1]={xl=point1.x,yl=point1.y,zl=point1.z,xu=point2.x,yu=point2.y,zu=point2.z}
            saveTH(diskPath.."order.log",order)
        else
            print("You can addzone only when Floppy Disk contains preformated order")
        end
        return true
    end
end

--Cheacking if has all needed files
local ok=true
for i,k in pairs(code) do
    if not fs.exists(diskPath..i) then ok=false break end
end

if not ok then
    if not http then
        print("I am missing some files. Http Api is offline. Please replace them manualy.")
        for i,k in pairs(code) do
            if not fs.exists(diskPath..i) then print("File "..i.." is missing") end
        end
    else
        print("I am missing some files. Http Api is online! Downloading latest versions.")
        for i,k in pairs(code) do
            if not fs.exists(diskPath..i) then pasteget(k,diskPath..i) end
        end
    end
end

--running instalators

if turtle then
    if not gps.locate(2) then print("No GPS detected") return end
    if rs.getInput("back") then -- Deployed Activated startup.
        fs.delete("/swarminer")
        fs.delete("/startup")
        fs.copy(diskPath.."swarminer","/swarminer")
        fs.copy(diskPath.."swarmstart","/startup")
        print("Auto-Installed")
        print("Starting swarminer configuration")
        sleep(1)
        shell.run("/swarminer","instalation",diskPath)
        return true
    end
    if yn("Do you want to instal latest swarminer?") then
        fs.delete("/swarminer")
        fs.delete("/startup")
        fs.copy(diskPath.."swarminer","/swarminer")
        fs.copy(diskPath.."swarmstart","/startup")
        print("Installed")
        print("Starting swarminer configuration")
        sleep(1)
        shell.run("/swarminer","instalation",diskPath)
        return true
    end
else
    if yn("Do you want to instal scanner?") then
        fs.delete("/scanner")
        fs.delete("/startup")
        fs.delete("/gps.log")
        fs.copy(diskPath.."scanner","/scanner")
        fs.copy(diskPath.."swarmstart","/startup")
        if yn("Do you want this scanner to act like gps host too??") then
            local pos={gps.locate(2,true)}
            if pos[1] then
                print("x:"..pos[1].." y:"..pos[2].." z:"..pos[3])
                if not yn("Are thise correct?") then return false end
                saveT("/gps.log",{x=pos[1],y=pos[2],z=pos[3]})
            else print("No gps online - Enter Scanner Position manualy") saveT("/gps.log",getpos()) end
        end
        shell.run("/scanner")
        return true
    end
end
if yn("Do you want to preformat order and settings onto Floppy Disk?") then
    shell.run(diskPath.."swarminer","create",diskPath)
end