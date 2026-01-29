# frozen_string_literal: true

# name: unsub-update
# about: When a user sets Activity Summary (digest) to "Never" and they registered >10 minutes ago, send an async POST to an external endpoint.
# version: 1.0.1
# authors: you

after_initialize do
  require "net/http"
  require "uri"
  require "json"
  require "securerandom"

  # ============================================================
  # CONFIG (EDIT HERE)
  # ============================================================
  module ::DigestNeverPostbackConfig
    ENABLED = true

    # Your external endpoint (PHP)
    ENDPOINT_URL = "https://ai.templetrends.com/unsub_update.php"

    # Only send if user registered >= this many minutes ago
    MIN_MINUTES_SINCE_REGISTRATION = 10

    # Optional shared secret for your PHP endpoint
    SHARED_SECRET = ""

    # Timeouts
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 10
  end

  # Per-user custom fields
  PENDING_TOKEN_FIELD = "digest_never_postback_pending_token"
  SENT_AT_FIELD       = "digest_never_postback_sent_at"

  # ============================================================
  # JOB: sends POST in Sidekiq (async, non-blocking)
  # ============================================================
  module ::Jobs
    class DigestNeverPostback < ::Jobs::Base
      def execute(args)
        return unless ::DigestNeverPostbackConfig::ENABLED

        user_id     = args[:user_id].to_i
        pending_tok = args[:pending_token].to_s

        user = User.find_by(id: user_id)
        return if user.nil?
        return if user.staged? || user.suspended?

        opt = user.user_option
        return if opt.nil?

        # Only proceed if digest is STILL "never"
        return unless opt.digest_after_minutes.to_i <= 0

        # Ensure this job is still the latest intent for this user
        current_tok = user.custom_fields[PENDING_TOKEN_FIELD].to_s
        return unless current_tok.present? && current_tok == pending_tok

        # NEW RULE:
        # If user registered < MIN minutes ago => DO NOTHING (no waiting, no re-enqueue)
        min_age = ::DigestNeverPostbackConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
        return if user.created_at.present? && (Time.zone.now - user.created_at) < min_age

        # Build form payload (application/x-www-form-urlencoded)
        payload = {
          "event" => "digest_set_to_never",
          "user_id" => user.id.to_s,
          "username" => user.username.to_s,
          "email" => user.email.to_s,
          "registered_at" => (user.created_at&.utc&.iso8601 || ""),
          "digest_after_minutes" => opt.digest_after_minutes.to_i.to_s,
          "pending_token" => pending_tok,
          "sent_at_utc" => Time.zone.now.utc.iso8601,
          "secret" => ::DigestNeverPostbackConfig::SHARED_SECRET
        }

        uri = URI(::DigestNeverPostbackConfig::ENDPOINT_URL)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = ::DigestNeverPostbackConfig::OPEN_TIMEOUT_SECONDS
        http.read_timeout = ::DigestNeverPostbackConfig::READ_TIMEOUT_SECONDS

        req = Net::HTTP::Post.new(uri.request_uri)
        req.set_form_data(payload)

        begin
          resp = http.request(req)
          code = resp.code.to_i

          if code >= 200 && code < 300
            user.custom_fields[SENT_AT_FIELD] = Time.zone.now.utc.iso8601
            user.save_custom_fields(true)
          else
            Rails.logger.warn("[digest-never-postback] POST failed user_id=#{user.id} code=#{code} body=#{resp.body.to_s[0, 500]}")
          end
        rescue => e
          Rails.logger.warn("[digest-never-postback] POST error user_id=#{user.id} err=#{e.class}: #{e.message}")
        end
      end
    end
  end

  ::Jobs.register_job(:digest_never_postback, ::Jobs::DigestNeverPostback)

  # ============================================================
  # HOOK: detect when digest is changed to "Never"
  # ============================================================
  UserOption.class_eval do
    after_commit :_digest_never_postback_after_commit, on: [:update]

    def _digest_never_postback_after_commit
      return unless ::DigestNeverPostbackConfig::ENABLED

      return unless saved_change_to_digest_after_minutes?
      return unless digest_after_minutes.to_i <= 0

      u = self.user
      return if u.nil?

      # If user is < MIN minutes old => do nothing (per your new rule)
      min_age = ::DigestNeverPostbackConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
      return if u.created_at.present? && (Time.zone.now - u.created_at) < min_age

      # New pending token so older queued jobs become no-ops
      pending_tok = "#{Time.zone.now.to_i}-#{SecureRandom.hex(6)}"
      u.custom_fields[PENDING_TOKEN_FIELD] = pending_tok
      u.save_custom_fields(true)

      # Enqueue async job
      ::Jobs.enqueue(:digest_never_postback, user_id: u.id, pending_token: pending_tok)
    end
  end
end
