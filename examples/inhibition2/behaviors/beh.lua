-- /// co ///

local toroco = require 'toroco.toroco'
local input = toroco.input
local params = toroco.params

-- /// functions ///

local co = function ()
    while true do
        local v1 = toroco.wait_for_input (input.trigger1)
        if v1 then
            toroco.set_output {motors_setvel = params.motors_vel}
        else
            toroco.unset_output ()
        end
    end
end

return co

