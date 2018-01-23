local prometheus = require("nginx.prometheus").init("prometheus_metrics")
local metric_requests = prometheus:counter("nginx_http_requests_total", "Number of HTTP requests", {"status"})
local metric_connections = prometheus:gauge("nginx_http_connections", "Number of HTTP connections", {"state"})
local opened_connections = prometheus:gauge('nginx_opened_connections', "Number of connections in flight", {'host'})
local proxy_endpoint = os.getenv('PROXY_ENDPOINT') or error('missing PROXY_ENDPOINT variable')

local limit_conn = require "resty.limit.conn"
local tonumber = tonumber

local _M = {

}


function _M:access()
  -- limit the requests under 200 concurrent requests (normally just
  -- incoming connections unless protocols like SPDY is used) with
  -- a burst of 100 extra concurrent requests, that is, we delay
  -- requests under 300 concurrent connections and above 200
  -- connections, and reject any new requests exceeding 300
  -- connections.
  -- also, we assume a default request time of 0.5 sec, which can be
  -- dynamically adjusted by the leaving() call in log_by_lua below.
  local lim, err = limit_conn.new("conn_store", 1, 2, 0.5)
  if not lim then
    ngx.log(ngx.ERR,
      "failed to instantiate a resty.limit.conn object: ", err)
    return ngx.exit(500)
  end

  -- the following call must be per-request.
  -- here we use the remote (IP) address as the limiting key
  local key = ngx.var.host
  local delay, err = lim:incoming(key, true)
  if not delay then
    if err == "rejected" then
      return ngx.exit(503)
    end
    ngx.log(ngx.ERR, "failed to limit req: ", err)
    return ngx.exit(500)
  end

  local labels = { key }

  if lim:is_committed() then
    local ctx = ngx.ctx
    ctx.limit_conn = lim
    ctx.limit_conn_key = key
    ctx.limit_conn_delay = delay
    ctx.metric_labels = labels
  end

  -- the 2nd return value holds the current concurrency level
  -- for the specified key.
  local conn = err

  opened_connections:set(conn, labels)

  if delay >= 0.001 then
    ngx.log(ngx.WARN, 'need to delay key: ', key, ' by: ', delay,'s')
    -- the request exceeding the 200 connections ratio but below
    -- 300 connections, so
    -- we intentionally delay it here a bit to conform to the
    -- 200 connection limit.
    -- ngx.log(ngx.WARN, "delaying")
    ngx.sleep(delay)
  end
end

function _M:proxy_endpoint()
  return proxy_endpoint
end

function _M:metrics()
  metric_connections:set(ngx.var.connections_reading, {"reading"})
  metric_connections:set(ngx.var.connections_waiting, {"waiting"})
  metric_connections:set(ngx.var.connections_writing, {"writing"})

  return prometheus:collect()
end

function _M:log()
  local ctx = ngx.ctx
  local lim = ctx.limit_conn
  if lim then
    -- if you are using an upstream module in the content phase,
    -- then you probably want to use $upstream_response_time
    -- instead of ($request_time - ctx.limit_conn_delay) below.
    local latency = tonumber(ngx.var.request_time) - ctx.limit_conn_delay
    local key = ctx.limit_conn_key
    assert(key)
    local conn, err = lim:leaving(key, latency)

    if not conn then
      ngx.log(ngx.ERR,
        "failed to record the connection leaving ",
        "request: ", err)
      return
    end

    opened_connections:set(conn,  ctx.metric_labels)
  end


  metric_requests:inc(1, {ngx.var.status})
end

return _M
