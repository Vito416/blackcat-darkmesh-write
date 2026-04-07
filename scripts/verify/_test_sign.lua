-- Helper for verify scripts: sign command when WRITE_SIG_PRIV_HEX is available.
-- Falls back to passthrough when signing env is not configured.
local M = {}

local ok_cjson, cjson = pcall(require, "cjson.safe")

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

local function can_sign()
  local priv = os.getenv "WRITE_SIG_PRIV_HEX"
  return priv and #priv == 64
end

function M.maybe_sign(cmd)
  if not can_sign() then
    return cmd
  end
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
  if not ok_cjson or not cjson then
    return cmd
  end
  local parsed = cjson.decode(out or "{}") or {}
  cmd.signature = parsed.signature or cmd.signature
  cmd["Signature-Ref"] = parsed.signatureRef or cmd["Signature-Ref"] or "write-ed25519-test"
  cmd.signatureRef = cmd.signatureRef or cmd["Signature-Ref"]
  return cmd
end

return M
