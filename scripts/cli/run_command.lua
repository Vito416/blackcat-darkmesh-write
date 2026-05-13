#!/usr/bin/env lua
-- Run a write command locally against the in-memory router.
-- Usage:
--   lua scripts/cli/run_command.lua path/to/command.json
--   lua scripts/cli/run_command.lua --list-templates
--   lua scripts/cli/run_command.lua --template <Action>

local POLICY_ACTION_REQUIREMENTS = {
  RegisterHBNode = {
    { "hbNodeId", "nodeId", "node", "wallet" },
    { "endpoint", "url", "baseUrl" },
  },
  UpdateHBNodeStatus = {
    { "hbNodeId", "nodeId", "node", "wallet" },
    { "status" },
  },
  SetSiteServingPolicy = {
    { "siteId" },
    { "servingPolicy", "policy", "mode", "servingState" },
  },
  SetSiteFundingState = {
    { "siteId" },
    { "fundingState", "state", "status" },
  },
  SetPolicyMode = {
    { "mode" },
  },
  PublishPolicySnapshot = {
    { "snapshotId", "snapshot" },
  },
  RevokePolicySnapshot = {
    { "snapshotId", "snapshot" },
  },
  SetDnsProofState = {
    { "host", "domain" },
    { "proofState", "state", "status" },
  },
  GetTemplateActionContract = {
    { "action", "actionName", "op", "operation" },
  },
  GetSiteRuntimeBundle = {
    { "siteId", "domain", "host" },
  },
  ResolveRouteForHost = {
    { "host", "domain" },
    { "path", "route", "uri" },
    { "method" },
  },
  GetSiteServingPolicy = {
    { "siteId" },
  },
  GetPolicySnapshot = {},
  GetDnsProofState = {
    { "host", "domain" },
  },
  ResolveHostPolicyBundle = {
    { "host", "domain" },
  },
  GetDomainLifecycleState = {
    { "domain", "host" },
  },
  SetDomainLifecycleState = {
    { "domain", "host" },
    { "lifecycleState", "state", "status" },
  },
  CreateSessionLifecycle = {
    { "siteId" },
    { "subject" },
  },
  ReadSessionLifecycle = {
    { "siteId" },
    { "sessionId" },
  },
  GetSessionLifecycle = {
    { "siteId" },
    { "sessionId" },
  },
  RotateSessionLifecycle = {
    { "siteId" },
    { "sessionId" },
  },
  RevokeSessionLifecycle = {
    { "siteId" },
    { "sessionId" },
  },
  ListSessionsBySubject = {
    { "siteId" },
    { "subject" },
  },
  CheckPaymentWebhookIdempotency = {
    { "siteId" },
    { "fingerprint" },
  },
  GetPaymentWebhookIdempotencyState = {
    { "siteId" },
  },
  ResetPaymentWebhookIdempotencyState = {
    { "siteId" },
  },
  InvalidateResolverCache = {
    { "scope" },
  },
  GetResolverCacheStats = {
    { "scope" },
  },
}

local function read_field(tbl, keys)
  if type(tbl) ~= "table" then
    return nil
  end
  for _, key in ipairs(keys) do
    local val = tbl[key]
    if val ~= nil and tostring(val) ~= "" then
      return val, key
    end
  end
  return nil
end

local function first_key(keys)
  return keys and keys[1] or "field"
end

local function join_keys(keys)
  local parts = {}
  for i = 1, #keys do
    parts[#parts + 1] = keys[i]
  end
  return table.concat(parts, " | ")
end

local function to_lower(v)
  if v == nil then
    return nil
  end
  return string.lower(tostring(v))
end

local function require_string_field(payload, keys, err_name)
  for _, key in ipairs(keys) do
    local v = payload[key]
    if v ~= nil then
      if type(v) ~= "string" then
        return false, string.format("payload.%s must be string", key)
      end
      if v == "" then
        return false, string.format("payload.%s required", key)
      end
      return v
    end
  end
  return false, string.format("payload.%s required", err_name or first_key(keys))
end

local function validate_policy_action_specific(action, payload)
  if action == "SetPolicyMode" then
    local mode = to_lower(read_field(payload, { "mode" }))
    if not mode then
      return false, "payload.mode required"
    end
    local allowed = {
      off = true,
      observe = true,
      soft = true,
      enforce = true,
      ["dry-run"] = true,
      disabled = true,
      monitor = true,
      active = true,
    }
    if not allowed[mode] then
      return false, "payload.mode invalid"
    end
  elseif action == "PublishPolicySnapshot" then
    local snapshot_id = read_field(payload, { "snapshotId", "id" })
    local snapshot_hash = read_field(payload, { "snapshotHash", "hash", "tx" })
    local snapshot = payload.snapshot
    if not snapshot_id and not snapshot_hash and snapshot == nil then
      return false, "payload.snapshotId | payload.snapshotHash | payload.snapshot required"
    end
    if snapshot ~= nil and type(snapshot) ~= "table" and type(snapshot) ~= "string" then
      return false, "payload.snapshot must be object|string"
    end
  elseif action == "SetDnsProofState" then
    local proof_state = to_lower(read_field(payload, { "proofState", "state", "status" }))
    if not proof_state then
      return false, "payload.proofState required"
    end
    local allowed = {
      pending = true,
      verified = true,
      unverified = true,
      failed = true,
      revoked = true,
      suspended = true,
      stale = true,
    }
    if not allowed[proof_state] then
      return false, "payload.proofState invalid"
    end
  elseif action == "SetDomainLifecycleState" then
    local lifecycle_state = to_lower(read_field(payload, { "lifecycleState", "state", "status" }))
    if not lifecycle_state then
      return false, "payload.lifecycleState required"
    end
    local allowed = {
      active = true,
      pending = true,
      suspended = true,
      disabled = true,
      retired = true,
      archived = true,
    }
    if not allowed[lifecycle_state] then
      return false, "payload.lifecycleState invalid"
    end
  elseif action == "CreateSessionLifecycle" then
    local subject_or_false, err_subject = require_string_field(payload, { "subject" }, "subject")
    if subject_or_false == false then
      return false, err_subject
    end
    if payload.sessionId ~= nil and type(payload.sessionId) ~= "string" then
      return false, "payload.sessionId must be string"
    end
    if
      payload.tokenTtlSec ~= nil
      and (type(payload.tokenTtlSec) ~= "number" or payload.tokenTtlSec <= 0)
    then
      return false, "payload.tokenTtlSec must be positive number"
    end
    if payload.claims ~= nil and type(payload.claims) ~= "table" then
      return false, "payload.claims must be object"
    end
    if payload.context ~= nil and type(payload.context) ~= "table" then
      return false, "payload.context must be object"
    end
  elseif
    action == "ReadSessionLifecycle"
    or action == "GetSessionLifecycle"
    or action == "RevokeSessionLifecycle"
  then
    local session_or_false, err_session =
      require_string_field(payload, { "sessionId" }, "sessionId")
    if session_or_false == false then
      return false, err_session
    end
  elseif action == "RotateSessionLifecycle" then
    local session_or_false, err_session =
      require_string_field(payload, { "sessionId" }, "sessionId")
    if session_or_false == false then
      return false, err_session
    end
    if payload.newSessionId ~= nil and type(payload.newSessionId) ~= "string" then
      return false, "payload.newSessionId must be string"
    end
    if
      payload.tokenTtlSec ~= nil
      and (type(payload.tokenTtlSec) ~= "number" or payload.tokenTtlSec <= 0)
    then
      return false, "payload.tokenTtlSec must be positive number"
    end
  elseif action == "ListSessionsBySubject" then
    local subject_or_false, err_subject = require_string_field(payload, { "subject" }, "subject")
    if subject_or_false == false then
      return false, err_subject
    end
    if payload.includeInactive ~= nil and type(payload.includeInactive) ~= "boolean" then
      return false, "payload.includeInactive must be boolean"
    end
    if payload.limit ~= nil and (type(payload.limit) ~= "number" or payload.limit <= 0) then
      return false, "payload.limit must be positive number"
    end
  elseif action == "CheckPaymentWebhookIdempotency" then
    local fingerprint_or_false, err_fingerprint =
      require_string_field(payload, { "fingerprint" }, "fingerprint")
    if fingerprint_or_false == false then
      return false, err_fingerprint
    end
    if payload.provider ~= nil and type(payload.provider) ~= "string" then
      return false, "payload.provider must be string"
    end
    if payload.eventId ~= nil and type(payload.eventId) ~= "string" then
      return false, "payload.eventId must be string"
    end
    if payload.policy ~= nil then
      if type(payload.policy) ~= "string" then
        return false, "payload.policy must be string"
      end
      local normalized_policy = string.lower(payload.policy)
      if normalized_policy ~= "dedupe" and normalized_policy ~= "reject" then
        return false, "payload.policy invalid"
      end
    end
    if payload.ttlSec ~= nil and (type(payload.ttlSec) ~= "number" or payload.ttlSec <= 0) then
      return false, "payload.ttlSec must be positive number"
    end
    if payload.maxKeys ~= nil and (type(payload.maxKeys) ~= "number" or payload.maxKeys <= 0) then
      return false, "payload.maxKeys must be positive number"
    end
    if
      payload.keyMaxBytes ~= nil
      and (type(payload.keyMaxBytes) ~= "number" or payload.keyMaxBytes <= 0)
    then
      return false, "payload.keyMaxBytes must be positive number"
    end
  elseif action == "GetPaymentWebhookIdempotencyState" then
    if payload.provider ~= nil and type(payload.provider) ~= "string" then
      return false, "payload.provider must be string"
    end
    if payload.includeEntries ~= nil and type(payload.includeEntries) ~= "boolean" then
      return false, "payload.includeEntries must be boolean"
    end
    if payload.limit ~= nil and (type(payload.limit) ~= "number" or payload.limit <= 0) then
      return false, "payload.limit must be positive number"
    end
  elseif action == "ResetPaymentWebhookIdempotencyState" then
    if payload.provider ~= nil and type(payload.provider) ~= "string" then
      return false, "payload.provider must be string"
    end
    if payload.eventId ~= nil and type(payload.eventId) ~= "string" then
      return false, "payload.eventId must be string"
    end
  elseif
    action == "GetSiteServingPolicy"
    or action == "GetPolicySnapshot"
    or action == "GetDnsProofState"
    or action == "GetDomainLifecycleState"
  then
    if payload.host ~= nil and type(payload.host) ~= "string" then
      return false, "payload.host must be string"
    end
    if payload.domain ~= nil and type(payload.domain) ~= "string" then
      return false, "payload.domain must be string"
    end
    if payload.siteId ~= nil and type(payload.siteId) ~= "string" then
      return false, "payload.siteId must be string"
    end
  elseif action == "ResolveHostPolicyBundle" then
    local host_or_false, err_host = require_string_field(payload, { "host", "domain" }, "host")
    if host_or_false == false then
      return false, err_host
    end
  elseif action == "InvalidateResolverCache" or action == "GetResolverCacheStats" then
    if payload.scope ~= nil and type(payload.scope) ~= "string" then
      return false, "payload.scope must be string"
    end
    local scope = to_lower(read_field(payload, { "scope" }))
    if not scope then
      return false, "payload.scope required"
    end

    local allowed
    if action == "InvalidateResolverCache" then
      allowed = {
        all = true,
        host = true,
        site = true,
      }
    else
      allowed = {
        summary = true,
        all = true,
        host = true,
        domain = true,
        site = true,
        route = true,
      }
    end

    if not allowed[scope] then
      return false, "payload.scope invalid"
    end

    if scope == "host" or scope == "domain" then
      local host_or_false, err_host = require_string_field(payload, { "host", "domain" }, "host")
      if host_or_false == false then
        return false, err_host
      end
    elseif scope == "site" then
      local site_or_false, err_site = require_string_field(payload, { "siteId" }, "siteId")
      if site_or_false == false then
        return false, err_site
      end
    elseif scope == "route" then
      local host_or_false, err_host = require_string_field(payload, { "host", "domain" }, "host")
      if host_or_false == false then
        return false, err_host
      end
      local route_or_false, err_path =
        require_string_field(payload, { "path", "route", "uri" }, "path")
      if route_or_false == false then
        return false, err_path
      end
    end
  end
  return true
end

local function validate_policy_admin_command(cmd)
  local action = read_field(cmd, { "action", "Action" })
  if not action or not POLICY_ACTION_REQUIREMENTS[action] then
    return true
  end

  local core_fields = {
    { "requestId", "Request-Id" },
    { "actor", "Actor" },
    { "tenant", "Tenant" },
    { "nonce", "Nonce" },
    { "timestamp", "Timestamp", "ts" },
    { "signatureRef", "Signature-Ref" },
  }
  for _, keys in ipairs(core_fields) do
    if not read_field(cmd, keys) then
      return false, string.format("%s required", first_key(keys))
    end
  end

  local payload = cmd.payload
  if type(payload) ~= "table" then
    return false, "payload object required"
  end

  local required_groups = POLICY_ACTION_REQUIREMENTS[action]
  for _, group in ipairs(required_groups) do
    if not read_field(payload, group) then
      return false, string.format("payload.%s required", join_keys(group))
    end
  end

  local ok_specific, specific_err = validate_policy_action_specific(action, payload)
  if not ok_specific then
    return false, specific_err
  end
  return true
end

local function load_json_codec()
  local ok_cjson, cjson = pcall(require, "cjson")
  if ok_cjson and cjson then
    return {
      encode = function(value)
        return cjson.encode(value)
      end,
      decode = function(value)
        return cjson.decode(value)
      end,
    }
  end

  local ok_dkjson, dkjson = pcall(require, "dkjson")
  if ok_dkjson and dkjson then
    return {
      encode = function(value)
        return dkjson.encode(value)
      end,
      decode = function(value)
        local decoded, _, err = dkjson.decode(value, 1, nil)
        if err then
          error(err)
        end
        return decoded
      end,
    }
  end

  io.stderr:write "cjson or dkjson is required for this tool\n"
  os.exit(1)
end

local function policy_templates()
  return {
    RegisterHBNode = {
      action = "RegisterHBNode",
      requestId = "req-register-hb-node-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-register-hb-node-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        hbNodeId = "hb-eu-1",
        endpoint = "https://hyperbeam.example.com",
      },
    },
    UpdateHBNodeStatus = {
      action = "UpdateHBNodeStatus",
      requestId = "req-update-hb-status-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-update-hb-status-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        hbNodeId = "hb-eu-1",
        status = "online",
      },
    },
    SetSiteServingPolicy = {
      action = "SetSiteServingPolicy",
      requestId = "req-site-serving-policy-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-site-serving-policy-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        policy = "allow",
      },
    },
    SetSiteFundingState = {
      action = "SetSiteFundingState",
      requestId = "req-site-funding-state-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-site-funding-state-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        fundingState = "funded",
      },
    },
    SetPolicyMode = {
      action = "SetPolicyMode",
      requestId = "req-policy-mode-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-policy-mode-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        mode = "observe",
      },
    },
    PublishPolicySnapshot = {
      action = "PublishPolicySnapshot",
      requestId = "req-policy-snapshot-publish-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-policy-snapshot-publish-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        snapshotId = "snapshot-2026-04-22",
        snapshotHash = "tx-or-hash-placeholder",
      },
    },
    RevokePolicySnapshot = {
      action = "RevokePolicySnapshot",
      requestId = "req-policy-snapshot-revoke-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-policy-snapshot-revoke-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        snapshotId = "snapshot-2026-04-22",
      },
    },
    SetDnsProofState = {
      action = "SetDnsProofState",
      requestId = "req-dns-proof-state-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-dns-proof-state-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        host = "jdwt.fun",
        siteId = "site-jdwt",
        proofState = "verified",
      },
    },
    GetTemplateActionContract = {
      action = "GetTemplateActionContract",
      requestId = "req-template-action-contract-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-template-action-contract-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        actionName = "checkout.submit",
      },
    },
    GetSiteRuntimeBundle = {
      action = "GetSiteRuntimeBundle",
      requestId = "req-site-runtime-bundle-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-site-runtime-bundle-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        host = "jdwt.fun",
      },
    },
    ResolveRouteForHost = {
      action = "ResolveRouteForHost",
      requestId = "req-resolve-route-for-host-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-resolve-route-for-host-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        host = "jdwt.fun",
        path = "/products/item-1",
        method = "GET",
      },
    },
    GetSiteServingPolicy = {
      action = "GetSiteServingPolicy",
      requestId = "req-get-site-serving-policy-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-get-site-serving-policy-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
      },
    },
    GetPolicySnapshot = {
      action = "GetPolicySnapshot",
      requestId = "req-get-policy-snapshot-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-get-policy-snapshot-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        snapshotId = "snapshot-2026-04-22",
      },
    },
    GetDnsProofState = {
      action = "GetDnsProofState",
      requestId = "req-get-dns-proof-state-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-get-dns-proof-state-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        host = "jdwt.fun",
      },
    },
    ResolveHostPolicyBundle = {
      action = "ResolveHostPolicyBundle",
      requestId = "req-resolve-host-policy-bundle-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-resolve-host-policy-bundle-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        host = "jdwt.fun",
      },
    },
    GetDomainLifecycleState = {
      action = "GetDomainLifecycleState",
      requestId = "req-get-domain-lifecycle-state-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-get-domain-lifecycle-state-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        domain = "jdwt.fun",
      },
    },
    SetDomainLifecycleState = {
      action = "SetDomainLifecycleState",
      requestId = "req-set-domain-lifecycle-state-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-set-domain-lifecycle-state-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        domain = "jdwt.fun",
        lifecycleState = "active",
      },
    },
    CreateSessionLifecycle = {
      action = "CreateSessionLifecycle",
      requestId = "req-create-session-lifecycle-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-create-session-lifecycle-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        subject = "subject:user:alpha",
        sessionId = "sess:site-jdwt:alpha-001",
        tokenTtlSec = 900,
        claims = { tier = "starter" },
        context = { ip = "203.0.113.10" },
      },
    },
    ReadSessionLifecycle = {
      action = "ReadSessionLifecycle",
      requestId = "req-read-session-lifecycle-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-read-session-lifecycle-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        sessionId = "sess:site-jdwt:alpha-001",
      },
    },
    GetSessionLifecycle = {
      action = "GetSessionLifecycle",
      requestId = "req-get-session-lifecycle-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-get-session-lifecycle-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        sessionId = "sess:site-jdwt:alpha-001",
      },
    },
    RotateSessionLifecycle = {
      action = "RotateSessionLifecycle",
      requestId = "req-rotate-session-lifecycle-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-rotate-session-lifecycle-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        sessionId = "sess:site-jdwt:alpha-001",
        newSessionId = "sess:site-jdwt:alpha-002",
      },
    },
    RevokeSessionLifecycle = {
      action = "RevokeSessionLifecycle",
      requestId = "req-revoke-session-lifecycle-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-revoke-session-lifecycle-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        sessionId = "sess:site-jdwt:alpha-001",
      },
    },
    ListSessionsBySubject = {
      action = "ListSessionsBySubject",
      requestId = "req-list-sessions-by-subject-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-list-sessions-by-subject-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        subject = "subject:user:alpha",
        includeInactive = true,
        limit = 50,
      },
    },
    CheckPaymentWebhookIdempotency = {
      action = "CheckPaymentWebhookIdempotency",
      requestId = "req-check-payment-webhook-idempotency-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-check-payment-webhook-idempotency-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        provider = "gopay",
        eventId = "evt-001",
        fingerprint = "sha256:demo-fingerprint",
        policy = "dedupe",
        ttlSec = 600,
        maxKeys = 10000,
        keyMaxBytes = 512,
      },
    },
    GetPaymentWebhookIdempotencyState = {
      action = "GetPaymentWebhookIdempotencyState",
      requestId = "req-get-payment-webhook-idempotency-state-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-get-payment-webhook-idempotency-state-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        provider = "gopay",
        includeEntries = true,
        limit = 25,
      },
    },
    ResetPaymentWebhookIdempotencyState = {
      action = "ResetPaymentWebhookIdempotencyState",
      requestId = "req-reset-payment-webhook-idempotency-state-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-reset-payment-webhook-idempotency-state-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        siteId = "site-jdwt",
        provider = "gopay",
      },
    },
    InvalidateResolverCache = {
      action = "InvalidateResolverCache",
      requestId = "req-invalidate-resolver-cache-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-invalidate-resolver-cache-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        scope = "host",
        host = "jdwt.fun",
      },
    },
    GetResolverCacheStats = {
      action = "GetResolverCacheStats",
      requestId = "req-get-resolver-cache-stats-001",
      actor = "operator",
      tenant = "darkmesh",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-get-resolver-cache-stats-001",
      timestamp = "2026-04-22T00:00:00Z",
      payload = {
        scope = "summary",
      },
    },
  }
end

local function print_usage()
  io.stderr:write(
    "Usage:\n"
      .. "  lua scripts/cli/run_command.lua <command.json>\n"
      .. "  lua scripts/cli/run_command.lua --list-templates\n"
      .. "  lua scripts/cli/run_command.lua --template <Action>\n"
  )
end

local function is_policy_action(action)
  return action ~= nil and POLICY_ACTION_REQUIREMENTS[action] ~= nil
end

local exported = {
  validate_policy_admin_command = validate_policy_admin_command,
  policy_templates = policy_templates,
  policy_action_requirements = POLICY_ACTION_REQUIREMENTS,
  is_policy_action = is_policy_action,
}

if ... == "scripts.cli.run_command" then
  return exported
end

local arg1 = arg[1]
if not arg1 then
  print_usage()
  os.exit(1)
end

if arg1 == "--list-templates" then
  local templates = policy_templates()
  local names = {}
  for name in pairs(templates) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    print(name)
  end
  os.exit(0)
end

if arg1 == "--template" then
  local json = load_json_codec()
  local action = arg[2]
  if not action then
    io.stderr:write "Action is required for --template\n"
    os.exit(1)
  end
  local tpl = policy_templates()[action]
  if not tpl then
    io.stderr:write("Unknown template action: " .. tostring(action) .. "\n")
    os.exit(1)
  end
  print(json.encode(tpl))
  os.exit(0)
end

local f = assert(io.open(arg1, "r"))
local content = f:read "*a"
f:close()

local json = load_json_codec()
local cmd = json.decode(content)
local ok_cmd, err_msg = validate_policy_admin_command(cmd)
if not ok_cmd then
  print(json.encode { status = "ERR", code = "INVALID_INPUT", message = err_msg })
  os.exit(1)
end

local action = read_field(cmd, { "action", "Action" })
if is_policy_action(action) then
  print(json.encode {
    status = "ERR",
    code = "WRONG_TARGET",
    message = table.concat({
      "policy/resolver actions target blackcat-darkmesh-ao;",
      "use scripts/cli/send_control_command.js with AO_CONTROL_PID/AO_REGISTRY_PID/AO_RESOLVER_PID",
    }, " "),
    action = action,
  })
  os.exit(1)
end

local write = require "ao.write.process"

local resp = write.route(cmd)
print(json.encode(resp))
