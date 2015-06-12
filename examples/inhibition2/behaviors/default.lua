-- /// co ///

local toroco = require 'toroco.toroco'
local input = toroco.input
local params = toroco.params

-- /// functions ///

local co = function ()
    toroco.set_output {motors_setvel = params.motors_vel}
end

return co

