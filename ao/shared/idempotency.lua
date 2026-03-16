-- Idempotency registry with optional persistence via Storage.

local storage = require("ao.shared.storage")
local persist_ok, persist = pcall(require, "ao.shared.persist")
local Idem = {}
local store = {}
local IDEM_PATH = os.getenv("WRITE_IDEM_PATH")

function Idem.lookup(request_id)
  if not request_id then return nil end
  return store[request_id]
end

-- Compatibility helper used by AO/Wr processes; returns cached outcome or nil.
function Idem.check(request_id)
  return Idem.lookup(request_id)
end

function Idem.record(request_id, outcome)
  if not request_id then return true end
  store[request_id] = outcome
  if IDEM_PATH then
    storage.put("idempotency", store)
    storage.persist(IDEM_PATH)
  end
   -- Persist to WeaveDB export / local snapshot (PII-scrubbed) if available
  if persist_ok and persist.save then
    persist.save("idempotency", store)
  end
  return true
end

function Idem.persist(path)
  storage.put("idempotency", store)
  return storage.persist(path)
end

function Idem.load(path)
  local ok = storage.load(path)
  if ok then
    local persisted = storage.get("idempotency")
    if type(persisted) == "table" then store = persisted end
  end
  if not ok and persist_ok and persist.load then
    local recovered = persist.load("idempotency")
    if type(recovered) == "table" then store = recovered end
  end
end

if IDEM_PATH then
  Idem.load(IDEM_PATH)
end

return Idem
