local ua = ngx.var.http_user_agent or ""

if ua == "" then
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

local lower_ua = string.lower(ua)

local allowed_spiders = {
    "baiduspider",
    "googlebot",
    "bingbot",
    "sogou",
    "360spider",
    "bytespider"
}

for _, spider in ipairs(allowed_spiders) do
    if string.find(lower_ua, spider, 1, true) then
        return
    end
end

local blocked_keywords = {
    "sqlmap",
    "nikto",
    "masscan",
    "acunetix",
    "nessus"
}

for _, keyword in ipairs(blocked_keywords) do
    if string.find(lower_ua, keyword, 1, true) then
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
end
