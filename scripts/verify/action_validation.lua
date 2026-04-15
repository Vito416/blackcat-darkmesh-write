-- luacheck: max_line_length 200
package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

local function require_signing_env()
  if os.getenv "WRITE_REQUIRE_SIGNATURE" ~= "1" then
    io.stderr:write "SKIP action_validation: WRITE_REQUIRE_SIGNATURE must be 1\n"
    os.exit(0)
  end
  if not os.getenv "WRITE_SIG_PRIV_HEX" or not os.getenv "WRITE_SIG_PUBLIC" then
    io.stderr:write "SKIP action_validation: set WRITE_SIG_PRIV_HEX and WRITE_SIG_PUBLIC\n"
    os.exit(0)
  end
end

local function json_escape(str)
  return str:gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function json_encode(val)
  local t = type(val)
  if t == "nil" then
    return "null"
  elseif t == "boolean" or t == "number" then
    return tostring(val)
  elseif t == "string" then
    return '"' .. json_escape(val) .. '"'
  elseif t == "table" then
    local is_array = (#val > 0)
    if is_array then
      local parts = {}
      for i = 1, #val do
        parts[#parts + 1] = json_encode(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(val) do
        keys[#keys + 1] = k
      end
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json_encode(val[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local function sign_cmd(cmd)
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "w"))
  f:write(json_encode(cmd))
  f:close()
  local handle = io.popen(
    string.format(
      "WRITE_SIG_PRIV_HEX=%q node scripts/sign-write.js --file %q",
      os.getenv "WRITE_SIG_PRIV_HEX",
      tmp
    ),
    "r"
  )
  if not handle then
    os.remove(tmp)
    error "cannot run sign-write.js"
  end
  local out = handle:read "*a"
  handle:close()
  os.remove(tmp)
  local sig = (out or ""):match '"signature"%s*:%s*"([^"]+)"'
  local sig_ref = (out or ""):match '"signatureRef"%s*:%s*"([^"]+)"'
  assert(sig, "signature missing in sign-write output")
  cmd.signature = sig
  cmd["Signature-Ref"] = sig_ref or "write-ed25519-test"
  return cmd
end

require_signing_env()

local write = require "ao.write.process"

local function expect_error(res)
  return res and res.status == "ERROR"
end

local bad = write.route {
  Action = "PublishPageVersion",
  ["Request-Id"] = "v1",
  ["Actor-Role"] = "admin",
  nonce = "n1",
  ts = os.time(),
}
assert(expect_error(bad), "missing payload should error")

local ok = write.route(sign_cmd {
  Action = "PublishPageVersion",
  ["Request-Id"] = "v2",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-1",
  nonce = "n2",
  ts = os.time(),
  payload = { siteId = "s1", pageId = "p1", versionId = "v1", manifestTx = "tx123" },
})
assert(ok.status == "OK", "publish validation should pass")

local bad_route = write.route {
  Action = "UpsertRoute",
  ["Request-Id"] = "v3",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-1",
  nonce = "n3",
  ts = os.time(),
  payload = { siteId = "s1" },
}
assert(expect_error(bad_route), "missing path/target should error")

local good_route = write.route(sign_cmd {
  Action = "UpsertRoute",
  ["Request-Id"] = "v4",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-1",
  nonce = "n4",
  ts = os.time(),
  payload = { siteId = "s1", path = "/p", target = "page:p1" },
})
assert(good_route.status == "OK", "route validation should pass")

local bad_pay = write.route {
  Action = "CreatePaymentIntent",
  ["Request-Id"] = "v5",
  ["Actor-Role"] = "admin",
  nonce = "n5",
  ts = os.time(),
  payload = { orderId = "o1" },
}
assert(expect_error(bad_pay), "missing amount/currency should error")

local bad_inline_order = write.route(sign_cmd {
  Action = "CreateOrder",
  ["Request-Id"] = "v5b",
  ["Actor-Role"] = "admin",
  nonce = "n5b",
  ts = os.time(),
  payload = { siteId = "s1", items = { { sku = "sku-inline", qty = 1, price = 10 } } },
})
assert(expect_error(bad_inline_order), "inline CreateOrder without currency should error")

local ok_pay = write.route(sign_cmd {
  Action = "CreatePaymentIntent",
  ["Request-Id"] = "v6",
  ["Actor-Role"] = "admin",
  nonce = "n6",
  ts = os.time(),
  payload = { orderId = "o1", amount = 1000, currency = "USD" },
})
assert(ok_pay.status == "OK", "payment intent should pass")

local bad_provider = write.route {
  Action = "ProviderWebhook",
  ["Request-Id"] = "v7",
  ["Actor-Role"] = "ops",
  nonce = "n7",
  ts = os.time(),
  payload = { provider = "stripe", eventType = "payment", orderId = nil },
}
assert(expect_error(bad_provider), "provider webhook needs target ids")

-- Regression: action role policy must apply for lowercase `action` envelopes too.
local lowercase_forbidden = write.route(sign_cmd {
  action = "CreateForm",
  requestId = "v8",
  ["Actor-Role"] = "viewer",
  actor = "validator",
  tenant = "tenant-1",
  nonce = "n8",
  ts = os.time(),
  payload = {},
})
assert(expect_error(lowercase_forbidden), "lowercase action should still enforce role policy")

-- Regression: idempotency must not bypass auth/validation across tenant boundaries.
local idem_seed = write.route(sign_cmd {
  Action = "PublishPageVersion",
  ["Request-Id"] = "idem-1",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-1",
  nonce = "n9",
  ts = os.time(),
  payload = { siteId = "s1", pageId = "p1", versionId = "v1", manifestTx = "tx123" },
})
assert(idem_seed.status == "OK", "idempotency seed write should succeed")

local idem_cross_tenant = write.route {
  Action = "PublishPageVersion",
  ["Request-Id"] = "idem-1",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-2",
  nonce = "n10",
  ts = os.time(),
  payload = { siteId = "s1" },
}
assert(
  expect_error(idem_cross_tenant),
  "idempotency should not short-circuit before auth/validation"
)

print "action_validation: ok"
-- luacheck: max_line_length 200
-- luacheck: max_line_length 200
