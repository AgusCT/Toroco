-- /// inhibitor ///

local toroco = require 'toroco.toroco'
local input = toroco.input
local device = toroco.device
local behavior = toroco.behavior

-- /// Handler functions ///

local handler1 = function (event, value) 
	print (' ')

    if value then
        print ('inhibition started')        

        toroco.set_output {clickbutton = {'suppressed!'}}
    else
        print ('inhibition released')   

        toroco.unset_output ()
    end
end

return toroco.trigger (input.trigger1, handler1)

