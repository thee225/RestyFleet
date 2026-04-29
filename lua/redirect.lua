-- 动态跳转预留入口。
-- 默认行为：不做任何跳转。
--
-- 后续扩展示例：
--   ngx.var.http_user_agent  - 按浏览器、设备、蜘蛛或 App UA 分流
--   ngx.var.http_referer     - 按来源 Referer 分流
--   ngx.var.http_cookie      - 按活动或用户分组 Cookie 分流
--   ngx.var.uri              - 按访问路径分流
--
-- 示例：
--   if ngx.var.uri == "/old" then
--       return ngx.redirect("/new", ngx.HTTP_MOVED_TEMPORARILY)
--   end

return
