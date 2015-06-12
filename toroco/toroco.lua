------------
-- Main file of Torocó.
-- @module toroco,lua
-- @author Ignacio Bettosini and Agustín Clavelli

-- ***************
-- *** Package ***
-- ***************

package.path = package.path .. ";;;lumen/?.lua;toribio/?/init.lua;toribio/?.lua"

-- **************
-- *** Module ***
-- **************

local M = {}

-- ****************
-- *** Requires ***
-- ****************

local toribio = require 'toribio'
local sched = require 'lumen.sched'
local mutex = require 'lumen.mutex'
local log = require 'lumen.log'

M.input = require 'toroco.input'
M.output = require 'toroco.output'
M.device = require 'toroco.device'
M.behavior = require 'toroco.behavior'

require 'lumen.tasks.selector'.init({service='nixio'})

-- *****************
-- *** Variables ***
-- *****************


-- /// behaviors ///
-- Behaviors managed by Torocó.
-- Key: Behavior name.
-- Value fields:
--	name: Behavior name.
--	events: Events emitted by the behavior. Key: Event name.
--	event_count: number of
--	input_sources: Sources of each input of the behavior.
--	tasks: taskd of each coroutine of the behavior. No key.
--	inhibition_targets: Target events to be inhibited for each output event of the behavior.
--	suppression_targets: Target events to be suppressed by each output event of the behavior.

M.behaviors = {}

-- /// behavior_taskd ///
-- Behavior of each coroutine.
-- Key: Taskd of the coroutine.
-- Value: Behavior.

M.behavior_taskd = {}

-- /// events ///
-- events

M.active_events = {}

M.active_events_inhibited = {}

local events = {
	new_behavior = {},
    release = {} -- One for each event in torocó
}
M.events = events

-- /// polling_devices ///
-- Events of device polling functions.
-- Keys: Device name, Event name.
-- Value fields:
--	event: Event emitted by the polling function.

local polling_devices = {}

-- /// registered_receivers ///
-- Registered receivers for each event.
-- Key: Event
-- Value fields:
--	name: Behavior name.
--	event_alias: Event to be sent by the dispatcher to the receiver.
--	suppressed: Expire time of the suppressors of each input event of the receiver.
--	execute_count: Number of times that the event should be sent to the receiver.

local registered_receivers = {}

-- /// inhibited_events ///
-- Inhibited events of each behavior.
-- Expire time of the inhibitors of each output event of the emitter.
-- Keys: Event, Behavior.
-- Value fields:
--	expire_time: sched.get_time() + timeout.

local inhibited_events = {}


-- /// M.devices ///

M.devices = {}


-- /// M.params ///
-- Paramaters of each behavior.
-- Key: Parameter name.
-- Example: toroco.params.max_value.

M.params = {}

local meta1
meta1 = {
	__index = function (table, key)
        local beh = M.behavior_taskd [sched.running_task]
		return beh.params[key]
	end,

	__newindex = function (table, key, value)
        local beh = M.behavior_taskd [sched.running_task]
		beh.params[key] = value
	end,
}
setmetatable(M.params, meta1)


-- *****************
-- *** Functions ***
-- *****************

-- Checks if the inhibition has expired.
-- If it has expired, the inhibition is dropped.

local update_inhibition_expiration = function (event, inhibitor, inhibition)

    if inhibition.expire_time and inhibition.expire_time < sched.get_time() then

        inhibited_events [event] [inhibitor] = nil

        sched.schedule_signal (M.events.release [event])
    end
end

-- Checks if the suppression has expired.
-- If it has expired, the suppression is dropped.

local update_suppression_expiration = function (event, suppressor, suppression_desc, receiver)

    if suppression_desc.expire_time and suppression_desc.expire_time < sched.get_time() then

        receiver.suppressed [event] [suppressor] = nil
        
        sched.schedule_signal (M.events.release [event], receiver.name)
    end
end


-- This function is executed when Torocó captures a signal.
-- It resend the signal to all receivers which registered to the event,
-- applying the inhibition and suppression restrictions.
-- filter_receiver: table with receivers that will receive the event (a subset of registered_receivers).
-- if nil, the event is sent to all receivers.

local dispatch_signal = function (event, filter_receiver, ...)

    -- update inhibition
    for inhibitor, inhibition in pairs (inhibited_events [event]) do

        update_inhibition_expiration (event, inhibitor, inhibition)
    end

    -- check inhibition
    if next(inhibited_events [event]) == nil then

        -- for each registered receiver of the event, ...
        for i = #registered_receivers [event], 1, -1 do
            local receiver = registered_receivers [event] [i]

            -- if the receiver is included in the filter, ...
            if not filter_receiver or filter_receiver == receiver.name then

                -- update suppression
                for suppressor, suppression_desc in pairs(receiver.suppressed [event] or {}) do

                    update_suppression_expiration (event, suppressor, suppression_desc, receiver)
                end

                -- check suppression
                if next(receiver.suppressed [event] or {}) == nil then

                    if receiver.execute_count and receiver.execute_count == 0 then
                        table.remove(registered_receivers [event], i)

                    else
                        if receiver.execute_count then
                            receiver.execute_count = receiver.execute_count - 1
                        end
                        -- send alias signal
                        sched.schedule_signal (receiver.event_alias, ...)
                    end
                end
           	end
        end 
    end
end

-- Torocó version of sched.wait_for_device().

local my_wait_for_device = function(devdesc, timeout)
	assert(sched.running_task, 'Must run in a task')

    if type (devdesc) == 'table' then
        return toribio.wait_for_device (devdesc)
    end

	local wait_until
	if timeout then wait_until=sched.get_time() + timeout end
	
	local device_in_devices
	
	device_in_devices = function (dd)
        if toribio.devices[dd] then
            return toribio.devices[dd]
        else
		    for _, device in pairs(toribio.devices) do
			    if device.module == dd then 
                    return device 
                end
		    end
        end
	end

	local in_devices=device_in_devices(devdesc)
	if in_devices then 
		return in_devices
	else
		local tortask = toribio.task
		local waitd = {toribio.events.new_device}
		if wait_until then waitd.timeout=wait_until-sched.get_time() end
		while true do
			local ev, device = sched.wait(waitd) 
			if not ev then --timeout
				return nil, 'timeout'
			end
			if device.name == devdesc or device.module == devdesc then
				return device 
			end
			if wait_until then waitd.timeout=wait_until-sched.get_time() end
		end
	end
	
end

local do_device_polling = function (event_desc, time, convert)
    -- return the event of the device polling function
    if polling_devices[event_desc.emitter] and polling_devices[event_desc.emitter][event_desc.name] then

        return polling_devices[event_desc.emitter][event_desc.name].event
    
    -- create a new device polling function, and return the new event
    else
    
    	-- check errors
    	if type(time) ~= "number" then
        	error ('Torocó error: Refresh time in \'configure_polling()\' must be a number.')
        end
    
    	-- polling event
        local event = {}

        -- polling function
        local value = nil
        local polling_function = function()
            local device = my_wait_for_device (event_desc.emitter)
            local new_value = device[event_desc.name]();
            if convert then
                new_value = convert (new_value)
            end
            if (new_value ~= value) then
                value = new_value
                sched.schedule_signal (event, new_value)
            end
        end

		-- store the polling event in polling_devices.
        if not polling_devices[event_desc.emitter] then
            polling_devices[event_desc.emitter] = {}
        end
        polling_devices[event_desc.emitter][event_desc.name] = { event = event }

		-- start the polling function.
        sched.sigrun ({ {}, timeout = time }, polling_function)

        return event
    end
end

-- returns the real event from a device or behavior.
-- event_desc: event descriptor (return value of /toroco/device or /toroco/behavior)

local get_real_event = function (event_desc)

	-- if the event is defined in a device, ...

    if event_desc.type == 'device' then
        
        local device = my_wait_for_device (event_desc.emitter)
        
        -- if the device does not have the event, ...
        if not device.events or not device.events[event_desc.name] then
        
        	-- if the device has a function with that event, ...
            if device[event_desc.name] then
            	
            	return do_device_polling (event_desc, 0.1)
            else
                error ('Torocó error: Device event \'' .. event_desc.emitter .. '.' .. event_desc.name ..'\' not found.')
            end
        end

        -- if the device has the event, return it.
        return device.events[event_desc.name]

	-- if the event is defined in a behavior, ...
    elseif event_desc.type == 'behavior' then 

        local behavior = M.wait_for_behavior (event_desc.emitter)
       
        if not behavior.events[event_desc.name] then
        
        	--error ('Torocó error: Behavior event \'' .. event_desc.emitter .. '.' .. event_desc.name ..'\' not found.')
	        behavior.events[event_desc.name] = {}
	        behavior.event_count = behavior.event_count + 1
        end

        return behavior.events[event_desc.name]
    end
end

---- Release a suppression to an event ///
-- This function releases a suppression to an event for a specific behavior.
-- The released suppression is the one associated with the running behavior,
-- and is independent of other inhibitions to the same event that were set by other behaviors.
-- @param behavior      Releasing behavior.
-- @param event_desc    Event descriptor (return value of /toroco/device or /toroco/behavior)
-- @param receiver_desc Receiver descriptor (return value of /toroco/behavior)

local release_suppression = function (behavior, event_desc, receiver_desc)

    local event = get_real_event (event_desc)

    if not event then
	    log ('TOROCO', 'ERROR', 'release_suppression(): receiver is not valid. %s %s', section, task)
    end

    for _, receiver in ipairs (registered_receivers[event]) do
        if receiver.name == receiver_desc.emitter then

            if receiver.suppressed [event] then
                receiver.suppressed [event] [behavior] = nil;
            end
        end
    end 

    sched.schedule_signal (M.events.release [event], receiver_desc.emitter)
end

---- Release an inhibition to an event. ///
-- This function releases an inhibition to an event.
-- The released inhibition is independent of other inhibitions to the same event that were set by other behaviors.
-- @param behavior   Releasing behavior.
-- @param event_desc event descriptor (return value of /toroco/device or /toroco/behavior)

local release_inhibition = function (behavior, event_desc)

    local event = get_real_event (event_desc)

    if not event then
	    log ('TOROCO', 'ERROR', 'release_inhibition(): receiver is not valid. %s %s', section, task)
    end

    inhibited_events [event] [behavior] = nil

    sched.schedule_signal (M.events.release [event])


    if M.active_events_inhibited [event]  then
        local beh = M.wait_for_behavior (event_desc.emitter)

        local value = M.active_events_inhibited [event]

        M.active_events_inhibited [event] = nil
        
        -- set the event as active with the new values.
        M.active_events [event] = value
    end
end

---- Inhibit an event. ///
-- This function inhibits an event sent by a behavior.
-- The inhibition is independent of other inhibitions to the same event that were set by other behaviors.
-- @param behavior    Inhibiting behavior.
-- @param event_desc   Event descriptor (return value of /toroco/device or /toroco/behavior)
-- @param[opt] timeout Number of seconds.

local inhibit = function (behavior, event_desc, timeout)

    local event = get_real_event(event_desc)

    if not event then
	    log ('TOROCO', 'ERROR', 'inhibit(): receiver is not valid. %s %s', section, task)
    end

    -- if the event is not inhibited for longer than proposed, set the new time.
    -- if the event is inhibited for longer than proposed, do nothing.
    -- if there is no timeout, delete the expire time.

    inhibited_events [event] = inhibited_events [event] or {}

    if timeout then
        inhibited_events [event] [behavior] = { expire_time = sched.get_time() + timeout }

        -- check later for expiration
        sched.run (function ()
            local waitd = {
		        timeout = timeout,
	        }
            sched.wait (waitd)
            if inhibited_events [event] [behavior] then
                update_inhibition_expiration (event, behavior, inhibited_events [event] [behavior])
            end
        end)

    else
        inhibited_events [event] [behavior] = { expire_time = nil }
    end

    if M.active_events [event] then
        -- set the event as inactive
        M.active_events_inhibited [event] = M.active_events [event]
        M.active_events [event] = nil
        
        local beh = M.wait_for_behavior (event_desc.emitter)

        -- release the inhibitions for the event
        for _, inhibition_target in ipairs (beh.inhibition_targets [event_desc.name] or {}) do

            M.release_inhibition (beh, inhibition_target)
        end

        -- release the suppressions for the event
        for _, suppression_target in ipairs (beh.suppression_targets [event_desc.name] or {}) do
            release_suppression (beh, suppression_target.event, suppression_target.receiver)
        end
    end
end

---- Suppresses an event received by a specific behavior. ///
-- The suppression is associated with the running behavior,
-- and is independent of other suppressions to the same event that were set by other behaviors.
-- @param behavior      Suppressing behavior.
-- @param event_desc    Event descriptor
-- @param receiver_desc Receiver descriptor (return value of /toroco/behavior)
-- @param[opt] timeout  Number of seconds.

local suppress = function (behavior, event_desc, receiver_desc, timeout)

    local event = get_real_event (event_desc)

    if not event then
	    log ('TOROCO', 'ERROR', 'suppress(): receiver is not valid. %s %s', section, task)
    end

    for _, receiver in ipairs (registered_receivers[event]) do
        if receiver.name == receiver_desc.emitter then
            -- set receiver as suppressed
            receiver.suppressed [event] = receiver.suppressed [event] or {}
            
            if timeout then
                receiver.suppressed [event] [behavior] = { expire_time = sched.get_time() + timeout }

                -- check later for expiration
                sched.run (function ()
                    local waitd = {
		                timeout = timeout,
	                }
                    sched.wait (waitd)
                    if receiver.suppressed [event] [behavior] then
                        update_suppression_expiration (event, behavior, receiver.suppressed [event] [behavior], receiver)
                    end
                end)

            else
                receiver.suppressed [event] [behavior] = { expire_time = nil }
            end
        end
    end
end


-- returns the task name.
-- conf: configuration table of the task.

local get_task_name = function(conf)
    local config = toribio.configuration['tasks'] or {}    
    for k, v in pairs(config) do
        if v == conf then
            return k
        end
    end
end

-- Registers the dispatch signal function to an event
-- event: event to be registered.

local register_dispatcher = function(event)

    inhibited_events [event] = inhibited_events [event] or {}

    local waitd = {
        event,
        buff_mode = 'keep_last'
    }

    local no_filter_receiver = function (event, ...)
        dispatch_signal (event, nil, ...)
    end

    sched.sigrun (waitd, no_filter_receiver)
end

-- Stores the task for the event of the inputs in 'registered_receivers',
-- and registers the event aliases for the input.

local register_handler = function(behavior_name, input_name, input_sources, input_handler)

    -- initialize the callback receiver
    local receiver = {}
    receiver.name = behavior_name
    receiver.event_alias = {}
    receiver.suppressed = {}
    receiver.input_name = input_name

    if input_sources.type then
        input_sources = {input_sources}
    end

    for _, input_source in ipairs (input_sources) do
    
        -- add the receiver to registered_receivers
        local event = get_real_event (input_source)
        
        if not event then
        	error ('Torocó error: Input event \'' .. input_source.emitter .. '.' .. input_source.name .. '\' not found.')
        end

        if not registered_receivers [event] then
            registered_receivers [event] = {}

            register_dispatcher (event)
        end

        table.insert (registered_receivers [event], receiver)
    end

    -- initialize the callback function
    local mx = mutex.new()
    local fsynched = mx:synchronize (function(_, ...)
            input_handler(input_name, ...)
        end
    )

    local waitd = {
		receiver.event_alias,
        buff_mode = 'keep_last'
	}

 	local taskd = sched.run( function()
		while true do
			fsynched(sched.wait(waitd))
		end
	end)

    receiver.taskd = taskd

    return receiver
end 

---- Configures a device polling function. ///
-- @param event_desc Event descriptor (return value of /toroco/device)
-- @param time  	 Refresh time in seconds
-- @param converter  Function for converting the raw value

M.configure_polling = function (event_desc, time, converter)
    do_device_polling (event_desc, time, converter)
end

---- Wait for an input. ///
-- This function pauses a coroutine or trigger handler 
-- until an input is received.
-- @param input_desc      Input descriptor (return value of /toroco/input)
-- @param[opt] timeout    Number of seconds to wait or return nil.
-- @return                List of extra parameters of the received event. If there is none, it returns nil.

M.wait_for_input = function(input_desc, timeout)

    -- initialize the waiting receiver
    local receiver = {}
    receiver.name = M.behavior_taskd [sched.running_task].name
    receiver.event_alias = {}
    receiver.suppressed = {}
    receiver.execute_count = 1
    receiver.input_name = input_desc.name

        -- get event
    local input_sources = M.behavior_taskd [sched.running_task].input_sources [input_desc.name]
    
    if input_sources.type then
        input_sources = {input_sources}
    end

    for _, input_source in ipairs (input_sources) do

        -- add the receiver to registered_receivers
        local event = get_real_event (input_source)

        table.insert (registered_receivers [event], receiver)
    end

    -- initialize the waiting function
    local waitd = {
		receiver.event_alias,
		timeout = timeout,
        buff_mode = 'keep_last'
	}

    local key = #M.behavior_taskd [sched.running_task].receivers
    table.insert (M.behavior_taskd [sched.running_task].receivers, receiver)

    local f = function(_, ...)
        table.remove (M.behavior_taskd [sched.running_task].receivers, key)
        return ...
    end

    return f(sched.wait(waitd)) 
end

---- Send the behavior output. ///
-- This function sends the output of a behavior, that is,
-- it sends a signal for each output event of the behavior.
-- @param output_values Table with the extra parameters for each event.

M.send_output = function (output_values)

    local beh = M.behavior_taskd [sched.running_task]

    assert(beh, 'Must run in a behavior')

	-- for each event of the behavior, ...
    for event_name, event in pairs(beh.events) do

        -- if the event is defined at output_values, ...
        if output_values[event_name] then
            
            -- if it's a release event, ...
            if output_values[event_name].release then
            
                -- release the inhibitions for the event
                for _, inhibition_target in ipairs (beh.inhibition_targets [event_name] or {}) do

                    release_inhibition (M.behavior_taskd [sched.running_task], inhibition_target)
                end

                -- release the suppressions for the event
                for _, suppression_target in ipairs (beh.suppression_targets [event_name] or {}) do

                    release_suppression (M.behavior_taskd [sched.running_task], suppression_target.event, suppression_target.receiver)
                end

            -- if it's a send event, ...
            else
                local timeout = output_values[event_name].timeout

                -- start the inhibitions for the event
                for _, inhibition_target in ipairs (beh.inhibition_targets [event_name] or {}) do

                    inhibit (M.behavior_taskd [sched.running_task], inhibition_target, timeout)
                end

                -- start the suppressions for the event
                for _, suppression_target in ipairs (beh.suppression_targets [event_name] or {}) do

                    suppress (M.behavior_taskd [sched.running_task], suppression_target.event, suppression_target.receiver, timeout)
                end

        	    -- send a signal for the event, with the extra parameters
                sched.schedule_signal (event, unpack(output_values[event_name]))
            end

    	-- Warning: the event is not defined at the send_output invocation
        else
            sched.schedule_signal (event)
            print ('Torocó warning: Missing event ' .. event_name .. ' at send_output() in behavior ' .. M.behavior_taskd [sched.running_task].name .. '.')
        end
    end

    -- check for unused events in output_values
    local count = 0
    for _ in pairs(output_values) do 
        count = count + 1
    end
    if count > M.behavior_taskd [sched.running_task].event_count then
        print ('Torocó warning: Unused events at send_output() in behavior ' .. M.behavior_taskd [sched.running_task].name .. '.')
    end

    sched.wait()
end

---- Set the behavior output. ///
-- This function sets the output of a behavior, that is,
-- it sets a signal for each output event of the behavior.
-- If any of the output events is inhibited/suppressed and then released,
-- it resends the signal to the targets.
-- @param output_values Table with the extra parameters for each signal.

M.set_output = function (output_values)

    local beh = M.behavior_taskd [sched.running_task]

    assert(beh, 'Must run in a behavior')

    for event_name, value in pairs (output_values) do

        local event = beh.events [event_name]

        if not event then
            event = get_real_event(M.behavior[beh.name][event_name])
            print ('Torocó warning: Unused event \'' .. event_name .. '\' at send_output() in behavior ' .. beh.name .. '.')
        end

        if not inhibited_events [event] or inhibited_events [event] and next(inhibited_events [event]) == nil then
            -- set the event as active with the new values.
            M.active_events [event] = value

            -- start the inhibitions for the event
            for _, inhibition_target in ipairs (beh.inhibition_targets [event_name] or {}) do

                inhibit (beh, inhibition_target)
            end

            -- start the suppressions for the event
            for _, suppression_target in ipairs (beh.suppression_targets [event_name] or {}) do

                suppress (beh, suppression_target.event, suppression_target.receiver)
            end

            -- send a signal for the event, with the extra parameters
            sched.schedule_signal (event, unpack(value))
        else
            M.active_events_inhibited [event] = value
        end
    end

    sched.wait()
end

---- Set the behavior output. ///
-- This function unsets the output of a behavior, that is,
-- it unsets the signals for each output event of the behavior.

M.unset_output = function ()

    local beh = M.behavior_taskd [sched.running_task]

    for event_name, event in pairs(beh.events) do
        
        if M.active_events [event] then
            -- set the event as inactive
            M.active_events [event] = nil

            -- release the inhibitions for the event
            for _, inhibition_target in ipairs (beh.inhibition_targets [event_name] or {}) do

                release_inhibition (M.behavior_taskd [sched.running_task], inhibition_target)
            end

            -- release the suppressions for the event
            for _, suppression_target in ipairs (beh.suppression_targets [event_name] or {}) do
                release_suppression (M.behavior_taskd [sched.running_task], suppression_target.event, suppression_target.receiver)
            end
        end
        if M.active_events_inhibited [event] then
            M.active_events_inhibited [event] = nil
        end
    end
end

-- add coroutine to a behavior
-- behavior_desc: behavior descriptor (return value of /toroco/behavior)
-- coroutine: function to be executed.

local add_coroutine = function (behavior_name, coroutine) 

    local taskd = sched.new_task(coroutine)

    M.wait_for_behavior(behavior_name)

    M.behavior_taskd [taskd] = M.behaviors[behavior_name]

    table.insert (M.behaviors[behavior_name].tasks, taskd)

    sched.set_pause(taskd, true)
end

-- /// ///

local set_device_inputs = function(device_name, inputs)

    local receivers = {}
    for input_name, input_sources in pairs (inputs) do
        local proxy = function(_, ...)
            local device = my_wait_for_device (device_name) 
            device[input_name](...)
        end

        if input_sources.type then
            input_sources = {input_sources}
        end

        -- registers the (proxy) target function for the event.
        local receiver = register_handler (device_name, input_name, input_sources, proxy)
        sched.set_pause (receiver.taskd, false)

        table.insert (receivers, receiver)
    end
    
    return receivers
end

local emit_active_events = function (event_sources, receiver) 
    for _, event_desc in ipairs (event_sources) do
        local event = get_real_event (event_desc)
        if M.active_events[event] then
            dispatch_signal (event, receiver, unpack (M.active_events [event]))
            sched.wait()
        end
    end
end

---- Set the behavior inputs. ///
-- @param receiver_desc  Receiver descriptor (return value of /toroco/behavior)
-- @param inputs         Table where the keys are the input names
-- and the values are input descriptors (return value of /toroco/device or /toroco/behavior)

M.set_inputs = function (receiver_desc, inputs)

    local set_inputs_task = function ()
        local release_tasks = {}

        if receiver_desc.type == 'behavior' then
            local beh = M.wait_for_behavior (receiver_desc.emitter)

            for _, receiver in ipairs (beh.receivers) do
                
                local new_receiver = {}
                for k, v in pairs (receiver) do
                    new_receiver [k] = v
                end

                receiver.execute_count = 0

                local input_sources = inputs [new_receiver.input_name]
                if input_sources.type then
                    input_sources = {input_sources}
                end
                for _, input_source in ipairs (input_sources) do
                    -- add the receiver to registered_receivers
                    local event = get_real_event (input_source)

                    if not registered_receivers [event] then
                        registered_receivers [event] = {}

                        register_dispatcher (event)
                    end

                    table.insert (registered_receivers [event], new_receiver)
                end
            end

            for _, taskd in ipairs (beh.release_tasks) do
                sched.kill (taskd)
            end

        elseif receiver_desc.type == 'device' then
            local device = my_wait_for_device (receiver_desc.emitter)
            if M.devices [device] then

                for _, receiver in ipairs (M.devices [device].receivers) do
                    receiver.execute_count = 0
                    sched.kill (receiver.taskd)
                end

                M.devices [device].input_tasks = {}

                for _, taskd in ipairs (M.devices [device].release_tasks) do
                    sched.kill (taskd)
                end

                M.devices [device].release_tasks = {}
            end
        end

        -- Remove old suppresion targets in other behaviors.
        for _, beh in pairs (M.behaviors) do
            for output_name, output_targets in pairs (beh.suppression_targets) do
                for i = #output_targets, 1, -1 do
                    if output_targets[i].receiver.emitter == receiver_desc.emitter then 
                        table.remove (output_targets, i)
                    end
                end
            end
        end

        if receiver_desc.type == 'behavior' then

            local beh = M.wait_for_behavior (receiver_desc.emitter)
            
            beh.input_sources = inputs
            beh.release_tasks = release_tasks

        elseif receiver_desc.type == 'device' then

            local device = my_wait_for_device (receiver_desc.emitter)
            M.devices [device] = M.devices [device] or {}
            M.devices [device].release_tasks = release_tasks

            local receivers = set_device_inputs (receiver_desc.emitter, inputs)

            M.devices [device].receivers = receivers
        end

        -- for each input, ...
        for _, input_sources in pairs (inputs) do

            if input_sources.type then
                input_sources = {input_sources}
            end

            local suppression_targets = {}
            for _, input_source in ipairs (input_sources) do

                -- register a function to capture the release suppression event.
                local event = get_real_event (input_source)

                if not M.events.release [event] then
                    M.events.release [event] = {}
                end

                local mx = mutex.new()
                local fsynched = mx:synchronize (function (_, receiver)
                    receiver = receiver or receiver_desc.emitter
                    -- emit the event if it's active and should be received by this receiver
                    if receiver_desc.emitter == receiver and M.active_events [event] then
                        dispatch_signal (event, receiver, unpack (M.active_events [event]))
                    end
                end)

                local waitd = {
	                M.events.release [event],
                    buff_mode = 'keep_last'
                }

             	local taskd = sched.new_task( function()
	                while true do
		                fsynched(sched.wait(waitd))
	                end
                end)

                table.insert (release_tasks, taskd)

                -- initialize the dispatchers
                if not registered_receivers [event] then
                    registered_receivers [event] = {}

                    register_dispatcher (event)
                end
                
                if input_source.type == 'behavior' then
                    -- add the suppression targets to beh
                    local beh = M.wait_for_behavior (input_source.emitter)
                    beh.suppression_targets [input_source.name] =
                        beh.suppression_targets [input_source.name] or {}

                    for _, target in ipairs (suppression_targets) do
                        table.insert (beh.suppression_targets [input_source.name], {
                            receiver = receiver_desc,
                            event = target
                        })
                        
                        -- do suppressions if event already active
                        if M.active_events [event] then
                            suppress (beh, target, receiver_desc)
                        end
                    end
                end

                table.insert (suppression_targets, input_source)
            end
        end

        for _, input_events in pairs (inputs) do
            emit_active_events (input_events, receiver_desc.emitter)
        end
    end

    sched.run(set_inputs_task)
end

---- Sets the inhibitors for an emitter. ///
-- @param emitter_desc        Emitter descriptor (return value of /toroco/behavior or /toroco/device).
-- @param outputs_inhibitors  Table of inhibitors for each output event.

M.set_inhibitors = function (emitter_desc, outputs_inhibitors)

    local set_inhibitors_task = function ()

        -- for each output event to be inhibited, ...
        for output_name, inhibitors in pairs (outputs_inhibitors) do

            if inhibitors.type then
                inhibitors = {inhibitors}
            end

            -- for each inhibitor of the output event, ...
            for _, inhibitor_event_desc in ipairs (inhibitors) do

                if inhibitor_event_desc.type == 'behavior' then

                    local beh = M.wait_for_behavior (inhibitor_event_desc.emitter)
                    beh.inhibition_targets [inhibitor_event_desc.name] =
                        beh.inhibition_targets [inhibitor_event_desc.name] or {}

                    -- initialize the inhibitor's output event
                    get_real_event (inhibitor_event_desc)

                    table.insert (beh.inhibition_targets [inhibitor_event_desc.name], emitter_desc [output_name])
                end
            end
        end
    end     

    sched.run(set_inhibitors_task)
end


----  Create a trigger function. ///
-- Returns a coroutine that implements the trigger.
-- @param input_desc  Input descriptor (return value of /toroco/input)
-- @param handler     function to be called when the input is received.

M.trigger = function (input_desc, handler)

    local coroutine = function()
        local behavior =  M.behavior_taskd [sched.running_task]

        while not behavior.input_sources[input_desc.name] or not next(behavior.input_sources[input_desc.name]) do
            sched.wait()
        end

        local receiver = register_handler (behavior.name, input_desc.name, behavior.input_sources[input_desc.name], handler)

        table.insert (M.behaviors[behavior.name].receivers, receiver)
            
        M.behavior_taskd [receiver.taskd] = M.behaviors[behavior.name]

        table.insert (M.behaviors[behavior.name].tasks, receiver.taskd)
    end    

    return coroutine 
end


---- Suspend a behavior. ///
-- @param behavior_desc  Behavior descriptor (return value of /toroco/behavior)

M.suspend_behavior = function (behavior_desc)

    local tasks = M.behaviors [behavior_desc.emitter].tasks

    for i = #tasks, 1, -1 do

        if tasks [i].status ~= 'dead' then
            sched.set_pause (tasks [i], true)
        else
            M.behavior_taskd [tasks [i]] = nil
            table.remove (tasks, i)
        end
    end
end


---- Resume a behavior. ///
-- @param behavior_desc  Behavior descriptor (return value of /toroco/behavior)

M.resume_behavior = function (behavior_desc)

    local tasks = M.behaviors [behavior_desc.emitter].tasks

    for i = #tasks, 1, -1 do

        if tasks [i].status ~= 'dead' then
            sched.set_pause (tasks [i], false)
        else
            M.behavior_taskd [tasks [i]] = nil
            table.remove (tasks, i)
        end
    end
end


---- Resume a behavior. ///
-- @param behavior_desc  Behavior descriptor (return value of /toroco/behavior)

M.remove_behavior = function (behavior_desc)

    for _, taskd in ipairs (M.behaviors [behavior_desc.emitter].tasks) do
        if taskd.status ~= 'dead' then
            sched.kill (taskd)
        end
        M.behavior_taskd [taskd] = nil
    end

    for event, event_receivers in ipairs (registered_receivers) do
        for _, receiver in ipairs (event_receivers) do
            if receiver.name == behavior_desc.emitter then

                registered_receivers [event] = nil
            end
        end
    end

    for event, event_table in pairs (inhibited_events) do
        event_table [M.behaviors [behavior_desc.emitter]] = nil
    end

    M.behaviors [behavior_desc.emitter] = nil
    
end


-- suspend a task until the behavior has been registered to Torocó.
local waitd = {M.events.new_behavior}

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

---- Registers a behavior to Torocó. ///
-- This function loads a behavior from a file.
-- After loading the behaviors, add_behavior must be executed.
-- @param behavior_desc  Behavior descriptor (return value of /toroco/behavior).
-- @param pathname       Behavior filepath.
-- @param params         Values of the behavior parameters.

M.load_behavior = function (behavior_desc, pathname, params)

	-- load behavior file
	local behavior_file = loadfile (pathname..'.lua')
	if not behavior_file then
		error ('Torocó error: behavior file \'' .. pathname.. '.lua\' not found.')
	end
	
	-- execute file and get coroutines
	coroutines = {behavior_file()}
	
	-- add behavior to Torocó
    M.add_behavior (behavior_desc, coroutines, params)
end


---- Adds a behavior to Torocó. ///
-- This function adds a behavior to Torocó.
-- @param behavior_desc  Behavior descriptor (return value of /toroco/behavior).
-- @param coroutines     Table with the coroutines of the behavior.
-- @param params         Values of the behavior parameters.

M.add_behavior = function (behavior_desc, coroutines, params)
    
    local load_behavior = function()

		if M.behaviors [behavior_desc.emitter] then
			error ('Torocó error: Duplicated behavior \'' .. behavior_desc.emitter.. '\' at load_behavior().')
		end

        -- add behavior to 'M.behaviors'
        M.behaviors [behavior_desc.emitter] = {
            name = behavior_desc.emitter,
            events = {},
            event_count = 0,
            inhibition_targets = {},
            suppression_targets = {},
            input_sources = {},
            release_tasks = {},
            receivers = {},
            tasks = {},
            params = params or {}
        }

        -- emits new_behavior.
        M.behaviors [behavior_desc.emitter].loaded = true
        sched.signal (M.events.new_behavior, behavior_desc.emitter)
        
        for _, coroutine in ipairs (coroutines) do
            add_coroutine (behavior_desc.emitter, coroutine)
        end
    
        local init_behavior = function()
            local run_tasks = {}
            for _, task in ipairs (M.behaviors [behavior_desc.emitter].tasks) do
                sched.set_pause (task, false)
                table.insert (run_tasks, task)
            end

            for _, task in ipairs (run_tasks) do
                sched.run (task)
            end

            for _, input_events in pairs (M.behaviors [behavior_desc.emitter].input_sources) do
                emit_active_events (input_events, behavior_desc.emitter)
            end
        end

        sched.new_task(init_behavior)
    end

    sched.new_task(load_behavior)
end


---- Torocó main function. ///
-- @param[opt] toribio_conf_file Configuration filename.

M.run = function(toribio_conf_file)

    if toribio_conf_file then
        M.load_configuration(toribio_conf_file)
    else
        M.load_configuration('toribio.conf')
    end

    print ('Torocó go!')

    sched.loop()
end

-------------------------------------------------------------------------------

---- Load Torocó configuration file. ///
-- @param file Configuration filename.

M.load_configuration = function(file)

	-- load configuration file
	local func_conf, err = loadfile(file)
	if not func_conf then
		error ('Torocó error: configuration file \'' .. file .. '\' not found.')
	end
	
	-- configure the system
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

		        if conf and conf.load then
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
