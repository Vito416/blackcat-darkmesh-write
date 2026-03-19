#!/usr/bin/env lua
-- Verify WRITE_OUTBOX_EXPORT_PATH NDJSON for JSON validity and PII absence.

local path = os.getenv "WRITE_OUTBOX_EXPORT_PATH" or os.getenv "AO_WEAVEDB_EXPORT_PATH"
if not path or path == "" then
  io.stderr:write "WRITE_OUTBOX_EXPORT_PATH not set\n"
  os.exit(0)
end

local pii_keys = {
  address = true,
  Address = true,
  line1 = true,
  line2 = true,
  city = true,
  postal = true,
  region = true,
  phone = true,
  email = true,
  subject = true,
  ["Subject"] = true,
  customerId = true,
  ["Customer-Id"] = true,
  customerRef = true,
  ["Customer-Ref"] = true,
  token = true,
  tokenHash = true,
  ["Token-Hash"] = true,
  sessionHash = true,
  ["Session-Hash"] = true,
  jwt = true,
  JWT = true,
}

local ok_json, cjson = pcall(require, "cjson.safe")
if not ok_json then
  io.stderr:write "cjson.safe not available\n"
  os.exit(1)
end

local f = io.open(path, "r")
if not f then
  io.stderr:write("export not found: " .. path .. "\n")
  os.exit(1)
end

local line_no = 0
for line in f:lines() do
  line_no = line_no + 1
  local obj, err = cjson.decode(line)
  if not obj then
    io.stderr:write(string.format("invalid JSON at line %d: %s\n", line_no, err or "?"))
    os.exit(1)
  end
  local function walk(tbl)
    if type(tbl) ~= "table" then
      return
    end
    for k, v in pairs(tbl) do
      if pii_keys[k] then
        io.stderr:write(string.format("PII key '%s' found at line %d\n", k, line_no))
        os.exit(1)
      end
      if type(v) == "table" then
        walk(v)
      end
    end
  end
  walk(obj)
end
f:close()
print("export_verify: ok (" .. line_no .. " lines)")
