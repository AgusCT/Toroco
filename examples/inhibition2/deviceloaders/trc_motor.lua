-- Toroco deviceloader to test signaling

local M = {}

--- Initialize and starts the module.
-- @param conf the configuration table (see @{conf}).
M.init = function(conf)
	local toribio = require 'toribio'
	local selector = require 'lumen.tasks.selector'
	local sched = require 'lumen.sched'

	local devicename='trc_motor'
	
	local device={}
	
	--- Name of the device (in this case, 'mice').
	device.name=devicename

	--- Module name (in this case, 'mice').
	device.module='trc_motor'


	--- Events emitted by this device.
	-- @table events
	device.events={
	}

	--- Prints the values passed
	device.setvel2mtr=function(...)
		print('trc_motor: ', ...)
	end
	
	toribio.add_device(device)
end

return M

