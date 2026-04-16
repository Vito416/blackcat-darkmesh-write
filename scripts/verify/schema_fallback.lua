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
  print "schema_fallback(strict): ok"
  os.exit(0)
end

if not ok then
  local first = type(errs) == "table" and errs[1] or tostring(errs)
  io.stderr:write("schema_fallback: expected handler fallback, got " .. tostring(first) .. "\n")
  os.exit(1)
end

print "schema_fallback: ok"
