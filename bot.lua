local discordia = require "../deps/discordia/init.lua"
local persistence = require "../utils/persistence.lua"
local config = require "./config.lua"

local groups = persistence.load(config.savefile) or {}	-- all changes to groups should be reflected in savefile immediately
--[[ groups save data in following format
{"groupName" = {"channelID" = "lastmsgID"}}
]]
local vmMonitor = 5
local client = discordia.Client()
local clock = discordia.Clock()
						-- all commands should follow the same pattern - prefix + command + arguments
local commands = {		-- commands are one-word only. you can have space between prefix and command ("+ add" is valid")
	prefix = "+",
	-- channel and group commands
	add = "add",		-- create new groups and add new channels to them
	remove = "remove",	-- remove groups or specific channels from groups
	send = "send",		-- send a message to group
	update = "update",	-- check channels for validity and delete non-existent channels
	-- message commands
	delete = "delete",	-- delete the last message sent to group
	edit = "edit",		-- edit the last message sent to group
	-- meta commands
	list = "list",		-- print out the list of registered groups and channels in them
	help = "help",		-- print out help text
	status = "status", 	-- set bot status
	shutdown = "shutdown"
}

local activityStatus = {
	playing = 0,
	streaming = 1,
	listening = 2,
	watching = 3
}

local statusResolve = function (messageString)
	if type(messageString) ~= "string" then return nil end
	local _,_, statusType, status = messageString:gsub("listening to", "listening", 1):find("(%w+)%s(.*)")
	return (activityStatus[statusType] and {type = activityStatus[statusType], name = status} or nil)
end

local actions = {
	[commands.add] = function (message)
		message.channel:broadcastTyping()
		local _, _, groupName, channelID = message.content:find(commands.add.."%s(%S+)%s?(%d*)")
		if channelID == "" then channelID = message.channel.id end	-- if channelid is not present, bot defaults to current channel, same for other commands
		if groupName == "" then
			message:reply("Can't create group with empty name")
			return
		end
		if not groups[groupName] then groups[groupName] = {} end
		if not client:getChannel(channelID) then		-- channel doesn't exist or bot doesn't have access to it
			message:reply("Invalid channel ID")
			return
		end
		groups[groupName][channelID] = message.id
		persistence.store(config.savefile, groups)
		message:reply("Added `"..client:getChannel(channelID).name.."`to `"..groupName.."` group")
	end,
	
	[commands.remove] = function (message)
		message.channel:broadcastTyping()
		local _, _, groupName, channelID = message.content:find(commands.remove.."%s(%S+)%s?(%d*)")
		if channelID == "" then channelID = message.channel.id end
		if groups[groupName] then
			if client:getChannel(channelID) then
				groups[groupName][channelID] = nil
			else
				message:reply("Invalid channel ID")
				return
			end
		else
			message:reply("No group `"..groupName.."`")
			return
		end
		
		local empty = true						-- check whether this group is empty, delete it if yes
		for k, _ in pairs(groups[groupName]) do
			empty = false
		end
		if empty then groups[groupName] = nil end
		persistence.store(config.savefile, groups)
		message:reply("Removed `"..client:getChannel(channelID).name.."` from `"..groupName.."` group")
	end,
	
	[commands.send] = function (message)
		message.channel:broadcastTyping()
		-- +send Теперь я...
		local _, _, groupName, msg = message.content:find(commands.send.."%s(%S+)%s(.*)")
		if groups[groupName] then
			message:reply("Sending message to `"..groupName.."` group")
			for k, _ in pairs(groups[groupName]) do
				groups[groupName][k] = client:getChannel(k):send(msg).id	-- this id is used for deleting and editing
				persistence.store(config.savefile, groups)
				message:reply("Sent message to `"..client:getChannel(k).name.."` on server `"..client:getChannel(k).guild.name.."`")
			end
		else
			message:reply("No group `"..groupName.."`")
		end
	end,
	
	[commands.delete] = function (message)
		message.channel:broadcastTyping()
		local _, _, groupName = message.content:find(commands.delete.."%s(%S+)")
		if groups[groupName] then
			for k, v in pairs(groups[groupName]) do
				client:getChannel(k):getMessage(v):delete()
				message:reply("Deleted message in `"..client:getChannel(k).name.."` on server `"..client:getChannel(k).guild.name.."`")
			end
		else
			message:reply("No group `"..groupName.."`")
		end
	end,
	
	[commands.edit] = function (message)
		message.channel:broadcastTyping()
		local _, _, groupName, msg = message.content:find(commands.edit.."%s(%S+)%s(.*)")
		if groups[groupName] then
			message:reply("Editing last message sent to `"..groupName.."` group")
			for k, v in pairs(groups[groupName]) do
				client:getChannel(k):getMessage(v):setContent(msg)
				message:reply("Edited last message sent to `"..client:getChannel(k).name.."` on server `"..client:getChannel(k).guild.name.."`")
			end
		else
			message:reply("No group `"..groupName.."`")
		end
	end,
	
	[commands.list] = function (message)
		message.channel:broadcastTyping()
		local msg = "```Registered groups:```"
		for k,_ in pairs(groups) do
			msg = msg.."`"..k.."`\n"
		end
		msg = msg.." ```Groups:```"
		for groupName, group in pairs(groups) do
			msg = msg.."```"..groupName..":```"
			for channelID, _ in pairs(group) do
				msg = msg.."`"..client:getChannel(channelID).name.."` on `"..client:getChannel(channelID).guild.name.."`\n"
			end
		end
		message:reply(msg)
	end,
	
	[commands.help] = function (message)
		message:reply("This bot helps you to organize your newsletter channels. Use prefix '+' before your commands, like +help.\n**"..
			commands.add.."** *{group_name} [channelID]*: subscribe the *[channelID]* channel to the *{group_name}* newsletter. Defaults to current channel.\n**"..
			commands.remove.."** *{group_name} [channelID]*: unsubscribe the *[channelID]* channel from the *{group_name}* newsletter. Defaults to current channel.\n**"..
			commands.send.."** *{group_name} {message}*: send *{message}* to all channels, that are subscribed to *{group_name}* newsletter.\n**"..
			commands.delete.."** *{group_name}*: delete last message sent to *{group_name}* newsletter. You can delete only the last sent message.\n**"..
			commands.edit.."** *{group_name} {message}*: change last message sent to *{group_name}* newsletter to *{message}*.\n**"..
			commands.list.."**: print out all the registered newsletter groups and channels.\n**"..
			commands.shutdown.."**: allow the bot to die in peace.")
	end,
	
	[commands.update] = function (message)
		groups = persistence.load(config.savefile)
		for name, group in pairs(groups) do
			for channelID, _ in pairs(group) do
				if not client:getChannel(channelID) then 
					group[channelID] = nil
					message:reply("Deleted `"..channelID.."` from `"..name.."` group")
				end
			end
		end
		persistence.store(config.savefile, groups)
	end,
	
	[commands.status] = function (message)
		client:setGame(statusResolve(select(3, message.content:find(commands.status.."%s(.*)"))))
	end,
	
	[commands.shutdown] = function (message)
		message:reply("Shutting down gracefully")
		clock:stop()
		client:stop()
	end
}

client:on('messageCreate', function (message)
	if message.author.id == "601347755046076427" and message.channel.id == "676791988518912020" and message.content == "beep boop beep" then
		vmMonitor = 5
		return
	end
	if message.author.id ~= "272093076778909707" and message.author.id ~= "188731184501620736" then return end	-- Only Bor is valid...
	local _, _, command = message.content:find(commands.prefix.."%s?(%a+).*")
	local res, msg = pcall(function() if actions[command] then actions[command](message) end end)
	if not res then message:reply("Something went wrong, outputting error message...\n"..msg) end
end)

client:on('ready', function ()
	clock:start()
	client:getUser("188731184501620736"):send("It's alive!")
	client:setGame({type = 3, name = "the world go by"})
end)

clock:on('min', function ()
	vmMonitor = vmMonitor - 1
	if vmMonitor < 0 then 
		vmMonitor = 5
		client:getChannel("676791988518912020"):send("<@!188731184501620736> <@!272093076778909707> AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
	end
end)

client:run('Bot '..config.token)