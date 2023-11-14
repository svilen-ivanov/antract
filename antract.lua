--Copyright 2012-2014 37signals / Taylor Weibley
-- Additional changes by Svilen Ivanov (svilen.ivanov@gmail.com)
local sleep_time = tonumber(ngx.var.antract_interval)
local sleep_jitter_time = tonumber(ngx.var.antract_interval_jitter or 0)
local max_time = tonumber(ngx.var.antract_max_time)
local pausedreqs = ngx.shared.pausedreqs
local health_check_path = ngx.var.antract_health_check_path
local privileged_user_agent = ngx.var.antract_privileged_user_agent
local enabled_key
local req_count_key

--Check for app_name and 'scope' keys with it.
if ngx.var.app_name == nil then
  enabled_key = "enabled"
  req_count_key = "req_count"
else
  local app_name = tostring(ngx.var.app_name)
  enabled_key = "enabled_" .. app_name
  req_count_key = "req_count_" .. app_name
end

local function on_abort_handler()
  local current_count, err = pausedreqs:incr(req_count_key, -1)
  if current_count == nil then
    ngx.log(ngx.ERR, "Failed to decrement the req_count_key: " .. (err or 'unknown'))
  end

  ngx.log(ngx.INFO, "Client was aborted, current in-flight request count: " .. (current_count or 'unknown'))
  ngx.exit(500)
end

 local ok, err = ngx.on_abort(on_abort_handler)
 if not ok then
     ngx.log(ngx.ERR, "Failed to register the on_abort callback: " .. err)
     ngx.exit(500)
 end

if pausedreqs:get(enabled_key) then
  --Pass healthchecks no matter what.
  if ngx.var.uri == health_check_path then
    ngx.log(ngx.INFO, 'Passing through health check request: ' .. (ngx.var.uri or nil))
    return
  end

  --Pass special user agent no matter what. (Pingdom perhaps?)
  if ngx.var.http_user_agent and ngx.var.http_user_agent ~= '' then
    if string.match(ngx.var.http_user_agent, privileged_user_agent) then
      ngx.log(ngx.INFO, 'Passing through privileged user agent request: ' .. (ngx.var.http_user_agent or nil))
      return
    end
  end

  sleep_time = sleep_time + sleep_jitter_time * math.random()
  local wait_time = 0;

  local request_count, err = pausedreqs:incr(req_count_key, 1)
  if request_count == nil then
    ngx.log(ngx.ERR, "Failed to increment the req_count_key: " .. err)
    ngx.exit(500)
 end
  ngx.log(ngx.INFO, 'Paused request #' .. request_count)

  repeat
    -- Unpause this request if the enabled key is gone
    if pausedreqs:get(enabled_key) == nil then
      ngx.log(ngx.INFO, "Unpause after " .. wait_time .. " seconds")

      return
    else
      ngx.sleep(sleep_time)
      wait_time = wait_time + sleep_time
      -- This will be very noisy with a small sleep_time
      -- ngx.log(ngx.DEBUG, 'Paused waiting for ' .. wait_time .. ' seconds total')
    end
  until wait_time > max_time

else
  --Self explanatory
  return
end
