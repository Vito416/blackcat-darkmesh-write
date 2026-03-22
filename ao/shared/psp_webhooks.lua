-- Unified PSP webhook helpers (Stripe / PayPal / GoPay).
-- Provides per-provider verification, replay key, and status mapping.

local cjson
do
  local ok, mod = pcall(require, "cjson.safe")
  if ok then
    cjson = mod
  else
    ok, mod = pcall(require, "cjson")
    if ok then
      cjson = mod
    end
  end
end
local stripe_ok, stripe = pcall(require, "ao.shared.stripe")
local paypal_ok, paypal = pcall(require, "ao.shared.paypal")
local gopay_ok, gopay = pcall(require, "ao.shared.gopay")

local M = {}

local function read_body(raw)
  if not raw or not raw.body then
    return nil
  end
  local ok, decoded = pcall(cjson.decode, raw.body)
  if ok then
    return decoded
  end
end

M.registry = {
  gopay = {
    replay_key = function(cmd)
      return "gopay:"
        .. (
          cmd.payload.eventId
          or cmd.payload.paymentId
          or cmd.payload.orderId
          or cmd.requestId
          or ""
        )
    end,
    verify = function(cmd)
      if cmd.payload.raw and cmd.payload.raw.skip_verify then
        return true
      end
      local secret = os.getenv "GOPAY_WEBHOOK_SECRET"
      if secret and cmd.payload.raw and cmd.payload.raw.body then
        local sig = cmd.payload.raw.headers
          and (
            cmd.payload.raw.headers["X-GoPay-Signature"]
            or cmd.payload.raw.headers["GoPay-Signature"]
          )
        if not sig then
          return false, "missing_signature"
        end
        if not (gopay_ok and gopay.verify_signature) then
          return nil, "provider_unavailable"
        end
        local ok_sig = gopay.verify_signature(cmd.payload.raw.body, sig, secret)
        if ok_sig == nil then
          return nil, "provider_unavailable"
        end
        if not ok_sig then
          return false, "signature_invalid"
        end
      end
      if os.getenv "GOPAY_WEBHOOK_BASIC" == "1" and cmd.payload.raw and cmd.payload.raw.headers then
        local auth = cmd.payload.raw.headers["Authorization"]
        local decoded = gopay_ok and gopay.verify_basic and gopay.verify_basic(auth)
        if not decoded then
          return false, "basic_invalid"
        end
        local expected = (os.getenv "GOPAY_CLIENT_ID" or "")
          .. ":"
          .. (os.getenv "GOPAY_CLIENT_SECRET" or "")
        if decoded ~= expected then
          return false, "basic_mismatch"
        end
      end
      return true
    end,
    status = function(cmd)
      local status_map = {
        PAID = "captured",
        CHARGED = "captured",
        AUTHORIZED = "requires_capture",
        CREATED = "pending",
        CANCELED = "voided",
        TIMEOUTED = "voided",
        REFUNDED = "refunded",
        PARTIALLY_REFUNDED = "partially_refunded",
        RISK = "risk_review",
        DISPUTED = "disputed",
        PAYMENT_METHOD_CHOSEN = "pending",
      }
      local body = read_body(cmd.payload.raw)
      if body and body.preauthorized and body.payment_instrument == "CARD" then
        status_map["PAID"] = "requires_capture"
      end
      return status_map[string.upper(cmd.payload.status or "")] or "pending"
    end,
  },
  stripe = {
    replay_key = function(cmd)
      return "stripe:" .. (cmd.payload.eventId or cmd.payload.paymentId or "")
    end,
    verify = function(cmd)
      if cmd.payload.raw and cmd.payload.raw.skip_verify then
        return true
      end
      local secret = os.getenv "STRIPE_WEBHOOK_SECRET"
      if secret and cmd.payload.raw and cmd.payload.raw.body then
        local headers = cmd.payload.raw.headers or {}
        local sig = headers["Stripe-Signature"] or headers["stripe-signature"]
        if not sig then
          return false, "missing_signature"
        end
        if not stripe_ok or not stripe.verify_webhook then
          return nil, "provider_unavailable"
        end
        local ok_sig = stripe.verify_webhook(
          cmd.payload.raw.body,
          sig,
          secret,
          tonumber(os.getenv "STRIPE_WEBHOOK_TOLERANCE" or "300")
        )
        if ok_sig == nil then
          return nil, "provider_unavailable"
        end
        if not ok_sig then
          return false, "signature_invalid"
        end
      end
      return true
    end,
    status = function(cmd)
      local status_map = {
        ["payment_intent.succeeded"] = "captured",
        ["payment_intent.payment_failed"] = "failed",
        ["payment_intent.canceled"] = "voided",
        ["charge.refunded"] = "refunded",
        ["charge.refund.updated"] = "refunded",
        ["payment_intent.processing"] = "pending",
        ["payment_intent.requires_action"] = "requires_capture",
        ["charge.dispute.created"] = "disputed",
        ["charge.dispute.closed"] = "captured",
        ["charge.dispute.funds_withdrawn"] = "disputed",
        ["charge.dispute.funds_reinstated"] = "captured",
        ["charge.dispute.accepted"] = "disputed",
        ["charge.dispute.expired"] = "disputed",
        ["charge.dispute.escalated"] = "disputed",
      }
      return status_map[cmd.payload.eventType] or "pending"
    end,
    on_found = function(pid, _p, cmd, state)
      if cmd.payload.eventType and cmd.payload.eventType:match "dispute" then
        state.payment_disputes[pid] = state.payment_disputes[pid] or {}
        state.payment_disputes[pid].status = cmd.payload.eventType
        state.payment_disputes[pid].reason = cmd.payload.reason
        state.payment_disputes[pid].evidence = cmd.payload.evidence
          or state.payment_disputes[pid].evidence
      end
    end,
  },
  paypal = {
    replay_key = function(cmd)
      return "paypal:" .. (cmd.payload.eventId or cmd.payload.paymentId or "")
    end,
    verify = function(cmd)
      if cmd.payload.raw and cmd.payload.raw.skip_verify then
        return true
      end
      local secret = os.getenv "PAYPAL_WEBHOOK_SECRET"
      local strict = os.getenv "PAYPAL_WEBHOOK_STRICT" == "1"
      if (secret or strict) and cmd.payload.raw and cmd.payload.raw.body then
        local headers = cmd.payload.raw.headers or {}
        local sig = headers["PayPal-Transmission-Sig"] or headers["PP-Signature"]
        if strict and not sig then
          return false, "missing_signature"
        end
        if not paypal_ok then
          return nil, "provider_unavailable"
        end
        local ok_sig = false
        if sig and secret and paypal.verify_webhook then
          ok_sig = paypal.verify_webhook(cmd.payload.raw.body, sig, secret)
          if ok_sig == nil then
            return nil, "provider_unavailable"
          end
        end
        if not ok_sig and paypal.verify_webhook_remote then
          local remote_ok, remote_err = paypal.verify_webhook_remote(cmd.payload.raw.body, headers)
          if remote_ok == nil then
            return nil, remote_err or "provider_unavailable"
          end
          ok_sig = remote_ok or ok_sig
        end
        if strict and not ok_sig then
          return false, "signature_invalid"
        end
      end
      return true
    end,
    status = function(cmd)
      local status_map = {
        ["PAYMENT.CAPTURE.COMPLETED"] = "captured",
        ["PAYMENT.CAPTURE.DENIED"] = "failed",
        ["PAYMENT.CAPTURE.REFUNDED"] = "refunded",
        ["PAYMENT.CAPTURE.REVERSED"] = "voided",
        ["CHECKOUT.ORDER.APPROVED"] = "requires_capture",
        ["PAYMENT.CAPTURE.PENDING"] = "pending",
        ["CUSTOMER.DISPUTE.CREATED"] = "disputed",
        ["CUSTOMER.DISPUTE.UPDATED"] = "disputed",
        ["CUSTOMER.DISPUTE.RESOLVED"] = "captured",
        ["CUSTOMER.DISPUTE.EXPIRED"] = "disputed",
        ["CUSTOMER.DISPUTE.ESCALATED"] = "disputed",
      }
      return status_map[cmd.payload.eventType] or "pending"
    end,
    on_found = function(pid, _p, cmd, state)
      if cmd.payload.eventType and cmd.payload.eventType:match "DISPUTE" then
        state.payment_disputes[pid] = state.payment_disputes[pid] or {}
        state.payment_disputes[pid].status = cmd.payload.eventType
        state.payment_disputes[pid].reason = cmd.payload.reason
        state.payment_disputes[pid].evidence = cmd.payload.evidence
          or state.payment_disputes[pid].evidence
      end
    end,
  },
}

return M
