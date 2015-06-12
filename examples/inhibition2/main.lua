-- /// Torocó example - Inhibition and suppression ///
-- main.lua


local toroco = require 'toroco.toroco'
local input = toroco.input
local output = toroco.output
local device = toroco.device
local behavior = toroco.behavior


-- initialize behaviors

toroco.load_behavior (behavior.default, 'behaviors/default', {motors_vel = {1, 0, 0, 0}})
toroco.load_behavior (behavior.beh, 'behaviors/beh', {motors_vel = {1, 55, 0, 55}})
toroco.load_behavior (behavior.inhibitor, 'behaviors/inhibitor')

-- initialize inputs

toroco.set_inputs (behavior.beh, {
    trigger1 = device.mice.leftbutton
})

toroco.set_inputs (behavior.inhibitor, {
    trigger1 = device.mice.rightbutton
})

toroco.set_inhibitors (behavior.beh, {
    motors_setvel = behavior.inhibitor.clickbutton
})

toroco.set_inputs (device.trc_motor, {
    setvel2mtr = { behavior.default.motors_setvel, behavior.beh.motors_setvel }
})


-- run toroco

toroco.run ()


