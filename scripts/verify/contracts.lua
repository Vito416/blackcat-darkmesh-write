local write = require "ao.write.process"

local function req(action, extra)
  local msg = {
    action = action,
    ["Request-Id"] = action .. "-req",
    ["Actor-Role"] = "admin",
    payload = {},
  }
  if extra then
    for k, v in pairs(extra) do
      msg[k] = v
    end
  end
  return msg
end

local tests = {
  function()
    local resp = write.route(req("SaveDraftPage", { payload = { siteId = "s1", pageId = "home", blocks = {} } }))
    assert(resp.status == "OK")
  end,
  function()
    local resp = write.route(req("PublishPageVersion", { payload = { siteId = "s1", pageId = "home", versionId = "v1", manifestTx = "tx-1" } }))
    assert(resp.status == "OK")
  end,
  function()
    local resp = write.route(req("UpsertRoute", { payload = { siteId = "s1", path = "/", target = { type = "page", id = "home" } } }))
    assert(resp.status == "OK")
  end,
  function()
    local resp = write.route(req("UpsertProduct", { payload = { siteId = "s1", sku = "sku1", name = "Prod" } }))
    assert(resp.status == "OK")
  end,
  function()
    local resp = write.route(req("UnknownAction"))
    assert(resp.code == "UNKNOWN_ACTION")
  end,
}

for i, t in ipairs(tests) do
  local ok, err = pcall(t)
  if not ok then
    io.stderr:write(string.format("Test %d failed: %s\n", i, err))
    os.exit(1)
  end
end

print("contracts: ok")
-- luacheck: max_line_length 200
