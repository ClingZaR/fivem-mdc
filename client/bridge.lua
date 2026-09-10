--[[
    FRAMEWORK BRIDGE (client)

    The client half of the adapter. Together with server/bridge.lua this is the
    whole framework surface of the resource. Port these two files and the MDC
    runs on anything.

    Contract
    --------
    ClientBridge.GetPlayerData() -> { job = { name, type, onduty, grade } } | nil

    `job.type` must be 'leo' for police-type jobs. If your framework has no job
    types, map your police job names in JOB_TYPES below.
]]

ClientBridge = {}

local JOB_TYPES = {
    -- ['police']  = 'leo',
    -- ['sheriff'] = 'leo',
}

---@return table|nil
function ClientBridge.GetPlayerData()
    local data = exports.qbx_core:GetPlayerData()
    if not data then return nil end

    if data.job and not data.job.type and JOB_TYPES[data.job.name] then
        data.job.type = JOB_TYPES[data.job.name]
    end
    return data
end
