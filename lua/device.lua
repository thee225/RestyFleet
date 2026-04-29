local _M = {}

local mobile_patterns = {
    "android",
    "iphone",
    "ipad",
    "ipod",
    "mobile",
    "windows phone"
}

function _M.is_mobile(user_agent)
    if not user_agent or user_agent == "" then
        return false
    end

    local ua = string.lower(user_agent)
    for _, pattern in ipairs(mobile_patterns) do
        if string.find(ua, pattern, 1, true) then
            return true
        end
    end

    return false
end

return _M
