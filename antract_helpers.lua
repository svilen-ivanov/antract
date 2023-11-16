--Copyright 2012-2014 37signals / Taylor Weibley
-- Additional changes by Svilen Ivanov (svilen.ivanov@gmail.com)
local pausedreqs = ngx.shared.pausedreqs
local enabled_key
local req_count_key

local function endswith(str, ending)
    return str ~= nil and (ending == "" or str:sub(-#ending) == ending)
end

--Check for app_name and 'scope' keys with it.
--app_name should be set in the server block of the
--nginx app config.
if ngx.var.app_name == nil then
  enabled_key = "enabled"
  req_count_key = "req_count"
else
  local app_name = tostring(ngx.var.app_name)
  enabled_key = "enabled_" .. app_name
  req_count_key = "req_count_" .. app_name
end

local enabled = pausedreqs:get(enabled_key or false)
-- Say how many connections we paused
local paused_count = tonumber(pausedreqs:get(req_count_key) or 0)

if endswith(ngx.var.uri, '/status') then
  local free_page_bytes = pausedreqs:free_space()
  if enabled then
    ngx.say("Pause is enabled, " .. paused_count .. " requests are currently paused. Free space in pausedreqs: " .. free_page_bytes .. 'b')
  else
    ngx.say("Pause is disabled. Free space in pausedreqs: " .. free_page_bytes .. 'b')
  end

  ngx.exit(200)

elseif endswith(ngx.var.uri, '/enable') then
  if enabled then
    local message = "Pause is already enabled, " .. paused_count .. " requests are currently paused."
    ngx.say(message)
    ngx.log(ngx.NOTICE, message)
    ngx.exit(200)
  end

  pausedreqs:flush_all()
  local success, err = pausedreqs:set(req_count_key, 0)
  if not success then
    local message = 'Failed to reset request count: ' .. (err or 'unknown')
    ngx.log(ngx.ERR, message)
    ngx.say(message)
    ngx.exit(500)
  end
  local success, err = pausedreqs:set(enabled_key, true)
  if not success then
    local message = 'Failed to reset enabled_key: ' .. (err or 'unknown')
    ngx.log(ngx.ERR, message)
    ngx.say(message)
    ngx.exit(500)
  end
  local message = 'Pause is enabled.'
  ngx.log(ngx.NOTICE, message)
  ngx.say(message)
  ngx.exit(200)

elseif endswith(ngx.var.uri, '/disable') then
  if not enabled then
    local message = 'Pause is already disabled.'
    ngx.say(message)
    ngx.log(ngx.NOTICE, message)
    ngx.exit(200)
  end

  -- Unpause requests
  pausedreqs:flush_all()

  local message = 'Pause is disabled. ' .. paused_count .. ' requests were held in-flight.'
  ngx.log(ngx.NOTICE, message)
  ngx.say(message)

  ngx.exit(200)
else
  ngx.exit(404)
end
