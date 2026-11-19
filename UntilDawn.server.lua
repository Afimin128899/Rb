local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
Players.CharacterAutoLoads = false

local remote = Instance.new("RemoteEvent")
remote.Name = "UntilDawnSessions"
local rooms = {}
local membership = {}
local CAPACITY = 4
local VISITOR_COUNT = 5
local danger = {[2] = true, [5] = true}

for number = 1, 3 do
	rooms[number] = {number = number, members = {}, phase = "Lobby", epoch = 0}
end

local function send(room, event, ...)
	for _, member in ipairs(room.members) do
		remote:FireClient(member, event, room.number, ...)
	end
end

local function roomRoster()
	local roster = {}
	for number, room in ipairs(rooms) do
		roster[number] = {count = #room.members, phase = room.phase}
	end
	return roster
end

local function publishRooms()
	remote:FireAllClients("Rooms", roomRoster())
end

local function publishLobby(room)
	local names = {}
	for index, member in ipairs(room.members) do
		names[index] = member.DisplayName
	end
	for _, member in ipairs(room.members) do
		remote:FireClient(member, "Lobby", room.number, names, member == room.members[1])
	end
end

local function setPhase(room, phase)
	room.phase = phase
	room.epoch += 1
end

local function schedule(room, seconds, callback)
	local epoch = room.epoch
	task.delay(seconds, function()
		if room.epoch == epoch then callback(room) end
	end)
end

local function beginDawn(room)
	setPhase(room, "Finished")
	send(room, "Dawn")
	publishRooms()
end

local beginRound, resolveVotes, beginGap
beginRound = function(room)
	setPhase(room, "Encounter")
	room.index += 1
	room.votes = {}
	local duration = room.fast and 15 or 30
	send(room, "Round", room.index, workspace:GetServerTimeNow(), duration, #room.members)
	schedule(room, duration, resolveVotes)
end

beginGap = function(room)
	setPhase(room, "Gap")
	send(room, "Gap", room.index)
	schedule(room, room.fast and 1 or 2.4, function(session)
		if session.index == VISITOR_COUNT then
			setPhase(session, "Final")
			session.ready = {}
			send(session, "Final")
			schedule(session, session.fast and 10 or 20, beginDawn)
		else
			beginRound(session)
		end
	end)
end

resolveVotes = function(room)
	local open, closed = 0, 0
	for _, vote in pairs(room.votes) do
		if vote then open += 1 else closed += 1 end
	end
	local opened = open > closed
	if opened and danger[room.index] then room.mistakes += 1 end
	if room.mistakes == 2 then
		setPhase(room, "Finished")
		send(room, "Result", room.index, opened, false)
		publishRooms()
		return
	end
	setPhase(room, "Result")
	room.ready = {}
	send(room, "Result", room.index, opened, open + closed == 0)
	schedule(room, room.fast and 5 or 12, beginGap)
end

local function checkResponses(room)
	local responses = room.phase == "Encounter" and room.votes or room.ready
	local count = 0
	for _ in pairs(responses) do count += 1 end
	if room.phase == "Encounter" then
		for _, member in ipairs(room.members) do
			remote:FireClient(member, "Votes", room.number, room.index, count, #room.members, responses[member])
		end
		if count == #room.members then resolveVotes(room) end
	elseif count == #room.members then
		if room.phase == "Final" then beginDawn(room) else beginGap(room) end
	end
end

local function leave(player)
	local room = membership[player]
	if not room then return end
	membership[player] = nil
	table.remove(room.members, table.find(room.members, player))
	if #room.members == 0 then
		setPhase(room, "Lobby")
		room.votes, room.ready = nil, nil
	elseif room.phase == "Lobby" then
		publishLobby(room)
	elseif room.phase == "Encounter" then
		room.votes[player] = nil
		checkResponses(room)
	elseif room.phase == "Result" or room.phase == "Final" then
		room.ready[player] = nil
		checkResponses(room)
	end
	publishRooms()
end

Players.PlayerRemoving:Connect(leave)
remote.OnServerEvent:Connect(function(player, action, value, decision)
	local room = membership[player]
	if action == "List" then
		remote:FireClient(player, "Rooms", roomRoster())
	elseif action == "Join" then
		if room or typeof(value) ~= "number" or value % 1 ~= 0 then return end
		local target = rooms[value]
		if not target or target.phase ~= "Lobby" or #target.members >= CAPACITY then
			remote:FireClient(player, "Unavailable")
			return
		end
		membership[player] = target
		table.insert(target.members, player)
		publishLobby(target)
		publishRooms()
	elseif action == "Leave" then
		leave(player)
	elseif room then
		if action == "Start" and room.phase == "Lobby" and room.members[1] == player then
			room.fast = #room.members == 1
			room.index, room.mistakes = 0, 0
			send(room, "Started", room.fast)
			beginRound(room)
			publishRooms()
		elseif action == "Vote" and room.phase == "Encounter" and value == room.index and typeof(decision) == "boolean" then
			room.votes[player] = decision
			checkResponses(room)
		elseif action == "Continue" and room.phase == "Result" and value == room.index then
			room.ready[player] = true
			checkResponses(room)
		elseif action == "DawnReady" and room.phase == "Final" then
			room.ready[player] = true
			checkResponses(room)
		end
	end
end)
remote.Parent = ReplicatedStorage
