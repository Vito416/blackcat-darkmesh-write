-- luacheck: max_line_length 200
local write = require "ao.write.process"
local ok_cli, run_command = pcall(require, "scripts.cli.run_command")
if not ok_cli then
  run_command = nil
end

local function req(action, extra)
  local msg = {
    action = action,
    ["Request-Id"] = action .. "-req",
    ["Actor-Role"] = "admin",
    actor = "contracts-checker",
    tenant = "tenant-contracts",
    nonce = action .. "-nonce",
    ts = os.time(),
    payload = {},
  }
  if extra then
    for k, v in pairs(extra) do
      msg[k] = v
    end
  end
  return msg
end

local function shallow_copy(tbl)
  local out = {}
  for k, v in pairs(tbl) do
    out[k] = v
  end
  return out
end

local tests = {
  function()
    local resp = write.route(
      req("SaveDraftPage", { payload = { siteId = "s1", pageId = "home", blocks = {} } })
    )
    assert(resp.status == "OK")
  end,
  function()
    local resp = write.route(
      req(
        "PublishPageVersion",
        { payload = { siteId = "s1", pageId = "home", versionId = "v1", manifestTx = "tx-1" } }
      )
    )
    assert(resp.status == "OK")
  end,
  function()
    local resp = write.route(
      req("UpsertRoute", { payload = { siteId = "s1", path = "/", target = "page:home" } })
    )
    assert(resp.status == "OK")
  end,
  function()
    local resp = write.route(
      req(
        "UpsertProduct",
        { payload = { siteId = "s1", sku = "sku1", payload = { name = "Prod" } } }
      )
    )
    assert(resp.status == "OK")
  end,
  function()
    local resp = write.route(req "UnknownAction")
    assert(resp.code == "UNKNOWN_ACTION")
  end,
  function()
    local policy_tests = {
      {
        action = "RegisterHBNode",
        payload = { hbNodeId = "hb-1", endpoint = "https://hb.example" },
      },
      {
        action = "UpdateHBNodeStatus",
        payload = { hbNodeId = "hb-1", status = "online" },
      },
      {
        action = "SetSiteServingPolicy",
        payload = { siteId = "s1", policy = "allow" },
      },
      {
        action = "SetSiteFundingState",
        payload = { siteId = "s1", fundingState = "funded" },
      },
      {
        action = "SetPolicyMode",
        payload = { mode = "observe" },
      },
      {
        action = "PublishPolicySnapshot",
        payload = { snapshotId = "snap-1" },
      },
      {
        action = "RevokePolicySnapshot",
        payload = { snapshotId = "snap-1" },
      },
      {
        action = "SetDnsProofState",
        payload = { host = "example.test", siteId = "s1", proofState = "verified" },
      },
      {
        action = "GetTemplateActionContract",
        payload = { actionName = "checkout.submit" },
      },
      {
        action = "GetSiteRuntimeBundle",
        payload = { host = "example.test" },
      },
      {
        action = "ResolveRouteForHost",
        payload = { host = "example.test", path = "/", method = "GET" },
      },
      {
        action = "GetSiteServingPolicy",
        payload = { siteId = "s1" },
      },
      {
        action = "GetPolicySnapshot",
        payload = { snapshotId = "snap-1" },
      },
      {
        action = "GetDnsProofState",
        payload = { host = "example.test" },
      },
      {
        action = "ResolveHostPolicyBundle",
        payload = { host = "example.test" },
      },
      {
        action = "GetDomainLifecycleState",
        payload = { domain = "example.test" },
      },
      {
        action = "SetDomainLifecycleState",
        payload = { domain = "example.test", lifecycleState = "active" },
      },
      {
        action = "CreateSessionLifecycle",
        payload = {
          siteId = "s1",
          subject = "subject:user:alpha",
          sessionId = "sess:s1:alpha-001",
          tokenTtlSec = 900,
        },
      },
      {
        action = "ReadSessionLifecycle",
        payload = { siteId = "s1", sessionId = "sess:s1:alpha-001" },
      },
      {
        action = "GetSessionLifecycle",
        payload = { siteId = "s1", sessionId = "sess:s1:alpha-001" },
      },
      {
        action = "RotateSessionLifecycle",
        payload = {
          siteId = "s1",
          sessionId = "sess:s1:alpha-001",
          newSessionId = "sess:s1:alpha-002",
        },
      },
      {
        action = "RevokeSessionLifecycle",
        payload = { siteId = "s1", sessionId = "sess:s1:alpha-001" },
      },
      {
        action = "ListSessionsBySubject",
        payload = { siteId = "s1", subject = "subject:user:alpha", includeInactive = true },
      },
      {
        action = "CheckPaymentWebhookIdempotency",
        payload = {
          siteId = "s1",
          provider = "gopay",
          eventId = "evt-001",
          fingerprint = "sha256:fingerprint",
          policy = "dedupe",
          ttlSec = 600,
        },
      },
      {
        action = "GetPaymentWebhookIdempotencyState",
        payload = { siteId = "s1", provider = "gopay", includeEntries = true, limit = 10 },
      },
      {
        action = "ResetPaymentWebhookIdempotencyState",
        payload = { siteId = "s1", provider = "gopay" },
      },
      {
        action = "InvalidateResolverCache",
        payload = { scope = "host", host = "example.test" },
      },
      {
        action = "GetResolverCacheStats",
        payload = { scope = "summary" },
      },
    }

    for _, spec in ipairs(policy_tests) do
      assert(
        run_command and run_command.is_policy_action(spec.action),
        spec.action .. " should be a control-plane action"
      )
      local ok_valid, err_valid = run_command.validate_policy_admin_command {
        action = spec.action,
        requestId = spec.action .. "-req",
        actor = "contracts-checker",
        tenant = "tenant-contracts",
        role = "registry-admin",
        signatureRef = "operator-key",
        nonce = spec.action .. "-nonce",
        timestamp = "2026-04-22T00:00:00Z",
        payload = spec.payload,
      }
      assert(
        ok_valid == true,
        spec.action .. " control envelope should validate: " .. tostring(err_valid)
      )
    end
  end,
  function()
    assert(
      run_command and run_command.validate_policy_admin_command,
      "run_command validator should load"
    )

    local valid_cmd = {
      action = "SetPolicyMode",
      requestId = "policy-pos-1",
      actor = "contracts-checker",
      tenant = "tenant-contracts",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-policy-pos-1",
      timestamp = "2026-04-22T00:00:00Z",
      payload = { mode = "observe" },
    }
    local ok_valid, err_valid = run_command.validate_policy_admin_command(valid_cmd)
    assert(ok_valid == true, "positive policy validation failed: " .. tostring(err_valid))

    local missing_sig_ref = shallow_copy(valid_cmd)
    missing_sig_ref.signatureRef = nil
    local ok_missing_sig, err_missing_sig =
      run_command.validate_policy_admin_command(missing_sig_ref)
    assert(ok_missing_sig == false, "policy validation should require signatureRef")
    assert(err_missing_sig == "signatureRef required")

    local invalid_cmd = {
      action = "PublishPolicySnapshot",
      requestId = "policy-neg-1",
      actor = "contracts-checker",
      tenant = "tenant-contracts",
      role = "registry-admin",
      signatureRef = "operator-key",
      nonce = "nonce-policy-neg-1",
      timestamp = "2026-04-22T00:00:00Z",
      payload = { snapshot = true },
    }
    local ok_invalid, err_invalid = run_command.validate_policy_admin_command(invalid_cmd)
    assert(ok_invalid == false, "negative policy validation should fail")
    assert(err_invalid == "payload.snapshot must be object|string")
  end,
  function()
    assert(run_command and run_command.policy_templates, "run_command templates should load")
    local templates = run_command.policy_templates()
    for action, template in pairs(templates) do
      local cmd = shallow_copy(template)
      assert(cmd, "missing template for action " .. action)
      local ok_valid, err_valid = run_command.validate_policy_admin_command(cmd)
      assert(ok_valid == true, action .. " template should validate: " .. tostring(err_valid))
      cmd.requestId = nil
      local ok_missing_req, err_missing_req = run_command.validate_policy_admin_command(cmd)
      assert(ok_missing_req == false, action .. " should fail without requestId")
      assert(err_missing_req == "requestId required")
    end
  end,
}

for i, t in ipairs(tests) do
  local ok, err = pcall(t)
  if not ok then
    io.stderr:write(string.format("Test %d failed: %s\n", i, err))
    os.exit(1)
  end
end

print "contracts: ok"
-- luacheck: max_line_length 200
