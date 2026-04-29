-- Dynamic redirect hook.
-- Default behavior: no redirect.
--
-- Extension ideas:
--   ngx.var.http_user_agent  - route by browser, device, crawler, or app UA
--   ngx.var.http_referer     - route traffic from specific referrers
--   ngx.var.http_cookie      - route by campaign or user segment cookie
--   ngx.var.uri              - route by path
--
-- Example:
--   if ngx.var.uri == "/old" then
--       return ngx.redirect("/new", ngx.HTTP_MOVED_TEMPORARILY)
--   end

return
