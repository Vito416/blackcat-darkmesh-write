-- PII-scrubbing append-only export for WeaveDB/Arweave bundling.
-- Enabled when WRITE_OUTBOX_EXPORT_PATH (or AO_WEAVEDB_EXPORT_PATH) is set.

local Export = {}

local path = os.getenv("WRITE_OUTBOX_EXPORT_PATH") or os.getenv("AO_WEAVEDB_EXPORT_PATH")
local json_ok, cjson = pcall(require, "cjson.safe")

local pii_keys = {
  address = true, Address = true,
  line1 = true, line2 = true, city = true, postal = true, region = true,
  phone = true, email = true,
  subject = true, ["Subject"] = true,
  customerId = true, ["Customer-Id"] = true,
  customerRef = true, ["Customer-Ref"] = true,
  token = true, tokenHash = true, ["Token-Hash"] = true,
  sessionHash = true, ["Session-Hash"] = true,
  jwt = true, JWT = true,
}

local function scrub(value)
  local t = type(value)
  if t ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    if not pii_keys[k] then
      out[k] = scrub(v)
    end
  end
  return out
end

function Export.write(ev)
  if not path or not json_ok or not ev then
    return
  end
  local f = io.open(path, "a")
  if not f then
    return
  end
  local ok, encoded = pcall(cjson.encode, scrub(ev))
  if ok and encoded then
    f:write(encoded)
    f:write("\n")
  end
  f:close()
end

return Export
