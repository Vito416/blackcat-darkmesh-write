-- Bundle PII-scrubbed export NDJSON into a JSON array for immutability upload.
-- Uses WRITE_OUTBOX_EXPORT_PATH (or AO_WEAVEDB_EXPORT_PATH as fallback).
local path = os.getenv "WRITE_OUTBOX_EXPORT_PATH"
  or os.getenv "AO_WEAVEDB_EXPORT_PATH"
  or "public-export.ndjson"
local json_ok, cjson = pcall(require, "cjson.safe")
if not json_ok then
  io.stderr:write "cjson.safe not available\n"
  os.exit(1)
end
local f = io.open(path, "r")
if not f then
  io.stderr:write("cannot open export file: " .. tostring(path) .. "\n")
  os.exit(1)
end
local rows = {}
for line in f:lines() do
  if line and line:match "%S" then
    local obj = cjson.decode(line)
    if obj then
      table.insert(rows, obj)
    end
  end
end
f:close()
io.write(cjson.encode(rows))
