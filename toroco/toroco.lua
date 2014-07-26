package.path = package.path .. ";;;lumen/?.lua;toribio/?/init.lua;toribio/?.lua"

local M = {}

-- *** Requires ***

local toribio = require 'toribio'
local sched = require 'lumen.sched'
local mutex = require 'lumen.mutex'
local log = require 'lumen.log'

require 'lumen.tasks.selector'.init({service='nixio'})

-- *** Variables ***

-- Behaviors managed by Torocó

M.behaviors = {}

--M.running_behavior = nil

local events = {
	new_behavior = {}
}
M.events = events

-- List of registered receivers for each event

local registered_receivers = {}
local inhibited_events = {}

-- *** Functions ***

-- This function is executed when Torocó captures a signal.

local dispatch_signal = function (event, ...)
    
    -- inhibition
    if inhibited_events [event] and inhibited_events [event].expire_time and inhibited_events [event].expire_time < sched.get_time() then
        inhibited_events [event] = nil
    end

    if not inhibited_events [event] then

        -- for each receiver, ...
        for _, receiver in ipairs (registered_receivers[event]) do

            -- suppression
            if receiver.inhibited and receiver.inhibited.expire_time < sched.get_time() then
                receiver.inhibited = nil
            end

            if not receiver.inhibited then
            
                -- dispatch event to the receiver
                receiver.callback(event, ...)
            end
        end 
    end
end


-- This function inhibits an event sent by a behavior.
-- emitter: return value of wait_for_behavior or wait_for_device.
-- event_name: string
-- timeout: number (optional)

M.inhibit = function(emitter, event_name, timeout)

    local event = emitter.events [event_name]

    -- if the event is not inhibited for longer than proposed, set the new time.
    -- if the event is inhibited for longer than proposed, do nothing.
    -- if there is no timeout, delete the expire time.

    if timeout then
        if not inhibited_events [event] 
        or not inhibited_events [event].expire_time 
        or inhibited_events [event].expire_time < sched.get_time() + timeout then
            inhibited_events [event] = { expire_time = sched.get_time() + timeout }
        end
    else
        inhibited_events [event] = { expire_time = nil }
    end
end

-- This function releases an inhibition.
-- emitter: return value of wait_for_behavior or wait_for_device.
-- event_name: string

M.release_inhibition = function(emitter, event_name)

    local event = emitter.events [event_name]

    inhibited_events [event] = nil
end

-- This function suppresses an event received by a behavior.
-- emitter: return value of wait_for_behavior or wait_for_device.
-- event_name: string
-- receiver_name: string

M.suppress = function(emitter, event_name, receiver_name, timeout)
    
    local event = emitter.events [event_name]

    for _, receiver in ipairs(registered_receivers[event]) do
        if receiver.name == receiver_name then
            if timeout then
                if not receiver.inhibited 
                or not receiver.inhibited.expire_time 
                or receiver.inhibited.expire_time < sched.get_time() + timeout then
                    receiver.inhibited = { expire_time = sched.get_time() + timeout }
                end
            else
                receiver.inhibited = { expire_time = nil }
            end
        end
    end 
end

-- This function releases a suppression.
-- emitter: return value of wait_for_behavior or wait_for_device.
-- event_name: string
-- receiver_name: string

M.release_suppression = function(emitter, event_name, receiver_name)
    
    local event = emitter.events [event_name]

    for _, receiver in ipairs(registered_receivers[event]) do
        if receiver.name == receiver_name then
            receiver.inhibited = false;
        end
    end 
end

-- Registers the events that a behavior wants to receive.
-- The data is stored in receivers_events.

local get_task_name = function(conf)
    local config = toribio.configuration['tasks'] or {}    
    for k, v in pairs(config) do
        if v == conf then
            return k
        end
    end
end

-- Registers the dispatch signal function to an event

local register_dispatcher = function(event)
    local waitd = {
        event
    }

    local mx = mutex.new()
    local fsynched = mx:synchronize (dispatch_signal)

    sched.sigrun(waitd, fsynched)
end

local get_trigger_event = function(trigger)
    if trigger.event.type == 'device' then

        -- FIXME: emitter should be devicename not module name
        local device = toribio.wait_for_device ({ module = trigger.event.emitter })     
        if not device.events or not device.events[trigger.event.name] then 
            log ('TORIBIO', 'WARN', 'Event not found for device %s: "%s"', tostring(device), tostring(trigger.event.name))
        end

        return device.events[trigger.event.name]

    elseif trigger.event.type == 'behavior' then 

        local behavior = M.wait_for_behavior (trigger.event.emitter)     
       
        if not behavior.events or not behavior.events[trigger.event.name] then 
            log ('TOROCO', 'WARN', 'Event not found for behavior %s: "%s"', tostring(behavior), tostring(trigger.event.name))
        end

        return behavior.events[trigger.event.name]

    elseif trigger.event.type == 'function' then

        local device = toribio.wait_for_device (trigger.event.emitter)
        
        local event = {}
        local value = nil

        -- TODO: There should be only one polling function per target
        local polling_function = function()
            local new_value = device.get_value ();

            if (new_value ~= value) then
                value = new_value
                sched.signal (event, new_value)
            end
        end

        sched.sigrun ({ {}, timeout = 0.1 }, polling_function)

        return event
    end
end

-- Stores the task for each event of the trigger in 'registered_receivers',
-- and registers the event aliases for the trigger.

local register_trigger = function(behavior_name, trigger)

    local event = get_trigger_event(trigger)

    if not registered_receivers[event] then
        registered_receivers[event] = {}

        register_dispatcher (event)
    end

    -- initialize the receiver
    local receiver = {}
    receiver.name = behavior_name
    table.insert(registered_receivers[event], receiver)
    
    -- initialize callback
    local mx = mutex.new()
    local fsynched = mx:synchronize (function(_, ...)
            trigger.callback(trigger.event.name, ...)
        end
    )
    receiver.callback = fsynched

end 


local register_output_target = function(behavior_name, output_name, target)
    local proxy = function(_, ...)
        target(...)
    end

    local trigger = { 
        event = { type = 'behavior', emitter = behavior_name, name = output_name },
        callback = proxy
    }

    -- registers the (proxy) target function for the event.
    register_trigger (target.emitter, trigger)
end

-- mystic function

M.wait = function(waitd)
    
end


-- suspend a task until the behavior has been registered to Torocó.

M.wait_for_behavior = function(behavior_name, timeout)
    assert(sched.running_task, 'Must run in a task')

    -- if the behavior is already loaded, return success.

    if M.behaviors[behavior_name] and M.behaviors[behavior_name].loaded then
        return M.behaviors[behavior_name]
    end

    -- else, ...

	local wait_until
	if timeout then 
        wait_until = sched.get_time() + timeout 
    end
    
    local waitd = {M.events.new_behavior}
    if wait_until then 
        waitd.timeout = wait_until-sched.get_time() 
    end

    while true do

        -- wait for the event 'new_behavior'
	    local ev, new_behavior_name = sched.wait(waitd) 

        -- process the result.
	    if not ev then --timeout
		    return nil, 'timeout'

	    elseif new_behavior_name == behavior_name then
		    return M.behaviors[behavior_name] 

	    elseif wait_until then 
            waitd.timeout=wait_until-sched.get_time() 
        end
    end
    
end

-- /// Registers a behavior to Torocó. ///
-- This function loads a behavior from a file.
-- After loading the behaviors, add_behavior must be executed.

M.load_behavior = function(behavior_name)
    local packagename = 'behaviors/'..behavior_name

    local behavior_desc = require (packagename)
    behavior_desc.name = behavior_name
    behavior_desc.output_targets = behavior_desc.output_targets or {}

    return behavior_desc
end


-- this function adds a behavior to Torocó.

M.add_behavior = function (behavior)

    local load_behavior = function()
        -- add behavior to 'M.behaviors'
        M.behaviors[behavior.name] = { events = behavior.events }

        -- emits new_behavior.
        M.behaviors[behavior.name].loaded = true
        sched.signal (M.events.new_behavior, behavior.name)

        -- register the triggers
        for trigger_name, event in pairs(behavior.triggers) do
            register_trigger (behavior.name, behavior.triggers[trigger_name])
        end

        -- register the output targets
        for output_name, target in pairs(behavior.output_targets or {}) do
            register_output_target (behavior.name, output_name, target)
        end
    
        
    end
    sched.run(load_behavior)
end


-- Torocó main function

M.run = function(toribio_conf_file)
    if toribio_conf then
        M.load_configuration(toribio_conf_file)
    else
        M.load_configuration('toribio.conf')
    end

    print ('Torocó go!')

    sched.loop()
end


-- This function loads the behaviors from the files,
-- and then adds the behaviors to Torocó.

M.add_behaviors = function (behaviors)

    for behavior_name, behavior_table in pairs(behaviors) do
        local behavior = M.load_behavior (behavior_name)

        -- TODO: Error handling
        for trigger_name, event in pairs(behavior_table.triggers) do
            behavior.triggers[trigger_name].event = event
        end

        behavior.output_targets = behavior.output_targets or {}

        for output_name, target in pairs(behavior_table.output_targets or {}) do
            behavior.output_targets[output_name] = target
        end

        M.add_behavior(behavior)
    end
end

-------------------------------------------------------------------------------

-- load toribio.conf

M.load_configuration = function(file)
	local func_conf, err = loadfile(file)
	assert(func_conf,err)
	local conf = toribio.configuration
	local meta_create_on_query 
	meta_create_on_query = {
		__index = function (table, key)
			table[key]=setmetatable({}, meta_create_on_query)
			return table[key]
		end,
	}
	setmetatable(conf, meta_create_on_query)
	setfenv(func_conf, conf)
	func_conf()
	meta_create_on_query['__index']=nil

    sched.run(function()
        for _, section in ipairs({'deviceloaders', 'tasks'}) do
	        for task, conf in pairs(toribio.configuration[section] or {}) do
		        log ('TORIBIOGO', 'DETAIL', 'Processing conf %s %s: %s', section, task, tostring((conf and conf.load) or false))

		        if conf and conf.load==true then
			        --[[
			        local taskmodule = require (section..'/'..task)
			        if taskmodule.start then
				        local ok = pcall(taskmodule.start,conf)
			        end
			        --]]
			        log ('TORIBIOGO', 'INFO', 'Starting %s %s', section, task)
			        toribio.start(section, task)
		        end
	        end
        end
    end)
end

-------------------------------------------------------------------------------

return M
