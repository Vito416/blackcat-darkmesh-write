package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

local strict = os.getenv "WRITE_REQUIRE_ACTION_SCHEMA" == "1"

package.loaded["ao.shared.validation"] = nil
package.preload["ao.shared.schema"] = function()
  return {
    is_ready = function(scope)
      if scope == "actions" then
        return false, "schema_unavailable:actions"
      end
      return false, "schema_unavailable"
    end,
    validate_action = function()
      return false, { "schema_should_not_be_called" }
    end,
  }
end

local validation = require "ao.shared.validation"

local ok, errs = validation.validate_action("Ping", {})
local ok_with_validator, errs_with_validator =
  validation.validate_action("CreateOrder", { siteId = "site-fallback", cartId = "cart-fallback" })
if strict then
  if ok then
    io.stderr:write "schema_fallback(strict): expected failure when schema is unavailable\n"
    os.exit(1)
  end
  local first = type(errs) == "table" and errs[1] or nil
  if first ~= "schema_unavailable:actions" then
    io.stderr:write(
      "schema_fallback(strict): expected schema_unavailable:actions, got "
        .. tostring(first)
        .. "\n"
    )
    os.exit(1)
  end
  if ok_with_validator then
    io.stderr:write "schema_fallback(strict): expected validator-backed action to fail when schema is unavailable\n"
    os.exit(1)
  end
  local second = type(errs_with_validator) == "table" and errs_with_validator[1] or nil
  if second ~= "schema_unavailable:actions" then
    io.stderr:write(
      "schema_fallback(strict): expected schema_unavailable:actions for validator-backed action, got "
        .. tostring(second)
        .. "\n"
    )
    os.exit(1)
  end
  print "schema_fallback(strict): ok"
  os.exit(0)
end

if not ok then
  local first = type(errs) == "table" and errs[1] or tostring(errs)
  io.stderr:write("schema_fallback: expected handler fallback, got " .. tostring(first) .. "\n")
  os.exit(1)
end
if not ok_with_validator then
  local first = type(errs_with_validator) == "table" and errs_with_validator[1]
    or tostring(errs_with_validator)
  io.stderr:write(
    "schema_fallback: expected validator-backed action to pass, got " .. tostring(first) .. "\n"
  )
  os.exit(1)
end

print "schema_fallback: ok"
