std = "lua51"
max_line_length = 120

exclude_files = {
  "dist/**",
  "node_modules/**",
  "tests/security/**",
  "scripts/verify/envelope_guard.lua",
}

files = {}
files["scripts/verify/envelope_guard.lua"] = { ignore = { "121", "122" } }
unused_args = false
ignore = { "121" }
files["scripts/verify/envelope_guard.lua"] = { ignore = { "121" } }
