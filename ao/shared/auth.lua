-- Minimal auth helpers for write process (secretless).

local Auth = {}

-- Accept all for now; upstream caller controls trust.
function Auth.enforce(_msg)
  return true
end

local function contains(list, value)
  if not list then
    return false
  end
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

function Auth.require_role(msg, allowed_roles)
  if not allowed_roles or #allowed_roles == 0 then
    return true
  end
  local role = msg["Actor-Role"] or msg.actorRole or msg.role
  if not role then
    return false, "missing_role"
  end
  if not contains(allowed_roles, role) then
    return false, "forbidden_role"
  end
  return true
end

function Auth.require_role_for_action(msg, policy)
  if not policy then
    return true
  end
  local roles = policy[msg.Action]
  if not roles then
    return true
  end
  return Auth.require_role(msg, roles)
end

-- No-op JWT consumer (accept everything)
function Auth.consume_jwt(_msg)
  return true
end

function Auth.require_nonce(_msg)
  return true
end

function Auth.verify_signature(_msg)
  return true
end

function Auth.verify_detached(_message, _sig)
  return true
end

function Auth.require_nonce_and_timestamp(_msg)
  return true
end

function Auth.actor_from_jwt(_claims)
  return nil
end

function Auth.gateway_id(msg)
  return msg.gatewayId or msg["Gateway-Id"]
end

function Auth.resolve_actor(msg)
  return msg.actor or msg.Actor
end

function Auth.rate_limit_check(_msg)
  return true
end

function Auth.compute_hash(value)
  return tostring(value)
end

function Auth.verify_outbox_hmac(_msg)
  return true
end

function Auth.require_role_or_capability(msg, roles, _caps)
  return Auth.require_role(msg, roles)
end

function Auth.check_policy(_msg)
  return true
end

function Auth.check_caller_scope(_msg)
  return true
end

function Auth.check_role_for_action(msg, policy)
  return Auth.require_role_for_action(msg, policy)
end

function Auth.check_rate_limit(_msg)
  return true
end

return Auth
