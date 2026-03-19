-- luacheck: max_line_length 220
-- Minimal JWT mapping check: run with
-- WRITE_REQUIRE_JWT=1 WRITE_JWT_HS_SECRET=dev-secret lua5.4 scripts/verify/jwt_actor_spec.lua
local ok_mime, _ = pcall(require, "mime")
if not ok_mime then
  print("jwt_actor_spec: skipped (mime module missing)")
  os.exit(0)
end
local auth = require "ao.shared.auth"
local token = [[eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJqd3QtZWRpdG9yLTEiLCJ0ZW5hbnQiOiJqd3QtdGVuYW50LTEiLCJyb2xlIjoiZWRpdG9yIn0.SZtRcFbtUVjr9K1WkmVUfUMEfW7Zx8sCJ_cvQ5RYesg]]
local msg = { jwt = token }
local ok, claims = auth.consume_jwt(msg)
assert(ok, "jwt validation failed: " .. tostring(claims))
assert(msg.actor == "jwt-editor-1", "actor not mapped")
assert(msg.tenant == "jwt-tenant-1", "tenant not mapped")
assert(msg["Actor-Role"] == "editor", "role not mapped")
print("jwt_actor_spec: ok")
-- luacheck: max_line_length 200
